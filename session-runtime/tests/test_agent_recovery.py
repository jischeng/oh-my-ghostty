"""Daemon-owned completion cleanup and conversation recovery using a fixture Agent."""
import json
import os
from pathlib import Path
import socket
import shlex
import subprocess
import tempfile
import time
import unittest
import uuid
from test_sessions import BINARY, encode, frame


class AgentRecoveryTests(unittest.TestCase):
    def test_completion_persists_conversation_and_resume_uses_new_pid(self):
        with tempfile.TemporaryDirectory(prefix='omg-agent-', dir='/tmp') as directory:
            root = Path(directory)
            home = root/'home'
            home.mkdir()
            conversation = 'fixture-conversation'
            store = home/'.claude/projects/project'
            store.mkdir(parents=True)
            (store/(conversation+'.jsonl')).write_text('{"type":"session"}\n')
            bin_dir = root/'bin'
            bin_dir.mkdir()
            agent = bin_dir/'claude'
            agent.write_text('#!/bin/sh\nprintf "RESUMED:%s:%s\\n" "$1" "$2"\nexec sleep 60\n')
            agent.chmod(0o700)
            shell = root/'shell'
            shell.write_text('#!/bin/sh\nexport PATH="'+str(bin_dir)+':/usr/bin:/bin"\nexec /bin/sh "$@"\n')
            shell.chmod(0o700)
            (root/'policy.json').write_text(json.dumps({'close_on_agent_done': True,
                'agent_done_grace_seconds': 1, 'terminate_grace_seconds': 1,
                'detached_ttl_seconds': 60, 'host_idle_seconds': 60}))
            host = subprocess.Popen([str(BINARY), 'host', str(root), '--', str(shell), '-i'],
                                    env={**os.environ, 'HOME': str(home)})
            pane = str(uuid.uuid4())
            clients = []
            def attach(resume_generation=None):
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(8)
                s.connect(str(root/'host.sock'))
                clients.append(s)
                if resume_generation is None:
                    s.sendall(encode(b'H', 1, pane.encode()))
                else:
                    request = json.dumps({
                        'id': pane,
                        'generation': resume_generation,
                    }).encode()
                    s.sendall(encode(b'U', 1, request))
                info = None
                while True:
                    kind, stream, data = frame(s)
                    if kind == b'E': self.fail(data.decode())
                    if kind != b'D': continue
                    if data[:1] == b'J': info = json.loads(data[13:])
                    if data[:1] == b'S':
                        import struct
                        seq = struct.unpack('>Q', data[1:9])[0]
                        s.sendall(encode(b'D', 1, encode(b'A', seq)))
                        s.sendall(encode(b'D', 1, encode(b'W')))
                    if data[:1] == b'W': return s, info
            try:
                for _ in range(100):
                    if (root/'host.sock').exists(): break
                    time.sleep(.02)
                first, original = attach()
                task = f'"$OMG_RUNTIME_BIN" report claude working {conversation} {root}; sleep 0.2; "$OMG_RUNTIME_BIN" report claude done {conversation} {root}; exec sleep 60'
                command = '/bin/sh -c ' + shlex.quote(task) + '\n'
                first.sendall(encode(b'D', 1, encode(b'I', 0, command.encode())))
                record_path = root/'sessions'/f'{pane}.json'
                for _ in range(100):
                    record = json.loads(record_path.read_text())
                    if record.get('resume'): break
                    time.sleep(.02)
                self.assertEqual(record['resume']['conversation_id'], conversation)
                first.close()
                for _ in range(400):
                    record = json.loads(record_path.read_text())
                    if record['pid'] is None and record['ended']: break
                    time.sleep(.02)
                self.assertEqual(record['ended'], 'agent_completed')
                self.assertIsNone(record['pid'])
                attach_only = socket.socket(socket.AF_UNIX)
                attach_only.settimeout(5)
                attach_only.connect(str(root/'host.sock'))
                clients.append(attach_only)
                policy = json.loads((root/'policy.json').read_text())
                request = json.dumps({
                    'id': pane,
                    'policy': policy,
                    'create': False,
                    'cwd': None,
                }).encode()
                attach_only.sendall(encode(b'C', 2, request))
                while True:
                    kind, stream, _ = frame(attach_only)
                    if stream == 2:
                        self.assertEqual(kind, b'E')
                        break
                record = json.loads(record_path.read_text())
                self.assertEqual(record['ended'], 'agent_completed')
                self.assertIsNone(record['pid'])
                restored, current = attach(original['generation'])
                self.assertNotEqual(current['pid'], original['pid'])
                self.assertEqual(current['session_id'], original['session_id'])
                self.assertNotEqual(current['generation'], original['generation'])
                record = json.loads(record_path.read_text())
                self.assertEqual(record['resume']['conversation_id'], conversation)
                restored.sendall(encode(b'D', 1, encode(b'K')))
                while True:
                    k, _, data = frame(restored)
                    if k == b'D' and data[:1] == b'X': break
            finally:
                for client in clients: client.close()
                host.kill()
                host.wait()

    def _find_holder_pid(self, root, session_id):
        import hashlib
        import struct
        import sys
        ctl_path = root / (hashlib.sha256(session_id.encode()).hexdigest()[:16] + '.ctl')
        if not ctl_path.exists():
            return None
        with socket.socket(socket.AF_UNIX) as probe:
            probe.settimeout(2)
            probe.connect(str(ctl_path))
            if sys.platform == 'darwin':
                return struct.unpack('i', probe.getsockopt(0, 2, 4))[0]
            creds = probe.getsockopt(socket.SOL_SOCKET, 17, 12)
            return struct.unpack('3i', creds)[0]

    def test_local_lost_session_auto_resumes_agent_with_login_shell_fallback_and_agent_completed_rejects_open(self):
        import signal
        import struct
        with tempfile.TemporaryDirectory(prefix='omg-local-agent-', dir='/tmp') as directory:
            root = Path(directory)
            home = root / 'home'
            home.mkdir(mode=0o700)
            conversation = 'local-resurrect-conv-1'
            store_dir = home / '.claude/projects/project'
            store_dir.mkdir(parents=True)
            store_file = store_dir / f'{conversation}.jsonl'
            store_file.write_text('{"type":"session"}\n')
            args_log = root / 'agent-args.log'
            bin_dir = root / 'bin'
            bin_dir.mkdir(mode=0o700)
            agent = bin_dir / 'claude'
            agent.write_text(
                '#!/bin/sh\n'
                f'printf "%s\\n" "$*" >> "{args_log}"\n'
                'printf "AGENT_RESUMED_LIVE\\n"\n'
                'exit 0\n'
            )
            agent.chmod(0o700)
            policy = {
                'detached_ttl_seconds': 259200,
                'expires_at': None,
                'close_on_agent_done': False,
                'agent_done_grace_seconds': 60,
                'terminate_grace_seconds': 1,
                'host_idle_seconds': 300,
                'record_retention_seconds': 604800,
            }
            env_path = f'{bin_dir}:/usr/bin:/bin'
            host = subprocess.Popen(
                [str(BINARY), 'host-local', str(root), '--', '/bin/sh', '-i'],
                env={**os.environ, 'HOME': str(home), 'SHELL': '/bin/sh', 'PATH': env_path},
            )
            clients = []
            pids = []
            try:
                host_sock = root / 'host.sock'
                for _ in range(150):
                    if host_sock.exists():
                        break
                    time.sleep(0.02)

                # 1. Local Lost session with valid resume store -> auto-resumes agent,
                # then when agent exits, falls through to interactive login shell!
                pane = str(uuid.uuid4())
                resurrect_launch = {
                    'argv': ['/bin/sh', '-i'],
                    'env': {'HOME': str(home), 'PATH': env_path, 'SHELL': '/bin/sh', 'TERM': 'xterm-256color'},
                    'cwd': directory,
                    'cols': 80,
                    'rows': 24,
                    'pixel_width': 640,
                    'pixel_height': 384,
                }
                s1 = socket.socket(socket.AF_UNIX)
                s1.settimeout(8)
                s1.connect(str(host_sock))
                clients.append(s1)
                s1.sendall(encode(b'C', 1, json.dumps({
                    'id': pane,
                    'policy': policy,
                    'create': True,
                    'cwd': directory,
                    'launch': dict(resurrect_launch),
                }).encode()))
                while True:
                    kind, _, data = frame(s1)
                    if kind != b'D':
                        continue
                    if data[:1] == b'J':
                        pids.append(json.loads(data[13:])['pid'])
                    elif data[:1] == b'S':
                        seq = struct.unpack('>Q', data[1:9])[0]
                        s1.sendall(encode(b'D', 1, encode(b'A', seq)))
                        s1.sendall(encode(b'D', 1, encode(b'W')))
                    elif data[:1] == b'W':
                        break
                report_cmd = f'"$OMG_RUNTIME_BIN" report claude working {conversation} {root}\n'
                s1.sendall(encode(b'D', 1, encode(b'I', 0, report_cmd.encode())))
                record_path = root / 'sessions' / f'{pane}.json'
                for _ in range(100):
                    if record_path.exists():
                        rec = json.loads(record_path.read_text())
                        if rec.get('resume'):
                            break
                    time.sleep(0.03)
                self.assertEqual(rec['resume']['conversation_id'], conversation)

                holder_pid = self._find_holder_pid(root, pane)
                self.assertIsNotNone(holder_pid)
                os.kill(holder_pid, signal.SIGTERM)
                for _ in range(150):
                    rec = json.loads(record_path.read_text())
                    if rec.get('ended') == 'lost' and rec.get('pid') is None:
                        break
                    time.sleep(0.03)
                self.assertEqual(rec['ended'], 'lost')
                s1.close()

                s2 = socket.socket(socket.AF_UNIX)
                s2.settimeout(8)
                s2.connect(str(host_sock))
                clients.append(s2)
                s2.sendall(encode(b'C', 2, json.dumps({
                    'id': pane,
                    'policy': policy,
                    'create': False,
                    'cwd': None,
                    'resurrect_launch': resurrect_launch,
                }).encode()))
                out2 = b''
                deadline = time.monotonic() + 8
                saw_snap = False
                while time.monotonic() < deadline:
                    kind, stream, data = frame(s2)
                    if kind == b'E':
                        self.fail(data.decode(errors='replace'))
                    if kind != b'D' or stream != 2:
                        continue
                    if data[:1] == b'J':
                        pids.append(json.loads(data[13:])['pid'])
                    elif data[:1] == b'S':
                        seq = struct.unpack('>Q', data[1:9])[0]
                        s2.sendall(encode(b'D', 2, encode(b'A', seq)))
                        s2.sendall(encode(b'D', 2, encode(b'W')))
                        saw_snap = True
                    elif data[:1] == b'O':
                        out2 += data[13:]
                    elif saw_snap and b'AGENT_RESUMED_LIVE' in out2:
                        break
                self.assertIn(b'AGENT_RESUMED_LIVE', out2)
                self.assertIn(f'--resume {conversation}', args_log.read_text())

                # Fake agent exited cleanly -> login shell fallback stays alive!
                s2.sendall(encode(b'D', 2, encode(b'I', 0, b'printf "FALLBACK_SHELL_OK\\n"\n')))
                fallback_out = b''
                deadline = time.monotonic() + 5
                while b'FALLBACK_SHELL_OK' not in fallback_out and time.monotonic() < deadline:
                    kind, stream, data = frame(s2)
                    if kind == b'D' and stream == 2 and data[:1] == b'O':
                        fallback_out += data[13:]
                self.assertIn(b'FALLBACK_SHELL_OK', fallback_out)

                # 2. Remove conversation store -> second SIGTERM + resurrect must skip agent & open shell.
                args_before = args_log.read_text()
                store_file.unlink()
                holder_pid2 = self._find_holder_pid(root, pane)
                self.assertIsNotNone(holder_pid2)
                os.kill(holder_pid2, signal.SIGTERM)
                for _ in range(150):
                    rec = json.loads(record_path.read_text())
                    if rec.get('ended') == 'lost' and rec.get('pid') is None:
                        break
                    time.sleep(0.03)
                s2.close()

                s3 = socket.socket(socket.AF_UNIX)
                s3.settimeout(8)
                s3.connect(str(host_sock))
                clients.append(s3)
                s3.sendall(encode(b'C', 3, json.dumps({
                    'id': pane,
                    'policy': policy,
                    'create': False,
                    'cwd': None,
                    'resurrect_launch': resurrect_launch,
                }).encode()))
                while True:
                    kind, stream, data = frame(s3)
                    if kind == b'E':
                        self.fail(data.decode(errors='replace'))
                    if kind == b'D' and stream == 3:
                        if data[:1] == b'J':
                            pids.append(json.loads(data[13:])['pid'])
                        elif data[:1] == b'S':
                            seq = struct.unpack('>Q', data[1:9])[0]
                            s3.sendall(encode(b'D', 3, encode(b'A', seq)))
                            s3.sendall(encode(b'D', 3, encode(b'W')))
                        elif data[:1] == b'W':
                            break
                self.assertEqual(args_log.read_text(), args_before, 'missing store must not invoke agent')
                s3.sendall(encode(b'D', 3, encode(b'I', 0, b'printf "NO_STORE_SHELL_OK\\n"\n')))
                shell_out = b''
                deadline = time.monotonic() + 5
                while b'NO_STORE_SHELL_OK' not in shell_out and time.monotonic() < deadline:
                    kind, stream, data = frame(s3)
                    if kind == b'D' and stream == 3 and data[:1] == b'O':
                        shell_out += data[13:]
                self.assertIn(b'NO_STORE_SHELL_OK', shell_out)
                s3.sendall(encode(b'D', 3, encode(b'K')))
                s3.close()

                # 3. Local AgentCompleted session MUST STILL reject OpenRequest (even with resurrect_launch),
                # and resume ONLY via explicit b'U'.
                store_file.write_text('{"type":"session"}\n')
                pane_done = str(uuid.uuid4())
                done_policy = dict(policy, close_on_agent_done=True, agent_done_grace_seconds=1)
                s4 = socket.socket(socket.AF_UNIX)
                s4.settimeout(8)
                s4.connect(str(host_sock))
                clients.append(s4)
                s4.sendall(encode(b'C', 4, json.dumps({
                    'id': pane_done,
                    'policy': done_policy,
                    'create': True,
                    'cwd': directory,
                    'launch': dict(resurrect_launch),
                }).encode()))
                while True:
                    kind, stream, data = frame(s4)
                    if kind == b'D' and stream == 4:
                        if data[:1] == b'J':
                            pids.append(json.loads(data[13:])['pid'])
                        elif data[:1] == b'S':
                            seq = struct.unpack('>Q', data[1:9])[0]
                            s4.sendall(encode(b'D', 4, encode(b'A', seq)))
                            s4.sendall(encode(b'D', 4, encode(b'W')))
                        elif data[:1] == b'W':
                            break
                done_task = (
                    f'"$OMG_RUNTIME_BIN" report claude working {conversation} {root}; '
                    f'sleep 0.1; "$OMG_RUNTIME_BIN" report claude done {conversation} {root}; '
                    'exec sleep 60'
                )
                done_cmd = '/bin/sh -c ' + shlex.quote(done_task) + '\n'
                s4.sendall(encode(b'D', 4, encode(b'I', 0, done_cmd.encode())))
                done_rec_path = root / 'sessions' / f'{pane_done}.json'
                for _ in range(100):
                    if done_rec_path.exists() and json.loads(done_rec_path.read_text()).get('resume'):
                        break
                    time.sleep(0.03)
                s4.close()
                for _ in range(200):
                    done_rec = json.loads(done_rec_path.read_text())
                    if done_rec.get('ended') == 'agent_completed' and done_rec.get('pid') is None:
                        break
                    time.sleep(0.03)
                self.assertEqual(done_rec.get('ended'), 'agent_completed')

                s5 = socket.socket(socket.AF_UNIX)
                s5.settimeout(5)
                s5.connect(str(host_sock))
                clients.append(s5)
                s5.sendall(encode(b'C', 5, json.dumps({
                    'id': pane_done,
                    'policy': done_policy,
                    'create': False,
                    'cwd': None,
                    'resurrect_launch': resurrect_launch,
                }).encode()))
                kind, stream, _ = frame(s5)
                self.assertEqual((kind, stream), (b'E', 5))
                s5.close()

                s6 = socket.socket(socket.AF_UNIX)
                s6.settimeout(8)
                s6.connect(str(host_sock))
                clients.append(s6)
                s6.sendall(encode(b'U', 6, json.dumps({
                    'id': pane_done,
                    'generation': done_rec['generation'],
                }).encode()))
                while True:
                    kind, stream, data = frame(s6)
                    if kind == b'E':
                        self.fail(data.decode(errors='replace'))
                    if kind == b'D' and stream == 6:
                        if data[:1] == b'J':
                            info6 = json.loads(data[13:])
                            pids.append(info6['pid'])
                            self.assertNotEqual(info6['generation'], done_rec['generation'])
                        elif data[:1] == b'S':
                            seq = struct.unpack('>Q', data[1:9])[0]
                            s6.sendall(encode(b'D', 6, encode(b'A', seq)))
                            s6.sendall(encode(b'D', 6, encode(b'W')))
                        elif data[:1] == b'W':
                            break
                s6.sendall(encode(b'D', 6, encode(b'K')))
                while True:
                    kind, stream, data = frame(s6)
                    if kind == b'D' and stream == 6 and data[:1] == b'X':
                        break
            finally:
                for client in clients:
                    client.close()
                holder_pids = set()
                for sid_file in (root / 'sessions').glob('*.json'):
                    hpid = self._find_holder_pid(root, sid_file.stem)
                    if hpid and hpid > 1:
                        holder_pids.add(hpid)
                    try:
                        sid_file.with_suffix('.closed').write_text('')
                    except OSError:
                        pass
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
                from test_local_runtime import wait_holders_stopped
                try:
                    wait_holders_stopped(root)
                except (AssertionError, TimeoutError, OSError):
                    pass
                for hpid in holder_pids:
                    try:
                        os.kill(hpid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                deadline_reap = time.monotonic() + 2
                while time.monotonic() < deadline_reap:
                    alive = False
                    for hpid in holder_pids:
                        try:
                            os.kill(hpid, 0)
                            alive = True
                        except ProcessLookupError:
                            pass
                    if not alive:
                        break
                    time.sleep(0.02)
                for hpid in holder_pids:
                    try:
                        os.kill(hpid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                for pid in pids:
                    for killer in (os.killpg, os.kill):
                        try:
                            killer(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == '__main__': unittest.main()
