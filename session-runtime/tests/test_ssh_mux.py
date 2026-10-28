"""Opt-in SSH check: set OMG_SSH_TEST_CONFIG to a deployment connection JSON."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import uuid
from test_sessions import encode, frame


@unittest.skipUnless(os.environ.get('OMG_SSH_TEST_CONFIG'), 'requires explicit SSH deployment configuration')
class SSHMultiplexTests(unittest.TestCase):
    def test_two_panes_share_ssh_and_survive_transport_restart(self):
        binary = Path(__file__).resolve().parents[1] / 'target/debug/omgd'
        with tempfile.TemporaryDirectory(prefix='omg-mux-', dir='/tmp') as directory:
            path = directory + '/s'
            identities = [str(uuid.uuid4()).encode(), str(uuid.uuid4()).encode()]
            clients = []
            relay = None
            def start():
                p = subprocess.Popen([str(binary), 'connect', path, os.environ['OMG_SSH_TEST_CONFIG']], stderr=subprocess.DEVNULL)
                for _ in range(1500):
                    if os.path.exists(path):
                        return p
                    time.sleep(.02)
                raise TimeoutError('relay startup')
            def attach(identity):
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(10)
                s.connect(path)
                clients.append(s)
                s.sendall(encode(b'H', 0, identity))
                kind, _, data = frame(s)
                self.assertEqual(kind, b'J')
                info = json.loads(data)
                kind, seq, _ = frame(s)
                self.assertEqual(kind, b'S')
                s.sendall(encode(b'A', seq))
                s.sendall(encode(b'W'))
                while frame(s)[0] != b'W':
                    pass
                return s, info
            try:
                relay = start()
                one, a = attach(identities[0])
                two, b = attach(identities[1])
                self.assertNotEqual(a['pid'], b['pid'])
                children = subprocess.check_output(['pgrep', '-P', str(relay.pid)], text=True).split()
                self.assertEqual(len(children), 1, 'one SSH child for both panes')
                ssh_pid = int(children[0])
                os.kill(ssh_pid, 15)
                relay.wait(timeout=10)
                one.close()
                two.close()
                relay = start()
                one, again_a = attach(identities[0])
                two, again_b = attach(identities[1])
                self.assertEqual(a['pid'], again_a['pid'])
                self.assertEqual(b['pid'], again_b['pid'])
                one.sendall(encode(b'I', 0, b'sleep 60\n'))
                time.sleep(.2)
                one.sendall(encode(b'I', 0, b'\x03'))
                one.sendall(encode(b'I', 0, b'printf "MUX_%s_OK\\n" SIGNAL\n'))
                data = b''
                while b'MUX_SIGNAL_OK' not in data:
                    kind, _, payload = frame(one)
                    if kind == b'O':
                        data += payload
                for s in [one, two]:
                    s.sendall(encode(b'K'))
                    while frame(s)[0] != b'X':
                        pass
            finally:
                for s in clients:
                    s.close()
                if relay is not None and relay.poll() is None:
                    relay.terminate()
                    relay.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
