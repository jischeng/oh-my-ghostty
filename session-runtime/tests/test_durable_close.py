"""Close without attachment, replay prevention and startup reconciliation."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from test_sessions import BINARY, encode, frame


class DurableCloseTests(unittest.TestCase):
    def test_close_survives_client_loss_and_never_recreates_session(self):
        with tempfile.TemporaryDirectory(prefix='omg-close-', dir='/tmp') as directory:
            policy = dict(detached_ttl_seconds=259200, expires_at=None, close_on_agent_done=True,
                          agent_done_grace_seconds=60, terminate_grace_seconds=1,
                          host_idle_seconds=300, record_retention_seconds=604800)
            Path(directory, 'policy.json').write_text(json.dumps(policy))
            daemon = subprocess.Popen([str(BINARY), 'host', directory, '--', '/bin/sh', '-i'])
            identity = b'33333333-3333-3333-3333-333333333333'
            pids = []
            def connect():
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(5)
                s.connect(directory + '/host.sock')
                return s
            try:
                for _ in range(100):
                    if Path(directory, 'host.sock').exists(): break
                    time.sleep(.02)
                with connect() as s:
                    s.sendall(encode(b'H', 1, identity))
                    while True:
                        kind, _, data = frame(s)
                        if kind == b'D' and data[:1] == b'J':
                            pids.append(json.loads(data[13:])['pid'])
                            break
                # No claim, snapshot ACK or attached GUI is required for close.
                with connect() as s:
                    s.sendall(encode(b'K', 2, identity))
                    kind, _, data = frame(s)
                    self.assertEqual(kind, b'D')
                    self.assertEqual(data[13:], b'pending')
                # Close completes after its requesting transport disappears.
                deadline = time.monotonic() + 8
                while True:
                    with connect() as s:
                        s.sendall(encode(b'K', 3, identity))
                        kind, _, data = frame(s)
                        self.assertEqual(kind, b'D', data)
                        if data[13:] == b'closed': break
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.1)
                with self.assertRaises(ProcessLookupError): os.kill(pids[0], 0)
                with connect() as s:
                    s.sendall(encode(b'H', 4, identity))
                    self.assertEqual(frame(s)[0], b'E')
                # Intent arriving before create permanently fences that UUID.
                unseen = b'44444444-4444-4444-4444-444444444444'
                with connect() as s:
                    s.sendall(encode(b'K', 5, unseen))
                    self.assertEqual(frame(s)[2][13:], b'closed')
                    s.sendall(encode(b'H', 6, unseen))
                    self.assertEqual(frame(s)[0], b'E')
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)
                for pid in pids:
                    try: os.killpg(pid, 9)
                    except ProcessLookupError: pass

    def test_restart_marks_stale_records_lost_without_signalling_recorded_pid(self):
        with tempfile.TemporaryDirectory(prefix='omg-reconcile-', dir='/tmp') as directory:
            sessions = Path(directory, 'sessions')
            sessions.mkdir(mode=0o700)
            identity = '55555555-5555-5555-5555-555555555555'
            # Use our own PID: reconciliation must never signal a recorded PID.
            record = dict(version=1, id=identity, generation='1234', pid=os.getpid(), created_at=1,
                          updated_at=1, policy=dict(detached_ttl_seconds=259200, expires_at=None,
                          close_on_agent_done=True, agent_done_grace_seconds=60, terminate_grace_seconds=1,
                          host_idle_seconds=300, record_retention_seconds=604800), ended=None, resume=None)
            path = sessions / (identity + '.json')
            path.write_text(json.dumps(record))
            daemon = subprocess.Popen([str(BINARY), 'host', directory, '--', '/bin/sh', '-i'])
            try:
                for _ in range(100):
                    updated = json.loads(path.read_text())
                    if updated['ended'] is not None: break
                    time.sleep(.02)
                self.assertEqual(updated['ended'], 'lost')
                self.assertIsNone(updated['pid'])
                os.kill(os.getpid(), 0)
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)

    def _open_expect_error(self, host_socket, stream_id, request_dict):
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(5)
        sock.connect(str(host_socket))
        try:
            sock.sendall(encode(b'C', stream_id, json.dumps(request_dict).encode()))
            while True:
                kind, sid, data = frame(sock)
                if sid != stream_id:
                    continue
                if kind == b'E':
                    return data.decode(errors='replace')
                if kind == b'D' and data[:1] in (b'J', b'S'):
                    self.fail(f'Closed/exited session must never resurrect, got inner {data[:1]!r}')
        finally:
            sock.close()

    def test_closed_normal_exits_and_sibling_tombstone_delete_snapshots_and_never_resurrect(self):
        import struct
        with tempfile.TemporaryDirectory(prefix='omg-durable-snap-', dir='/tmp') as directory:
            root = Path(directory)
            fake_home = root / 'home'
            run_root = fake_home / '.omg' / 'run'
            sib_closed_dir = run_root / 'sib_closed'
            sib_lost_dir = run_root / 'sib_lost'
            host_dir = run_root / 'current_host'
            for d in (sib_closed_dir / 'sessions', sib_lost_dir / 'sessions', host_dir):
                d.mkdir(parents=True, mode=0o700)
                d.chmod(0o700)
            for p in (fake_home, fake_home / '.omg', run_root, sib_closed_dir, sib_lost_dir):
                p.chmod(0o700)

            policy = dict(
                detached_ttl_seconds=259200,
                expires_at=None,
                close_on_agent_done=False,
                agent_done_grace_seconds=60,
                terminate_grace_seconds=1,
                host_idle_seconds=300,
                record_retention_seconds=604800,
            )
            resurrect_launch = dict(
                argv=['/bin/sh', '-i'],
                env={'HOME': str(fake_home), 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'TERM': 'xterm-256color'},
                cwd=directory,
                cols=80,
                rows=24,
                pixel_width=640,
                pixel_height=384,
            )

            # Seed a sibling conflict BEFORE starting host_dir: sibling A has .closed tombstone
            # while sibling B has a newer ended="lost" record + fake snapshot.
            blocked_id = '77777777-7777-7777-7777-777777777777'
            (sib_closed_dir / 'sessions' / f'{blocked_id}.closed').write_text('')
            (sib_lost_dir / 'sessions' / f'{blocked_id}.json').write_text(json.dumps(dict(
                version=1,
                id=blocked_id,
                generation='abcd1234',
                pid=None,
                created_at=9999999999,
                updated_at=9999999999,
                boot_time=10,
                policy=policy,
                ended='lost',
                resume=None,
            )))
            (sib_lost_dir / 'sessions' / f'{blocked_id}.snapshot').write_bytes(b'OMGSNAP1\0deadbeef\0payload')

            daemon = subprocess.Popen(
                [str(BINARY), 'host-local', str(host_dir), '--', '/bin/sh', '-i'],
                env={**os.environ, 'HOME': str(fake_home), 'SHELL': '/bin/sh'},
            )
            pids = []
            try:
                host_sock = host_dir / 'host.sock'
                for _ in range(150):
                    if host_sock.exists():
                        break
                    time.sleep(0.02)

                # 0. Sibling tombstone beats newer sibling lost record.
                self._open_expect_error(host_sock, 1, dict(
                    id=blocked_id, policy=policy, create=False, cwd=None, resurrect_launch=resurrect_launch
                ))

                def start_and_wait_checkpoint(sid, session_policy, stream_id):
                    s = socket.socket(socket.AF_UNIX)
                    s.settimeout(8)
                    s.connect(str(host_sock))
                    s.sendall(encode(b'C', stream_id, json.dumps(dict(
                        id=sid,
                        policy=session_policy,
                        create=True,
                        cwd=directory,
                        launch=dict(resurrect_launch),
                    )).encode()))
                    while True:
                        kind, _, data = frame(s)
                        if kind != b'D':
                            continue
                        inner = data[:1]
                        if inner == b'J':
                            pids.append(json.loads(data[13:])['pid'])
                        elif inner == b'S':
                            seq = struct.unpack('>Q', data[1:9])[0]
                            s.sendall(encode(b'D', stream_id, encode(b'A', seq)))
                            s.sendall(encode(b'D', stream_id, encode(b'W')))
                        elif inner == b'W':
                            break
                    s.sendall(encode(b'D', stream_id, encode(b'I', 0, b'printf "CHECKPOINT_SEED\\n"\n')))
                    snap = host_dir / 'sessions' / f'{sid}.snapshot'
                    for _ in range(120):
                        if snap.exists():
                            break
                        time.sleep(0.05)
                    self.assertTrue(snap.exists(), f'debounced checkpoint should create {snap}')
                    return s, snap

                # 1. ExplicitClose (b'K') deletes snapshot + writes .closed -> never resurrects.
                s_close_id = '88888888-8888-8888-8888-888888888888'
                c1, snap1 = start_and_wait_checkpoint(s_close_id, policy, 2)
                c1.sendall(encode(b'D', 2, encode(b'K')))
                for _ in range(100):
                    if not snap1.exists() and (host_dir / 'sessions' / f'{s_close_id}.closed').exists():
                        break
                    time.sleep(0.03)
                c1.close()
                self.assertFalse(snap1.exists())
                self._open_expect_error(host_sock, 3, dict(
                    id=s_close_id, policy=policy, create=False, cwd=None, resurrect_launch=resurrect_launch
                ))

                # 2. Same-boot normal ProcessExited deletes snapshot -> never resurrects.
                s_exit_id = '99999999-9999-9999-9999-999999999999'
                c2, snap2 = start_and_wait_checkpoint(s_exit_id, policy, 4)
                c2.sendall(encode(b'D', 4, encode(b'I', 0, b'exit 0\n')))
                for _ in range(100):
                    rec2 = json.loads((host_dir / 'sessions' / f'{s_exit_id}.json').read_text())
                    if rec2.get('ended') == 'process_exited' and not snap2.exists():
                        break
                    time.sleep(0.03)
                c2.close()
                self.assertEqual(rec2['ended'], 'process_exited')
                self.assertFalse(snap2.exists())
                self._open_expect_error(host_sock, 5, dict(
                    id=s_exit_id, policy=policy, create=False, cwd=None, resurrect_launch=resurrect_launch
                ))

                # 3. Same-boot DetachedTimeout deletes snapshot -> never resurrects.
                s_ttl_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                ttl_policy = dict(policy, detached_ttl_seconds=1)
                c3, snap3 = start_and_wait_checkpoint(s_ttl_id, ttl_policy, 6)
                c3.close()
                rec3 = {}
                for _ in range(150):
                    rec3 = json.loads((host_dir / 'sessions' / f'{s_ttl_id}.json').read_text())
                    if rec3.get('ended') == 'detached_timeout' and not snap3.exists():
                        break
                    time.sleep(0.05)
                self.assertEqual(rec3.get('ended'), 'detached_timeout')
                self.assertFalse(snap3.exists())
                self._open_expect_error(host_sock, 7, dict(
                    id=s_ttl_id, policy=ttl_policy, create=False, cwd=None, resurrect_launch=resurrect_launch
                ))
            finally:
                for sid_file in (host_dir / 'sessions').glob('*.json'):
                    try:
                        sid_file.with_suffix('.closed').write_text('')
                    except OSError:
                        pass
                from test_local_runtime import wait_holders_stopped
                try:
                    wait_holders_stopped(host_dir)
                except AssertionError:
                    pass
                daemon.terminate()
                daemon.wait(timeout=5)
                for pid in pids:
                    try:
                        os.killpg(pid, 9)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__': unittest.main()
