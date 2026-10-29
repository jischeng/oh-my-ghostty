"""New remote PTYs inherit cwd; reattach cannot reset it or affect sibling PTYs."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import uuid
from test_sessions import BINARY, encode, frame


class SplitDirectoryTests(unittest.TestCase):
    def test_cwd_is_child_scoped_and_only_used_for_new_sessions(self):
        with tempfile.TemporaryDirectory(prefix="omg-split-", dir="/tmp") as directory:
            project = Path(directory) / "项目 space ' ; $(literal)"
            sibling = Path(directory) / "second"
            project.mkdir()
            sibling.mkdir()
            daemon = subprocess.Popen([str(BINARY), "host", directory, "--", "/bin/sh", "-i"])
            peers = []
            pids = []
            try:
                path = directory + "/host.sock"
                for _ in range(100):
                    if os.path.exists(path):
                        break
                    time.sleep(.02)
                def connect():
                    peer = socket.socket(socket.AF_UNIX)
                    peer.settimeout(5)
                    peer.connect(path)
                    peers.append(peer)
                    return peer
                def event(peer, stream, wanted, error=False):
                    for _ in range(200):
                        kind, channel, payload = frame(peer)
                        if kind == b'E' and channel == stream:
                            if error:
                                return payload
                            self.fail(payload.decode())
                        if kind != b'D' or channel != stream:
                            continue
                        inner, seq, size = struct.unpack('>cQI', payload[:13])
                        self.assertEqual(size, len(payload) - 13)
                        if inner == wanted:
                            return seq, payload[13:]
                    self.fail('missing event')
                def attach(peer, stream, identity, cwd=None, create=True):
                    request = dict(id=identity, create=create, policy={})
                    if cwd is not None:
                        request['cwd'] = str(cwd)
                    peer.sendall(encode(b'C', stream, json.dumps(request).encode()))
                    _, data = event(peer, stream, b'J')
                    pid = json.loads(data)['pid']
                    seq, _ = event(peer, stream, b'S')
                    peer.sendall(encode(b'D', stream, encode(b'A', seq)))
                    peer.sendall(encode(b'D', stream, encode(b'W')))
                    event(peer, stream, b'W')
                    return pid
                def cwd(peer, stream):
                    # Prefix/suffix are emitted separately so terminal echo
                    # cannot satisfy the output marker assertion.
                    command = b"printf '\\nSPLIT_%s%s%s_END\\n' CWD= \"$PWD\" =CWD\n"
                    peer.sendall(encode(b'D', stream, encode(b'I', 0, command)))
                    data = b''
                    marker = b'SPLIT_CWD='
                    for _ in range(100):
                        _, output = event(peer, stream, b'O')
                        data += output
                        if marker in data and b'=CWD_END' in data:
                            return data.split(marker, 1)[1].split(b'=CWD_END', 1)[0].decode()
                    self.fail('missing cwd output')
                peer = connect()
                one, two = str(uuid.uuid4()), str(uuid.uuid4())
                pids.append(attach(peer, 1, one, project))
                self.assertEqual(Path(cwd(peer, 1)).resolve(), project.resolve())
                pids.append(attach(peer, 2, two, sibling))
                self.assertEqual(Path(cwd(peer, 2)).resolve(), sibling.resolve())
                self.assertEqual(Path(cwd(peer, 1)).resolve(), project.resolve())
                self.assertNotEqual(pids[0], pids[1])
                peer.close()
                time.sleep(.05)
                peer = connect()
                # Even an old/malicious client supplying cwd during reattach
                # must not change the existing PTY or create a replacement.
                self.assertEqual(attach(peer, 1, one, sibling, create=False), pids[0])
                self.assertEqual(Path(cwd(peer, 1)).resolve(), project.resolve())
                for bad in ['relative', directory + '/missing', '/bad\0path']:
                    identity = str(uuid.uuid4())
                    peer.sendall(encode(b'C', 8, json.dumps(dict(id=identity, create=True, policy={}, cwd=bad)).encode()))
                    self.assertTrue(event(peer, 8, b'J', error=True))
                    self.assertFalse((Path(directory) / 'sessions' / (identity + '.created')).exists())
                # Older clients without cwd still open a session normally.
                pids.append(attach(peer, 3, str(uuid.uuid4())))
                peer.sendall(encode(b'D', 1, encode(b'I', 0, b'exit\n')))
                event(peer, 1, b'X')
                peer.sendall(encode(b'D', 3, encode(b'I', 0, b'exit\n')))
                event(peer, 3, b'X')
            finally:
                for peer in peers:
                    peer.close()
                # Signal only still-owned session leaders; exited PIDs can be
                # reused, and an already reaped child's process group is gone.
                for pid in pids:
                    if pid <= 1:
                        continue
                    parent = subprocess.run(['ps', '-p', str(pid), '-o', 'ppid='],
                                            capture_output=True, text=True).stdout.strip()
                    try:
                        if parent == str(daemon.pid) and os.getpgid(pid) == pid:
                            os.killpg(pid, 9)
                    except ProcessLookupError:
                        pass
                daemon.terminate()
                daemon.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
