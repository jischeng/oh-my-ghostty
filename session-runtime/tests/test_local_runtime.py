"""Local holder lifetime, launch and catalogue contract."""
import base64
import hashlib
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
import uuid
from test_sessions import BINARY, encode, frame


def wait_socket(path, process):
    for _ in range(250):
        if path.exists():
            socket_probe = socket.socket(socket.AF_UNIX)
            try:
                socket_probe.connect(str(path))
            except OSError:
                socket_probe.close()
            else:
                socket_probe.close()
                return
        if process.poll() is not None:
            raise RuntimeError("local host exited before becoming ready")
        time.sleep(.02)
    raise TimeoutError("local host startup")


def wait_holders_stopped(root):
    deadline = time.monotonic() + 5
    while list(root.glob("*.ctl")) and time.monotonic() < deadline:
        time.sleep(.02)
    if list(root.glob("*.ctl")):
        raise TimeoutError("local holder shutdown")


def next_inner_event(stream, stream_id):
    while True:
        kind, outer_id, data = frame(stream)
        if kind == b"E" and outer_id == stream_id:
            raise AssertionError(data.decode(errors="replace"))
        if kind != b"D" or outer_id != stream_id:
            continue
        inner, sequence, count = struct.unpack(">cQI", data[:13])
        if count != len(data) - 13:
            raise AssertionError("invalid inner frame length")
        return inner, sequence, data[13:]


def inner_event(stream, stream_id, wanted):
    while True:
        kind, sequence, data = next_inner_event(stream, stream_id)
        if kind == wanted:
            return sequence, data


