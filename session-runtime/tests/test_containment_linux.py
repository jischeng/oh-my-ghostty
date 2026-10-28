"""Opt-in real systemd/cgroup acceptance. Only disposable runtime directories."""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from test_sessions import encode, frame


@unittest.skipUnless(os.environ.get('OMG_CONTAINMENT_TEST_BINARY'), 'requires disposable Linux systemd test host')
class ContainmentTests(unittest.TestCase):
    def test_escaped_descendants_close_isolation_and_host_crash(self):
        binary = os.environ['OMG_CONTAINMENT_TEST_BINARY']
        with tempfile.TemporaryDirectory(prefix='omg-containment-', dir='/tmp') as directory:
            daemon_pid = None
            pids = []
            policy = dict(detached_ttl_seconds=259200, expires_at=None, close_on_agent_done=True,
                          agent_done_grace_seconds=60, terminate_grace_seconds=1,
                          host_idle_seconds=300, record_retention_seconds=604800)
            Path(directory, 'policy.json').write_text(json.dumps(policy))
            subprocess.run([binary, 'ensure-host', directory], check=True, timeout=15)
            def connect():
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(10)
                s.connect(directory + '/host.sock')
                return s
            def inner(s, stream, kind):
                while True:
                    outer, seq, data = frame(s)
                    if outer == b'E': raise AssertionError(data)
                    if outer == b'D' and seq == stream and data[:1] == kind:
                        return struct.unpack('>cQI', data[:13])[1], data[13:]
            def alive(pid):
                p = Path(f'/proc/{pid}/stat')
                return p.exists() and p.read_text().split(') ')[1][0] != 'Z'
            def await_dead(ids):
                end = time.monotonic() + 15
                while any(alive(pid) for pid in ids):
                    if time.monotonic() > end: raise AssertionError(('survivors', ids))
                    time.sleep(.05)
            try:
                with connect() as s:
                    ids = [b'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', b'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb']
                    infos = []
                    for stream, identity in enumerate(ids, 1):
                        s.sendall(encode(b'H', stream, identity))
                        _, data = inner(s, stream, b'J')
                        info = json.loads(data)
                        infos.append(info)
                        pids.append(info['pid'])
                        seq, _ = inner(s, stream, b'S')
                        s.sendall(encode(b'D', stream, encode(b'A', seq)))
                        s.sendall(encode(b'D', stream, encode(b'W')))
                        inner(s, stream, b'W')
                        # A detached, double-forked, TERM/HUP-ignoring process.
                        script = f"import os,signal,time; os.fork() and os._exit(0); os.setsid(); os.fork() and os._exit(0); signal.signal(signal.SIGHUP,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open('{directory}/escaped-{stream}','w').write(str(os.getpid())); time.sleep(600)"
                        import shlex
                        command = 'python3 -c ' + shlex.quote(script) + '\n'
                        s.sendall(encode(b'D', stream, encode(b'I', 0, command.encode())))
                    for stream in [1, 2]:
                        path = Path(directory, f'escaped-{stream}')
                        end = time.monotonic() + 10
                        while not path.exists() or not path.read_text():
                            self.assertLess(time.monotonic(), end)
                            time.sleep(.02)
                        pids.append(int(path.read_text()))
                    daemon_pid = int(Path(f'/proc/{pids[0]}/stat').read_text().split(') ')[1].split()[1])
                    self.assertEqual(daemon_pid, int(Path(f'/proc/{pids[1]}/stat').read_text().split(') ')[1].split()[1]))
                    groups = [Path(f'/proc/{pid}/cgroup').read_text() for pid in pids]
                    self.assertEqual(groups[0], groups[2])
                    self.assertEqual(groups[1], groups[3])
                    self.assertNotEqual(groups[0], groups[1])
                    self.assertIn('/session-', groups[0])
                # Disconnection does not kill either session or escaped child.
                time.sleep(.2)
                self.assertTrue(all(alive(pid) for pid in pids))
                end = time.monotonic() + 12
                while True:
                    with connect() as s:
                        s.sendall(encode(b'K', 9, ids[0]))
                        _, data = inner(s, 9, b'K')
                        if data == b'closed': break
                    self.assertLess(time.monotonic(), end)
                    time.sleep(.1)
                await_dead([pids[0], pids[2]])
                self.assertTrue(alive(pids[1]) and alive(pids[3]))
                # SIGKILL cannot run Rust Drop; systemd must clean the subtree.
                os.kill(daemon_pid, signal.SIGKILL)
                await_dead([pids[1], pids[3]])
                print('PASS: detach preserved both sessions; close killed only A including escaped descendant; host SIGKILL cleaned B', flush=True)
            finally:
                if daemon_pid:
                    try: os.kill(daemon_pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                # Only PIDs created in this isolated test; never enumerate user sessions.
                for pid in pids:
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass


if __name__ == '__main__': unittest.main()
