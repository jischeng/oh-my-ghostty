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


if __name__ == '__main__': unittest.main()