class LocalRuntimeTests(unittest.TestCase):
    def test_holder_survives_broker_restart_and_initial_input_is_not_replayed(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-runtime-", dir="/tmp") as directory:
            root = Path(directory)
            host_socket = root / "host.sock"
            marker = root / "startup.txt"
            session_id = str(uuid.uuid4())
            policy = {
                "detached_ttl_seconds": 259200,
                "expires_at": None,
                "close_on_agent_done": False,
                "agent_done_grace_seconds": 60,
                "terminate_grace_seconds": 1,
                "host_idle_seconds": 300,
                "record_retention_seconds": 604800,
            }
            daemon = subprocess.Popen([
                str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
            ])
            live_shell_pid = None
            attached = []
            try:
                wait_socket(host_socket, daemon)
                transport = socket.socket(socket.AF_UNIX)
                transport.settimeout(8)
                transport.connect(str(host_socket))

                # A catalogue read is available before any session exists.
                empty = subprocess.check_output(
                    [str(BINARY), "list-local", str(host_socket)], timeout=5
                )
                self.assertEqual(json.loads(empty), [])
                self.assertEqual(list((root / "sessions").glob("*.json")), [])

                launch = {
                    "argv": ["/bin/sh", "-i"],
                    "env": {
                        "HOME": os.environ.get("HOME", directory),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TERM": "xterm-256color",
                    },
                    "cwd": directory,
                    "cols": 87,
                    "rows": 31,
                    "pixel_width": 1305,
                    "pixel_height": 651,
                    "input_base64": base64.b64encode(
                        f"printf 'ONCE\\n' >> {marker}\n".encode()
                    ).decode(),
                }
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    # Local launch.cwd is authoritative; legacy request cwd is ignored.
                    "cwd": "/definitely/not/a/directory",
                    "launch": launch,
                }
                transport.sendall(encode(b"C", 1, json.dumps(request).encode()))
                _, info_data = inner_event(transport, 1, b"J")
                info = json.loads(info_data)
                live_shell_pid = info["pid"]
                self.assertEqual(info["version"], 2)
                self.assertEqual(
                    (info["cols"], info["rows"], info["pixel_width"], info["pixel_height"]),
                    (87, 31, 1305, 651),
                )
                snapshot_seq, _ = inner_event(transport, 1, b"S")
                transport.sendall(encode(b"D", 1, encode(b"A", snapshot_seq)))
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(marker.exists(), "one-time startup input was not delivered")
                self.assertEqual(marker.read_text().splitlines(), ["ONCE"])

                # accept() may preserve O_NONBLOCK from the listener on macOS.
                # A controller which writes just after accept must not see EOF.
                control_path = root / (
                    hashlib.sha256(session_id.encode()).hexdigest()[:16] + ".ctl"
                )
                record = json.loads((root / "sessions" / (session_id + ".json")).read_text())
                with socket.socket(socket.AF_UNIX) as control:
                    control.settimeout(3)
                    control.connect(str(control_path))
                    time.sleep(.1)
                    control.sendall(encode(b"V", 0, json.dumps({
                        "id": session_id,
                        "generation": record["generation"],
                        "capability": record["holder_capability"],
                    }).encode()))
                    kind, _, status = frame(control)
                    self.assertEqual(kind, b"V")
                    self.assertEqual(json.loads(status)["session_pid"], live_shell_pid)
                time.sleep(.6)

                listing = subprocess.check_output(
                    [str(BINARY), "list-local", str(host_socket)], timeout=5
                )
                entries = json.loads(listing)
                self.assertEqual(len(entries), 1)
                entry = entries[0]
                self.assertEqual(entry["id"], session_id)
                self.assertEqual(entry["pid"], live_shell_pid)
                self.assertEqual(entry["cwd"], str(Path(directory).resolve()))
                self.assertNotIn("holder_capability", entry)
                self.assertNotIn("env", entry)
                self.assertNotIn("argv", entry)

                # A crashed broker cannot own or recreate the persistent holder.
                transport.close()
                daemon.kill()
                daemon.wait(timeout=5)
                os.kill(live_shell_pid, 0)
                daemon = subprocess.Popen([
                    str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
                ])
                wait_socket(host_socket, daemon)

                reattached = socket.socket(socket.AF_UNIX)
                reattached.settimeout(8)
                reattached.connect(str(host_socket))
                attached.append(reattached)
                attach_request = {
                    "id": session_id,
                    "policy": policy,
                    "create": False,
                    "cwd": None,
                }
                reattached.sendall(
                    encode(b"C", 1, json.dumps(attach_request).encode())
                )
                _, attach_info = inner_event(reattached, 1, b"J")
                self.assertEqual(json.loads(attach_info)["pid"], live_shell_pid)
                self.assertEqual(marker.read_text().splitlines(), ["ONCE"])
            finally:
                for stream in attached:
                    stream.close()
                if live_shell_pid:
                    try:
                        os.killpg(live_shell_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    wait_holders_stopped(root)
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_password_mode_and_final_runtime_are_reported(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-meta-", dir="/tmp") as directory:
            root = Path(directory)
            daemon = subprocess.Popen([
                str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
            ])
            stream = None
            try:
                wait_socket(root / "host.sock", daemon)
                stream = socket.socket(socket.AF_UNIX)
                stream.settimeout(8)
                stream.connect(str(root / "host.sock"))
                session_id = str(uuid.uuid4())
                policy = {
                    "detached_ttl_seconds": 259200,
                    "expires_at": None,
                    "close_on_agent_done": False,
                    "agent_done_grace_seconds": 60,
                    "terminate_grace_seconds": 1,
                    "host_idle_seconds": 300,
                    "record_retention_seconds": 604800,
                }
                launch = {
                    "argv": [
                        "/bin/sh", "-c",
                        "stty -echo; sleep 0.55; stty echo; sleep 0.15; exit 7",
                    ],
                    "env": {
                        "HOME": os.environ.get("HOME", directory),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TERM": "xterm-256color",
                    },
                    "cwd": directory,
                    "cols": 80,
                    "rows": 24,
                    "pixel_width": 640,
                    "pixel_height": 384,
                }
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    "cwd": directory,
                    "launch": launch,
                }
                stream.sendall(encode(b"C", 1, json.dumps(request).encode()))
                _, info_data = inner_event(stream, 1, b"J")
                info = json.loads(info_data)
                self.assertEqual(info["version"], 2)
                self.assertFalse(info["password_input"])
                snapshot_seq, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", snapshot_seq)))

                password_states = []
                final_runtime = None
                while True:
                    kind, _, data = next_inner_event(stream, 1)
                    if kind == b"M":
                        metadata = json.loads(data)
                        password_states.append(metadata["password_input"])
                        if not metadata["password_input"]:
                            final_runtime = metadata["runtime_ms"]
                    elif kind == b"X":
                        self.assertEqual(data, b"7")
                        break
                self.assertIn(True, password_states)
                self.assertIn(False, password_states)
                self.assertIsNotNone(final_runtime)
                self.assertGreaterEqual(final_runtime, 500)
            finally:
                if stream is not None:
                    stream.close()
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_resize_v2_preserves_pixels_and_legacy_resize_still_works(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-resize-", dir="/tmp") as directory:
            root = Path(directory)
            daemon = subprocess.Popen([
                str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
            ])
            streams = []
            pid = None
            try:
                wait_socket(root / "host.sock", daemon)
                stream = socket.socket(socket.AF_UNIX)
                stream.settimeout(8)
                stream.connect(str(root / "host.sock"))
                streams.append(stream)
                session_id = str(uuid.uuid4())
                policy = {
                    "detached_ttl_seconds": 259200,
                    "expires_at": None,
                    "close_on_agent_done": False,
                    "agent_done_grace_seconds": 60,
                    "terminate_grace_seconds": 1,
                    "host_idle_seconds": 300,
                    "record_retention_seconds": 604800,
                }
                launch = {
                    "argv": ["/bin/sh", "-i"],
                    "env": {
                        "HOME": os.environ.get("HOME", directory),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TERM": "xterm-256color",
                    },
                    "cwd": directory,
                    "cols": 80,
                    "rows": 24,
                    "pixel_width": 640,
                    "pixel_height": 384,
                }
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    "cwd": directory,
                    "launch": launch,
                }
                stream.sendall(encode(b"C", 1, json.dumps(request).encode()))
                _, info_data = inner_event(stream, 1, b"J")
                pid = json.loads(info_data)["pid"]
                snapshot_seq, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", snapshot_seq)))
                stream.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(stream, 1, b"W")

                stream.settimeout(2)
                response_started = time.monotonic()
                stream.sendall(
                    encode(
                        b"D",
                        1,
                        encode(b"I", 0, b"printf 'POLL_WAKE_OK\\n'\n"),
                    )
                )
                output = b""
                while time.monotonic() - response_started < 3:
                    kind, _, data = next_inner_event(stream, 1)
                    if kind == b"O":
                        output += data
                    if b"POLL_WAKE_OK" in output:
                        break
                self.assertIn(b"POLL_WAKE_OK", output)
                self.assertLess(time.monotonic() - response_started, 3)
                stream.settimeout(8)

                v2 = struct.pack(">HHHH", 92, 36, 1840, 900)
                stream.sendall(encode(b"D", 1, encode(b"R", 0, v2)))
                inner_event(stream, 1, b"R")
                attach = socket.socket(socket.AF_UNIX)
                attach.settimeout(8)
                attach.connect(str(root / "host.sock"))
                streams.append(attach)
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": False,
                    "cwd": None,
                }
                attach.sendall(encode(b"C", 2, json.dumps(request).encode()))
                _, info_data = inner_event(attach, 2, b"J")
                info = json.loads(info_data)
                self.assertEqual(
                    (info["cols"], info["rows"], info["pixel_width"], info["pixel_height"]),
                    (92, 36, 1840, 900),
                )

                legacy = struct.pack(">HH", 80, 24)
                stream.sendall(encode(b"D", 1, encode(b"R", 0, legacy)))
                inner_event(stream, 1, b"R")
                third = socket.socket(socket.AF_UNIX)
                third.settimeout(8)
                third.connect(str(root / "host.sock"))
                streams.append(third)
                third.sendall(encode(b"C", 3, json.dumps(request).encode()))
                _, info_data = inner_event(third, 3, b"J")
                info = json.loads(info_data)
                self.assertEqual(
                    (info["cols"], info["rows"], info["pixel_width"], info["pixel_height"]),
                    (80, 24, 640, 384),
                )
            finally:
                for stream in streams:
                    stream.close()
                if pid:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    wait_holders_stopped(root)
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def _snapshot_contains_text(self, snap_bytes, text):
        raw = text.encode("utf-8")
        if raw in snap_bytes:
            return True
        # Ghostty GHOSTSNP encodes non-default-styled ASCII runs as 4-byte cells:
        # [0x04, lo, hi, 0x00] where codepoint == ((lo | (hi << 8)) >> 2).
        decoded = bytearray()
        i = 0
        limit = len(snap_bytes) - 3
        while i < limit:
            if snap_bytes[i] == 0x04 and snap_bytes[i + 3] == 0x00:
                cp = (snap_bytes[i + 1] | (snap_bytes[i + 2] << 8)) >> 2
                if 0x20 <= cp <= 0x7E:
                    decoded.append(cp)
                    i += 4
                    continue
            i += 1
        return raw in decoded

    def _find_holder_pid(self, root, session_id):
        import sys
        ctl_path = root / (hashlib.sha256(session_id.encode()).hexdigest()[:16] + ".ctl")
        if not ctl_path.exists():
            return None
        with socket.socket(socket.AF_UNIX) as probe:
            probe.settimeout(2)
            probe.connect(str(ctl_path))
            if sys.platform == "darwin":
                return struct.unpack("i", probe.getsockopt(0, 2, 4))[0]
            creds = probe.getsockopt(socket.SOL_SOCKET, 17, 12)
            return struct.unpack("3i", creds)[0]

    def test_sigterm_shutdown_saves_snapshot_and_resurrects_with_cwd_fallback_and_u_frame(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-resurrect-", dir="/tmp") as directory:
            root = Path(directory)
            fake_home = root / "home"
            fake_home.mkdir(mode=0o700)
            work_cwd = root / "ephemeral-cwd"
            work_cwd.mkdir(mode=0o700)
            marker = root / "once.txt"
            policy = {
                "detached_ttl_seconds": 259200,
                "expires_at": None,
                "close_on_agent_done": False,
                "agent_done_grace_seconds": 60,
                "terminate_grace_seconds": 1,
                "host_idle_seconds": 300,
                "record_retention_seconds": 604800,
            }
            daemon = subprocess.Popen(
                [str(BINARY), "host-local", directory, "--", "/bin/sh", "-i"],
                env={**os.environ, "HOME": str(fake_home), "SHELL": "/bin/sh"},
            )
            streams = []
            pids = []
            try:
                wait_socket(root / "host.sock", daemon)
                # Session 1: terminated via SIGTERM to holder.
                s1 = str(uuid.uuid4())
                t1 = socket.socket(socket.AF_UNIX)
                t1.settimeout(8)
                t1.connect(str(root / "host.sock"))
                streams.append(t1)
                launch1 = {
                    "argv": ["/bin/sh", "-i"],
                    "env": {
                        "HOME": str(fake_home),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "SHELL": "/bin/sh",
                        "TERM": "xterm-256color",
                    },
                    "cwd": str(work_cwd),
                    "cols": 84,
                    "rows": 28,
                    "pixel_width": 840,
                    "pixel_height": 560,
                    "input_base64": base64.b64encode(
                        f"printf 'ONCE_ONLY\\n' >> {marker}\n".encode()
                    ).decode(),
                }
                t1.sendall(encode(b"C", 1, json.dumps({
                    "id": s1,
                    "policy": policy,
                    "create": True,
                    "cwd": str(work_cwd),
                    "launch": launch1,
                }).encode()))
                _, j1 = inner_event(t1, 1, b"J")
                pid1 = json.loads(j1)["pid"]
                pids.append(pid1)
                seq1, _ = inner_event(t1, 1, b"S")
                t1.sendall(encode(b"D", 1, encode(b"A", seq1)))
                t1.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(t1, 1, b"W")
                t1.sendall(encode(b"D", 1, encode(b"I", 0, b"printf 'VT_%s\\n' 'SNAP_ONE'\n")))
                deadline = time.monotonic() + 5
                output = b""
                while b"VT_SNAP_ONE" not in output and time.monotonic() < deadline:
                    kind, _, data = next_inner_event(t1, 1)
                    if kind == b"O":
                        output += data
                self.assertIn(b"VT_SNAP_ONE", output)
                time.sleep(0.05)
                self.assertEqual(marker.read_text().splitlines(), ["ONCE_ONLY"])

                # Session 2: terminated via SIGTERM directly to child, resumed via b'U'.
                s2 = str(uuid.uuid4())
                t2 = socket.socket(socket.AF_UNIX)
                t2.settimeout(8)
                t2.connect(str(root / "host.sock"))
                streams.append(t2)
                t2.sendall(encode(b"C", 2, json.dumps({
                    "id": s2,
                    "policy": policy,
                    "create": True,
                    "cwd": directory,
                    "launch": {
                        "argv": ["/bin/sh", "-i"],
                        "env": {
                            "HOME": str(fake_home),
                            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                            "SHELL": "/bin/sh",
                            "TERM": "xterm-256color",
                        },
                        "cwd": directory,
                        "cols": 80,
                        "rows": 24,
                        "pixel_width": 640,
                        "pixel_height": 384,
                    },
                }).encode()))
                _, j2 = inner_event(t2, 2, b"J")
                pid2 = json.loads(j2)["pid"]
                pids.append(pid2)
                seq2, _ = inner_event(t2, 2, b"S")
                t2.sendall(encode(b"D", 2, encode(b"A", seq2)))
                t2.sendall(encode(b"D", 2, encode(b"W")))
                inner_event(t2, 2, b"W")
                t2.sendall(encode(b"D", 2, encode(b"I", 0, b"printf 'VT_%s\\n' 'SNAP_TWO' && exec sleep 60\n")))
                out2 = b""
                deadline = time.monotonic() + 5
                while b"VT_SNAP_TWO" not in out2 and time.monotonic() < deadline:
                    kind, _, data = next_inner_event(t2, 2)
                    if kind == b"O":
                        out2 += data
                self.assertIn(b"VT_SNAP_TWO", out2)
                time.sleep(0.1)

                holder1_pid = self._find_holder_pid(root, s1)
                self.assertIsNotNone(holder1_pid)
                os.kill(holder1_pid, signal.SIGTERM)
                os.kill(pid2, signal.SIGTERM)

                rec1_path = root / "sessions" / f"{s1}.json"
                rec2_path = root / "sessions" / f"{s2}.json"
                snap1_path = root / "sessions" / f"{s1}.snapshot"
                snap2_path = root / "sessions" / f"{s2}.snapshot"
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    r1 = json.loads(rec1_path.read_text())
                    r2 = json.loads(rec2_path.read_text())
                    if r1.get("ended") == "lost" and r1.get("pid") is None and r2.get("ended") == "lost" and r2.get("pid") is None:
                        break
                    time.sleep(0.05)
                self.assertEqual(r1["ended"], "lost")
                self.assertIsNone(r1["pid"])
                self.assertIsNotNone(r1.get("boot_time"))
                self.assertTrue(snap1_path.exists())
                self.assertEqual(snap1_path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(r2["ended"], "lost")
                self.assertTrue(snap2_path.exists())
                t1.close()
                t2.close()
                wait_holders_stopped(root)

                # Delete original cwd before resurrecting session 1 -> must fall back to HOME.
                work_cwd.rmdir()
                resurrect_sock = socket.socket(socket.AF_UNIX)
                resurrect_sock.settimeout(8)
                resurrect_sock.connect(str(root / "host.sock"))
                streams.append(resurrect_sock)
                resurrect_sock.sendall(encode(b"C", 3, json.dumps({
                    "id": s1,
                    "policy": policy,
                    "create": False,
                    "cwd": None,
                    "resurrect_launch": {
                        "argv": ["/bin/sh", "-i"],
                        "env": {
                            "HOME": str(fake_home),
                            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                            "SHELL": "/bin/sh",
                            "TERM": "xterm-256color",
                        },
                        "cwd": str(work_cwd),
                        "cols": 90,
                        "rows": 30,
                        "pixel_width": 900,
                        "pixel_height": 600,
                    },
                }).encode()))
                _, j_res = inner_event(resurrect_sock, 3, b"J")
                info_res = json.loads(j_res)
                pids.append(info_res["pid"])
                self.assertNotEqual(info_res["pid"], pid1)
                self.assertEqual((info_res["cols"], info_res["rows"]), (90, 30))
                s_seq, snap_bytes = inner_event(resurrect_sock, 3, b"S")
                self.assertIn(b"VT_SNAP_ONE", snap_bytes)
                self.assertTrue(self._snapshot_contains_text(snap_bytes, "Session resurrected after system restart"))
                resurrect_sock.sendall(encode(b"D", 3, encode(b"A", s_seq)))
                resurrect_sock.sendall(encode(b"D", 3, encode(b"W")))
                inner_event(resurrect_sock, 3, b"W")
                # Confirm initial input_base64 was NOT replayed.
                time.sleep(0.2)
                self.assertEqual(marker.read_text().splitlines(), ["ONCE_ONLY"])
                resurrect_sock.sendall(encode(b"D", 3, encode(b"I", 0, b"pwd -P\n")))
                live_out = b""
                deadline = time.monotonic() + 5
                resolved_home = str(fake_home.resolve()).encode()
                while resolved_home not in live_out and time.monotonic() < deadline:
                    kind, _, data = next_inner_event(resurrect_sock, 3)
                    if kind == b"O":
                        live_out += data
                self.assertIn(resolved_home, live_out)
                resurrect_sock.sendall(encode(b"D", 3, encode(b"K")))
                inner_event(resurrect_sock, 3, b"X")

                # Session 2: resurrect explicitly via b'U' (mobile contract).
                u_sock = socket.socket(socket.AF_UNIX)
                u_sock.settimeout(8)
                u_sock.connect(str(root / "host.sock"))
                streams.append(u_sock)
                u_sock.sendall(encode(b"U", 4, json.dumps({
                    "id": s2,
                    "generation": r2["generation"],
                }).encode()))
                _, j_u = inner_event(u_sock, 4, b"J")
                info_u = json.loads(j_u)
                pids.append(info_u["pid"])
                self.assertNotEqual(info_u["generation"], r2["generation"])
                u_seq, u_snap = inner_event(u_sock, 4, b"S")
                self.assertIn(b"VT_SNAP_TWO", u_snap)
                self.assertTrue(self._snapshot_contains_text(u_snap, "Session resurrected after system restart"))
                u_sock.sendall(encode(b"D", 4, encode(b"A", u_seq)))
                u_sock.sendall(encode(b"D", 4, encode(b"W")))
                inner_event(u_sock, 4, b"W")
                u_sock.sendall(encode(b"D", 4, encode(b"I", 0, b"printf 'U_FRAME_LIVE\\n'\n")))
                u_out = b""
                deadline = time.monotonic() + 5
                while b"U_FRAME_LIVE" not in u_out and time.monotonic() < deadline:
                    kind, _, data = next_inner_event(u_sock, 4)
                    if kind == b"O":
                        u_out += data
                self.assertIn(b"U_FRAME_LIVE", u_out)
                u_sock.sendall(encode(b"D", 4, encode(b"K")))
                inner_event(u_sock, 4, b"X")
            finally:
                for stream in streams:
                    stream.close()
                for p in pids:
                    try:
                        os.killpg(p, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                wait_holders_stopped(root)
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_manual_retry_preserves_resurrect_launch_and_sibling_migration_bypasses_grace(self):
        import threading

        # 1. Relay manual_retry preserves resurrect_launch across b'E' -> b'R'.
        with tempfile.TemporaryDirectory(prefix="omg-retry-resurrect-", dir="/tmp") as directory:
            root = Path(directory)
            host_dir = root / "host"
            host_dir.mkdir(mode=0o700)
            host_sock = host_dir / "host.sock"
            seen_requests = []

            srv = socket.socket(socket.AF_UNIX)
            srv.bind(str(host_sock))
            srv.listen(4)

            stop_host = threading.Event()

            def fake_host():
                while not stop_host.is_set() and len(seen_requests) < 2:
                    try:
                        conn, _ = srv.accept()
                    except OSError:
                        break
                    conn.settimeout(5)
                    try:
                        conn.sendall(encode(
                            b"P", 0,
                            b"durable-close/1,strict-open/1,local-launch/1,local-resurrect/1",
                        ))
                        while len(seen_requests) < 2:
                            kind, sid, data = frame(conn)
                            if kind == b"C":
                                seen_requests.append(json.loads(data))
                                err_msg = (
                                    b"transient open failure"
                                    if len(seen_requests) == 1
                                    else b"second failure stops"
                                )
                                conn.sendall(encode(b"E", sid, err_msg))
                    except (EOFError, BrokenPipeError, ConnectionResetError, TimeoutError):
                        pass
                    finally:
                        conn.close()

            thread = threading.Thread(target=fake_host, daemon=True)
            thread.start()
            config = root / "conn.json"
            config.write_text(json.dumps({
                "transport": "local",
                "executable": "/usr/bin/ssh",
                "arguments": [],
                "cwd": directory,
                "local_shell": "/bin/sh",
                "bundle": str(BINARY.parent),
                "revision": "test-rev",
                "local_state_directory": str(host_dir),
                "policy": {},
            }))
            relay_sock = root / "relay.sock"
            relay = subprocess.Popen([str(BINARY), "connect", str(relay_sock), str(config)])
            peer = socket.socket(socket.AF_UNIX)
            try:
                wait_socket(relay_sock, relay)
                peer.settimeout(5)
                peer.connect(str(relay_sock))
                session_id = str(uuid.uuid4())
                peer.sendall(encode(b"H", 0, json.dumps({
                    "id": session_id,
                    "create": False,
                    "policy": {},
                    "resurrect_launch": {
                        "argv": ["/bin/sh", "-i"],
                        "env": {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
                        "cwd": directory,
                        "cols": 80,
                        "rows": 24,
                        "pixel_width": 640,
                        "pixel_height": 384,
                    },
                }).encode()))
                while True:
                    kind, _, _ = frame(peer)
                    if kind != b"T":
                        break
                self.assertEqual(kind, b"E")
                subprocess.check_call([str(BINARY), "retry-local", str(relay_sock)], timeout=5)
                while True:
                    kind2, _, _ = frame(peer)
                    if kind2 != b"T":
                        break
                self.assertEqual(kind2, b"E")
                thread.join(timeout=5)
                self.assertEqual(len(seen_requests), 2)
                self.assertIn("resurrect_launch", seen_requests[0])
                self.assertIn("resurrect_launch", seen_requests[1])
            finally:
                stop_host.set()
                peer.close()
                relay.terminate()
                relay.wait(timeout=5)
                srv.close()

        # 2. Prior-boot stale ended:None bypasses 10s grace and migrates sibling root.
        with tempfile.TemporaryDirectory(prefix="omg-sibling-migrate-", dir="/tmp") as directory:
            root = Path(directory)
            fake_home = root / "home"
            run_root = fake_home / ".omg" / "run"
            old_dir = run_root / "oldhash111"
            new_dir = run_root / "newhash222"
            (old_dir / "sessions").mkdir(parents=True, mode=0o700)
            new_dir.mkdir(parents=True, mode=0o700)
            run_root.chmod(0o700)
            (fake_home / ".omg").chmod(0o700)
            fake_home.chmod(0o700)
            old_dir.chmod(0o700)
            (old_dir / "sessions").chmod(0o700)

            session_id = str(uuid.uuid4())
            policy = {
                "detached_ttl_seconds": 259200,
                "expires_at": None,
                "close_on_agent_done": False,
                "agent_done_grace_seconds": 60,
                "terminate_grace_seconds": 1,
                "host_idle_seconds": 300,
                "record_retention_seconds": 604800,
            }
            old_daemon = subprocess.Popen(
                [str(BINARY), "host-local", str(old_dir), "--", "/bin/sh", "-i"],
                env={**os.environ, "HOME": str(fake_home), "SHELL": "/bin/sh"},
            )
            pids = []
            try:
                wait_socket(old_dir / "host.sock", old_daemon)
                s_old = socket.socket(socket.AF_UNIX)
                s_old.settimeout(8)
                s_old.connect(str(old_dir / "host.sock"))
                s_old.sendall(encode(b"C", 1, json.dumps({
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    "cwd": directory,
                    "launch": {
                        "argv": ["/bin/sh", "-i"],
                        "env": {"HOME": str(fake_home), "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
                        "cwd": directory,
                        "cols": 80,
                        "rows": 24,
                        "pixel_width": 640,
                        "pixel_height": 384,
                    },
                }).encode()))
                _, j_old = inner_event(s_old, 1, b"J")
                old_pid = json.loads(j_old)["pid"]
                seq_old, _ = inner_event(s_old, 1, b"S")
                s_old.sendall(encode(b"D", 1, encode(b"A", seq_old)))
                s_old.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(s_old, 1, b"W")
                s_old.sendall(encode(b"D", 1, encode(b"I", 0, b"printf 'MIGRATED_VT\\n'\n")))
                out = b""
                deadline = time.monotonic() + 5
                while b"MIGRATED_VT" not in out and time.monotonic() < deadline:
                    k, _, d = next_inner_event(s_old, 1)
                    if k == b"O":
                        out += d
                self.assertIn(b"MIGRATED_VT", out)
                holder_pid = self._find_holder_pid(old_dir, session_id)
                self.assertIsNotNone(holder_pid)
                os.kill(holder_pid, signal.SIGTERM)
                wait_holders_stopped(old_dir)
                s_old.close()
            finally:
                try:
                    os.killpg(old_pid, signal.SIGKILL)
                except Exception:
                    pass
                old_daemon.terminate()
                old_daemon.wait(timeout=5)

            # Simulate ungraceful power loss from a prior boot (ended: None, old boot_time).
            rec_old_path = old_dir / "sessions" / f"{session_id}.json"
            rec = json.loads(rec_old_path.read_text())
            rec["ended"] = None
            rec["boot_time"] = 100
            rec["updated_at"] = 100
            rec["pid"] = 999999
            rec_old_path.write_text(json.dumps(rec))

            new_daemon = subprocess.Popen(
                [str(BINARY), "host-local", str(new_dir), "--", "/bin/sh", "-i"],
                env={**os.environ, "HOME": str(fake_home), "SHELL": "/bin/sh"},
            )
            try:
                wait_socket(new_dir / "host.sock", new_daemon)
                started = time.monotonic()
                s_new = socket.socket(socket.AF_UNIX)
                s_new.settimeout(8)
                s_new.connect(str(new_dir / "host.sock"))
                s_new.sendall(encode(b"C", 2, json.dumps({
                    "id": session_id,
                    "policy": policy,
                    "create": False,
                    "cwd": None,
                    "resurrect_launch": {
                        "argv": ["/bin/sh", "-i"],
                        "env": {"HOME": str(fake_home), "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
                        "cwd": directory,
                        "cols": 80,
                        "rows": 24,
                        "pixel_width": 640,
                        "pixel_height": 384,
                    },
                }).encode()))
                _, j_new = inner_event(s_new, 2, b"J")
                pids.append(json.loads(j_new)["pid"])
                elapsed = time.monotonic() - started
                self.assertLess(elapsed, 4.0, "prior boot stale record should bypass 10s grace")
                seq_new, snap_new = inner_event(s_new, 2, b"S")
                self.assertIn(b"MIGRATED_VT", snap_new)
                s_new.sendall(encode(b"D", 2, encode(b"A", seq_new)))
                s_new.sendall(encode(b"D", 2, encode(b"W")))
                inner_event(s_new, 2, b"W")
                self.assertTrue((new_dir / "sessions" / f"{session_id}.json").exists())
                self.assertTrue((new_dir / "sessions" / f"{session_id}.snapshot").exists())
                self.assertFalse(rec_old_path.exists())
                s_new.sendall(encode(b"D", 2, encode(b"K")))
                inner_event(s_new, 2, b"X")
                s_new.close()
            finally:
                for p in pids:
                    try:
                        os.killpg(p, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                wait_holders_stopped(new_dir)
                new_daemon.terminate()
                new_daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
