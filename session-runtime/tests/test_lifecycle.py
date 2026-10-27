"""Real daemon lifecycle tests; no GUI or external SSH endpoint required."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import uuid
from test_sessions import BINARY, encode, frame


class LifetimeTests(unittest.TestCase):
    def test_detached_ttl_reaps_process_and_empty_host(self):
        with tempfile.TemporaryDirectory(prefix='omg-ttl-', dir='/tmp') as root:
            policy = {'detached_ttl_seconds': 1, 'terminate_grace_seconds': 1, 'host_idle_seconds': 1}
            Path(root, 'policy.json').write_text(json.dumps(policy))
            host = subprocess.Popen([str(BINARY), 'host', root, '--', '/bin/sh', '-c',
                                     'trap "" TERM; while :; do printf output; sleep 0.05; done'])
            pane = str(uuid.uuid4())
            sock = None
            pid = None
            try:
                for _ in range(100):
                    if Path(root, 'host.sock').exists(): break
                    time.sleep(.02)
                sock = socket.socket(socket.AF_UNIX)
                sock.settimeout(5)
                sock.connect(root + '/host.sock')
                sock.sendall(encode(b'H', 1, pane.encode()))
                while True:
                    kind, stream, data = frame(sock)
                    if kind == b'D' and data[:1] == b'J':
                        pid = json.loads(data[13:])['pid']
                    if kind == b'D' and data[:1] == b'S':
                        import struct
                        seq = struct.unpack('>Q', data[1:9])[0]
                        sock.sendall(encode(b'D', 1, encode(b'A', seq)))
                        break
                self.assertIsNotNone(pid)
                # Output stays active; it must not renew the detached lifetime.
                sock.close()
                sock = None
                host.wait(timeout=10)
                self.assertEqual(host.returncode, 0)
                record = json.loads(Path(root, 'sessions', pane + '.json').read_text())
                self.assertEqual(record['ended'], 'detached_timeout')
                self.assertIsNone(record['pid'])
                with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
                self.assertFalse(Path(root, 'host.sock').exists())
            finally:
                if sock: sock.close()
                if host.poll() is None: host.kill()
                host.wait()
                if pid:
                    try: os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError: pass

    def test_duplicate_host_does_not_remove_live_socket(self):
        with tempfile.TemporaryDirectory(prefix='omg-lock-', dir='/tmp') as root:
            Path(root, 'policy.json').write_text(json.dumps({'host_idle_seconds': 2}))
            host = subprocess.Popen([str(BINARY), 'host', root, '--', '/bin/sh'])
            try:
                for _ in range(100):
                    if Path(root, 'host.sock').exists(): break
                    time.sleep(.02)
                other = subprocess.run([str(BINARY), 'host', root, '--', '/bin/sh'], capture_output=True, timeout=5)
                self.assertNotEqual(other.returncode, 0)
                self.assertTrue(Path(root, 'host.sock').exists())
                self.assertIsNone(host.poll())
                host.wait(timeout=5)
            finally:
                if host.poll() is None: host.kill()
                host.wait()


if __name__ == '__main__': unittest.main()
