"""Real host daemon multiplexing, child ownership and reattach contract."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest

BINARY = Path(__file__).resolve().parents[1] / 'target/debug/omgd'


def encode(kind, sequence=0, data=b''):
    return struct.pack('>cQI', kind, sequence, len(data)) + data


def frame(sock):
    def exact(n):
        data = b''
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise EOFError()
            data += chunk
        return data
    kind, seq, count = struct.unpack('>cQI', exact(13))
    return kind, seq, exact(count)


class SessionIdentityTests(unittest.TestCase):
    def test_one_daemon_multiplexes_isolated_sessions_and_reattaches(self):
        with tempfile.TemporaryDirectory(prefix='omg-host-', dir='/tmp') as directory:
            daemon = subprocess.Popen([str(BINARY), 'host', directory, '--', '/bin/sh', '-i'])
            sockets = []
            pids = []
            try:
                path = directory + '/host.sock'
                for _ in range(100):
                    if os.path.exists(path):
                        break
                    time.sleep(.02)
                def connect():
                    s = socket.socket(socket.AF_UNIX)
                    s.settimeout(5)
                    s.connect(path)
                    sockets.append(s)
                    return s
                def event(s, wanted, kind):
                    for _ in range(100):
                        k, stream, data = frame(s)
                        if k == b'E':
                            self.fail(data.decode())
                        if k != b'D':
                            continue
                        inner, seq, count = struct.unpack('>cQI', data[:13])
                        self.assertEqual(count, len(data)-13)
                        if stream == wanted and inner == kind:
                            return seq, data[13:]
                    self.fail('missing event')
                s = connect()
                ids = [b'11111111-1111-1111-1111-111111111111', b'22222222-2222-2222-2222-222222222222']
                info = []
                for stream, identity in enumerate(ids, 1):
                    s.sendall(encode(b'H', stream, identity))
                    _, data = event(s, stream, b'J')
                    info.append(json.loads(data))
                    pids.append(info[-1]['pid'])
                    seq, _ = event(s, stream, b'S')
                    s.sendall(encode(b'D', stream, encode(b'A', seq)))
                    s.sendall(encode(b'D', stream, encode(b'W')))
                    event(s, stream, b'W')
                self.assertNotEqual(pids[0], pids[1])
                for pid in pids:
                    parent = subprocess.check_output(['ps', '-p', str(pid), '-o', 'ppid='], text=True)
                    self.assertEqual(int(parent.strip()), daemon.pid)
                # One transport dies: both PTYs remain owned by the host.
                s.close()
                time.sleep(.05)
                s = connect()
                for stream, identity in enumerate(ids, 1):
                    s.sendall(encode(b'H', stream, identity))
                    _, data = event(s, stream, b'J')
                    self.assertEqual(json.loads(data)['pid'], pids[stream-1])
                    seq, _ = event(s, stream, b'S')
                    s.sendall(encode(b'D', stream, encode(b'A', seq)))
                    s.sendall(encode(b'D', stream, encode(b'W')))
                    event(s, stream, b'W')
                for stream in [1, 2]:
                    s.sendall(encode(b'D', stream, encode(b'I', 0, b'exit\n')))
                    event(s, stream, b'X')
                # Existing dead identity must not create a replacement shell.
                s.sendall(encode(b'H', 3, ids[0]))
                while True:
                    kind, stream, _ = frame(s)
                    if stream == 3:
                        self.assertEqual(kind, b'E')
                        break
            finally:
                for s in sockets:
                    s.close()
                daemon.terminate()
                daemon.wait(timeout=5)
                for pid in pids:
                    try:
                        os.killpg(pid, 9)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__':
    unittest.main()
