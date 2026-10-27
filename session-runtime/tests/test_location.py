import json
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from test_sessions import BINARY, encode, frame


class LocationTests(unittest.TestCase):
    def test_directory_changes_and_reattach_report_remote_cwd(self):
        with tempfile.TemporaryDirectory(prefix='omg-cwd-', dir='/tmp') as directory:
            root = Path(directory)
            target = root/'project with spaces'
            target.mkdir()
            daemon = subprocess.Popen([str(BINARY), 'serve', str(root/'s'), '--', '/bin/sh', '-i'], cwd=root)
            clients = []
            def attach():
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(5)
                s.connect(str(root/'s'))
                clients.append(s)
                self.assertEqual(frame(s)[0], b'J')
                kind, seq, _ = frame(s)
                self.assertEqual(kind, b'S')
                s.sendall(encode(b'A', seq))
                s.sendall(encode(b'W'))
                return s
            def location(s, expected):
                for _ in range(100):
                    kind, _, payload = frame(s)
                    if kind == b'M' and json.loads(payload)['cwd'] == str(expected.resolve()): return
                self.fail('remote directory never arrived')
            try:
                for _ in range(100):
                    if (root/'s').exists(): break
                    time.sleep(.02)
                s = attach()
                location(s, root)
                s.sendall(encode(b'I', 0, ("cd '" + str(target) + "'\n").encode()))
                location(s, target)
                s.close()
                time.sleep(.05)
                s = attach()
                location(s, target)
                s.sendall(encode(b'K'))
            finally:
                for s in clients: s.close()
                try: daemon.wait(timeout=8)
                except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()


if __name__ == '__main__': unittest.main()
