"""Inline viewer integration on private PTYs; no SSH host or GUI is contacted."""
import base64
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import subprocess
import struct
import sys
import tempfile
import termios
import textwrap
import time
import unittest
import uuid

from test_sessions import BINARY, encode, frame


def private_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


class MiniVT:
    """Minimal VT100/DEC terminal simulator to inspect outer scrollback & active grid."""

    def __init__(self, cols: int, rows: int):
        self.cols = cols
        self.rows = rows
        self.scrollback: list[str] = []
        self.grid = [[" "] * cols for _ in range(rows)]
        self.cx = 0
        self.cy = 0
        self.pending_wrap = False
        self.autowrap = True
        self.cursor_visible = True
        self.scroll_top = 0
        self.scroll_bottom = rows - 1
        self._saved_primary = None
        self._saved_cursor = (0, 0, False)
        self.alt_screen = False
        self._buf = ""

    def resize(self, cols: int, rows: int):
        new_grid = [[" "] * cols for _ in range(rows)]
        for r in range(min(self.rows, rows)):
            for c in range(min(self.cols, cols)):
                new_grid[r][c] = self.grid[r][c]
        self.cols = cols
        self.rows = rows
        self.grid = new_grid
        self.cx = min(self.cx, cols - 1)
        self.cy = min(self.cy, rows - 1)
        self.pending_wrap = False
        self.scroll_top = 0
        self.scroll_bottom = rows - 1

    def _scroll_up(self):
        top = self.scroll_top
        bot = self.scroll_bottom
        evicted = "".join(self.grid[top]).rstrip(" ")
        if top == 0 and bot == self.rows - 1 and not self.alt_screen:
            self.scrollback.append(evicted)
        del self.grid[top]
        self.grid.insert(bot, [" "] * self.cols)

    def _linefeed(self):
        self.pending_wrap = False
        if self.cy == self.scroll_bottom:
            self._scroll_up()
        elif self.cy + 1 < self.rows:
            self.cy += 1

    def feed(self, data: bytes):
        self._buf += data.decode("utf-8", "replace")
        text = self._buf
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "\x18":
                i += 1
            elif ch == "\r":
                self.cx = 0
                self.pending_wrap = False
                i += 1
            elif ch == "\n":
                self._linefeed()
                i += 1
            elif ch == "\x07" or ch == "\x00":
                i += 1
            elif ch == "\x08":
                self.cx = max(0, self.cx - 1)
                self.pending_wrap = False
                i += 1
            elif ch == "\t":
                self.cx = min(self.cols - 1, (self.cx // 8 + 1) * 8)
                self.pending_wrap = False
                i += 1
            elif ch == "\x1b":
                if i + 1 >= n:
                    break
                nxt = text[i + 1]
                if nxt == "7":
                    self._saved_cursor = (self.cx, self.cy, self.pending_wrap)
                    i += 2
                elif nxt == "8":
                    self.cx, self.cy, self.pending_wrap = self._saved_cursor
                    i += 2
                elif nxt == "]":
                    # OSC .. BEL or ST (wait for complete terminator if split across chunks)
                    j = i + 2
                    terminated = False
                    while j < n:
                        if text[j] == "\x07":
                            j += 1
                            terminated = True
                            break
                        if text[j] == "\x1b":
                            if j + 1 >= n:
                                break
                            if text[j + 1] == "\\":
                                j += 2
                                terminated = True
                                break
                        j += 1
                    if not terminated:
                        break
                    i = j
                elif nxt in ("P", "_", "^", "X"):
                    j = i + 2
                    terminated = False
                    while j < n:
                        if text[j] == "\x1b":
                            if j + 1 >= n:
                                break
                            if text[j + 1] == "\\":
                                j += 2
                                terminated = True
                                break
                        j += 1
                    if not terminated:
                        break
                    i = j
                elif nxt == "[":
                    j = i + 2
                    while j < n and not ("@" <= text[j] <= "~"):
                        j += 1
                    if j >= n:
                        break
                    params_raw = text[i + 2 : j]
                    final = text[j]
                    i = j + 1
                    if params_raw == "!":
                        if final == "p":
                            self.autowrap = True
                            self.cursor_visible = True
                            self.scroll_top = 0
                            self.scroll_bottom = self.rows - 1
                            self.pending_wrap = False
                        continue
                    priv = params_raw[:1] in ("?", ">", "=")
                    body = params_raw[1:] if priv else params_raw
                    if body.endswith('"') or body.endswith("$") or body.endswith(" "):
                        continue
                    parts = [int(p) if p.isdigit() else 0 for p in body.split(";")] if body else []
                    if priv and params_raw.startswith("?"):
                        if final in ("h", "l"):
                            enabled = final == "h"
                            for code in parts:
                                if code == 7:
                                    self.autowrap = enabled
                                    if not enabled:
                                        self.pending_wrap = False
                                elif code == 25:
                                    self.cursor_visible = enabled
                                elif code in (47, 1047, 1049):
                                    if enabled and not self.alt_screen:
                                        self._saved_primary = (
                                            [row[:] for row in self.grid],
                                            self.cx,
                                            self.cy,
                                        )
                                        self.grid = [[" "] * self.cols for _ in range(self.rows)]
                                        self.cx = 0
                                        self.cy = 0
                                        self.pending_wrap = False
                                        self.alt_screen = True
                                    elif not enabled and self.alt_screen:
                                        if self._saved_primary is not None:
                                            self.grid, self.cx, self.cy = self._saved_primary
                                            self._saved_primary = None
                                        self.pending_wrap = False
                                        self.alt_screen = False
                        continue
                    if priv:
                        continue
                    if final in ("H", "f"):
                        row = (parts[0] if len(parts) >= 1 and parts[0] > 0 else 1) - 1
                        col = (parts[1] if len(parts) >= 2 and parts[1] > 0 else 1) - 1
                        self.cy = max(0, min(self.rows - 1, row))
                        self.cx = max(0, min(self.cols - 1, col))
                        self.pending_wrap = False
                    elif final == "G":
                        col = (parts[0] if parts and parts[0] > 0 else 1) - 1
                        self.cx = max(0, min(self.cols - 1, col))
                        self.pending_wrap = False
                    elif final == "d":
                        row = (parts[0] if parts and parts[0] > 0 else 1) - 1
                        self.cy = max(0, min(self.rows - 1, row))
                        self.pending_wrap = False
                    elif final == "C":
                        step = parts[0] if parts and parts[0] > 0 else 1
                        self.cx = min(self.cols - 1, self.cx + step)
                        self.pending_wrap = False
                    elif final == "D":
                        step = parts[0] if parts and parts[0] > 0 else 1
                        self.cx = max(0, self.cx - step)
                        self.pending_wrap = False
                    elif final == "A":
                        step = parts[0] if parts and parts[0] > 0 else 1
                        self.cy = max(0, self.cy - step)
                        self.pending_wrap = False
                    elif final == "B":
                        step = parts[0] if parts and parts[0] > 0 else 1
                        self.cy = min(self.rows - 1, self.cy + step)
                        self.pending_wrap = False
                    elif final == "J":
                        mode = parts[0] if parts else 0
                        if mode == 2:
                            self.grid = [[" "] * self.cols for _ in range(self.rows)]
                        elif mode == 3:
                            self.scrollback.clear()
                        elif mode == 0:
                            for c in range(self.cx, self.cols):
                                self.grid[self.cy][c] = " "
                            for r in range(self.cy + 1, self.rows):
                                self.grid[r] = [" "] * self.cols
                        self.pending_wrap = False
                    elif final == "K":
                        mode = parts[0] if parts else 0
                        if mode == 0:
                            for c in range(self.cx, self.cols):
                                self.grid[self.cy][c] = " "
                        elif mode == 2:
                            self.grid[self.cy] = [" "] * self.cols
                        self.pending_wrap = False
                    elif final == "X":
                        count = parts[0] if parts and parts[0] > 0 else 1
                        for c in range(self.cx, min(self.cols, self.cx + count)):
                            self.grid[self.cy][c] = " "
                        self.pending_wrap = False
                    elif final == "r":
                        top = (parts[0] if len(parts) >= 1 and parts[0] > 0 else 1) - 1
                        bot = (parts[1] if len(parts) >= 2 and parts[1] > 0 else self.rows) - 1
                        self.scroll_top = max(0, min(self.rows - 1, top))
                        self.scroll_bottom = max(self.scroll_top, min(self.rows - 1, bot))
                        self.cx = 0
                        self.cy = 0
                        self.pending_wrap = False
                elif nxt in ("(", ")", "*", "+"):
                    i += 3
                else:
                    i += 2
            elif ch >= " ":
                if self.pending_wrap and self.autowrap:
                    self.cx = 0
                    self._linefeed()
                self.grid[self.cy][self.cx] = ch
                if self.cx + 1 < self.cols:
                    self.cx += 1
                    self.pending_wrap = False
                else:
                    self.pending_wrap = self.autowrap
                i += 1
            else:
                i += 1
        self._buf = text[i:]

    def active_lines(self) -> list[str]:
        return ["".join(r).rstrip(" ") for r in self.grid]


class InlineSSHTests(unittest.TestCase):
    def test_remote_exit_returns_to_same_local_shell_and_restores_its_terminal(self):
        self.exercise(False)

    def test_reconnect_keeps_original_process_and_returns_to_same_local_shell(self):
        self.exercise(True)

    def test_resize_queries_use_the_outer_terminals_cursor(self):
        self.exercise(False, resize=True)

    def test_inline_reconnect_restores_agent_changes_made_during_transport_loss(self):
        self.exercise(True, agent_changes=True)

    def exercise(self, disconnect, resize=False, agent_changes=False):
        with tempfile.TemporaryDirectory(prefix="omg-inline-", dir="/tmp") as directory:
            root = Path(directory)
            host = root / "host"
            host.mkdir(mode=0o700)
            policy = dict(detached_ttl_seconds=30, expires_at=None, close_on_agent_done=False,
                          agent_done_grace_seconds=1, terminate_grace_seconds=1,
                          host_idle_seconds=1, record_retention_seconds=60)
            private_json(host / "policy.json", policy)
            daemon = subprocess.Popen([str(BINARY), "host-local", str(host), "--", "/bin/sh"])
            parent, master = pty.fork()
            if parent == 0:
                env = dict(os.environ, OMG_SSH_HANDOFF_DIRECTORY=directory,
                           OMG_SSH_HANDOFF_TOKEN="inline-fixture", OMGD=str(BINARY))
                os.execve("/bin/sh", ["/bin/sh", "-c",
                    'printf "LOCAL_BEFORE:%s\\n" "$$"; "$OMGD" handoff /usr/bin/ssh fixture; '
                    'status=$?; printf "LOCAL_AFTER:%s:%s\\n" "$$" "$status"; exit "$status"'], env)
            output = bytearray()
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 640, 384))
            remote_id = str(uuid.uuid4())
            remote_pid = root / "remote.pid"
            active = root / "active.json"
            local_status = None
            replies = 0
            cursor_row = 7

            def read_output():
                nonlocal replies
                if select.select([master], [], [], .05)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                        while output.count(b"\x1b[6n") > replies:
                            os.write(master, f"\x1b[{cursor_row};1R".encode())
                            replies += 1
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise

            def wait_until(condition, seconds=8):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if condition():
                        return
                    read_output()
                self.fail("inline viewer fixture timed out: " + repr(bytes(output[-1000:])))

            try:
                wait_until(lambda: bool(list(root.glob("*.json"))))
                request = next(root.glob("*.json"))
                payload = json.loads(request.read_text())
                self.assertEqual(payload["viewer"], "inline/1")
                self.assertEqual(payload["token"], "inline-fixture")
                connection_id = "omg-ssh-inline-" + request.stem
                private_json(active, dict(connectionID=connection_id))
                config = root / "connection.json"
                private_json(config, dict(
                    transport="local", executable="/usr/bin/ssh", arguments=["fixture"], cwd=directory,
                    local_shell="/bin/sh", bundle=str(BINARY.parent), revision="fixture",
                    policy=policy, local_state_directory=str(host), tty_authentication=True))
                script = (
                    "import os,sys,tty,select,time,signal\n"
                    f"open({str(remote_pid)!r},'w').write(str(os.getpid()))\n"
                    "tty.setraw(0)\n"
                    "signal.signal(signal.SIGWINCH,lambda *args:os.write(1,b'\\x1b[6n'))\n"
                    "os.write(1,b'REMOTE_READY\\r\\n\\x1b[6n')\n"
                    "def status(value):\n"
                    " os.write(1,('\\x1b]3008;start=omg-agent-omp-%d;type=app;omg_agent=omp;"
                    "omg_scope=remote;omg_liveness=pid;omg_state=%s\\x07'%(os.getpid(),value)).encode())\n"
                    "status('working'); changed=False\n"
                    "data=b''; deadline=time.monotonic()+12; announced=False\n"
                    f"while (b'hello' not in data or data.count(b'R')<{2 if resize else 1}) and time.monotonic()<deadline:\n"
                    " if select.select([0],[],[],.1)[0]: data+=os.read(0,4096)\n"
                    f" if not changed and os.path.exists({str(root / 'agent-change')!r}):\n"
                    "  status('needsAttention'); changed=True\n"
                    " if not announced and b'R' in data:\n"
                    "  os.write(1,b'REMOTE_QUERY_ACCEPTED\\r\\n'); announced=True\n"
                    "count=data.count(b'R')\n"
                    "os.write(1,('REMOTE_QUERY_COUNT:%d\\r\\n'%count).encode())\n"
                    f"sys.exit(7 if count=={2 if resize else 1} and b'hello' in data and b'STALE' not in data "
                    f"and b'[{9 if resize else 7};1R' in data else 90)\n"
                )
                launch = dict(argv=[sys.executable, "-c", script],
                              env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                                   "HOME": directory, "TERM": "xterm-256color"},
                              cwd=directory, cols=80, rows=24, pixel_width=640, pixel_height=384,
                              input_base64=base64.b64encode(b"").decode())
                relay = root / "relay.sock"
                approval = dict(helper=str(BINARY), configuration=str(config), socket=str(relay),
                    open=dict(id=remote_id, create=True, policy=policy, launch=launch, inline_viewer=True),
                    context=dict(connection_id=connection_id, target="fixture", local_cwd=directory,
                                 active_record=str(active)))
                private_json(request.with_suffix(".accepted"), approval)
                wait_until(lambda: b"REMOTE_QUERY_ACCEPTED" in output and active.exists()
                           and json.loads(active.read_text()).get("phase") == "ready" and replies >= 1)
                self.assertNotIn(b"LOCAL_AFTER", output)
                self.assertNotIn(b"\x1b[2J", output, "first attach must preserve the local terminal contents")
                self.assertEqual(replies, 1, "the outer terminal must be the only cursor-query authority")
                original_pid = int(remote_pid.read_text())
                if resize:
                    cursor_row = 9
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 40, 320, 160))
                    wait_until(lambda: replies == 2)
                if disconnect:
                    generation = json.loads(active.read_text())["attachmentGeneration"]
                    before_reconnect = len(output)
                    daemon.terminate()
                    daemon.wait(timeout=5)
                    if agent_changes:
                        (root / "agent-change").touch()
                    wait_until(lambda: active.exists() and
                               json.loads(active.read_text()).get("phase") != "ready")
                    os.write(master, b"STALE\n")
                    wait_until(lambda: active.exists() and
                               json.loads(active.read_text()).get("phase") == "ready" and
                               json.loads(active.read_text()).get("attachmentGeneration", 0) > generation)
                    self.assertEqual(int(remote_pid.read_text()), original_pid)
                    os.kill(original_pid, 0)
                    if agent_changes:
                        wait_until(lambda: b"omg_state=needsAttention" in output[before_reconnect:]
                                   and b"start=omg-agent-sync;begin" in output[before_reconnect:])
                os.write(master, b"hello\n")
                wait_until(lambda: b"LOCAL_AFTER:" in output)
                for _ in range(50):
                    done, local_status = os.waitpid(parent, os.WNOHANG)
                    if done:
                        break
                    read_output()
                self.assertTrue(done, "the original shell must finish after remote exit")
                self.assertEqual(os.waitstatus_to_exitcode(local_status), 7, bytes(output[-1500:]))
                self.assertIn(f"LOCAL_BEFORE:{parent}".encode(), output)
                self.assertIn(f"LOCAL_AFTER:{parent}:7".encode(), output)
                self.assertIn(f"REMOTE_QUERY_COUNT:{2 if resize else 1}".encode(), output)
                self.assertFalse(active.exists())
            finally:
                if (host / "host.sock").exists():
                    try:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(2)
                            control.connect(str(host / "host.sock"))
                            control.sendall(encode(b"K", 1, remote_id.encode()))
                            frame(control)
                    except OSError:
                        pass
                if local_status is None:
                    try:
                        os.kill(parent, signal.SIGTERM)
                        os.waitpid(parent, 0)
                    except ProcessLookupError:
                        pass
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)
                os.close(master)

    def test_inline_never_splices_osc3008_inside_open_sync_output_frame(self):
        with tempfile.TemporaryDirectory(prefix="omg-inline-sync-", dir="/tmp") as directory:
            root = Path(directory)
            host = root / "host"
            host.mkdir(mode=0o700)
            private_json(host / "policy.json", dict(
                detached_ttl_seconds=30, expires_at=None, close_on_agent_done=False,
                host_idle_seconds=1, record_retention_seconds=60,
            ))
            daemon = subprocess.Popen([str(BINARY), "host-local", str(host), "--", "/bin/sh"])
            parent, master = pty.fork()
            if parent == 0:
                env = dict(os.environ, OMG_SSH_HANDOFF_DIRECTORY=directory,
                           OMG_SSH_HANDOFF_TOKEN="inline-sync-fixture", OMGD=str(BINARY))
                os.execve("/bin/sh", ["/bin/sh", "-c", '"$OMGD" handoff /usr/bin/ssh sync-fixture'], env)
            output = bytearray()
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 640, 384))
            remote_id = str(uuid.uuid4())
            active = root / "active.json"
            local_status = None
            try:
                def read_output():
                    r, _, _ = select.select([master], [], [], 0.05)
                    if r:
                        chunk = os.read(master, 65536)
                        output.extend(chunk)
                        if b"\x1b[6n" in chunk:
                            os.write(master, b"\x1b[1;1R")
                        return len(chunk) > 0
                    return False

                def wait_until(pred, timeout=5):
                    end = time.monotonic() + timeout
                    while time.monotonic() < end:
                        read_output()
                        if pred():
                            return
                    raise AssertionError(f"timed out; output={bytes(output[-1200:])!r}")

                req = None
                req_file = None
                wait_until(lambda: any(
                    p.suffix == ".json" and p.name != "active.json"
                    for p in root.iterdir()
                ))
                req_file = next(
                    p for p in root.iterdir()
                    if p.suffix == ".json" and p.name != "active.json"
                )
                req = json.loads(req_file.read_text())
                wait_until(lambda: (host / "host.sock").exists())
                remote = root / "remote.py"
                remote.write_text(textwrap.dedent("""\
                    import os, sys, time
                    # Begin ?2026h synchronized update, pause while agent status/cwd changes
                    # happen concurrently, then close ?2026l cleanly.
                    sys.stdout.write("\\x1b[?2026h\\x1b[2JFRAME_HEAD")
                    sys.stdout.flush()
                    time.sleep(0.03)
                    sys.stdout.write("\\x1b]7501;state=working:app=antigravity\\x07")
                    sys.stdout.flush()
                    time.sleep(0.03)
                    sys.stdout.write("FRAME_TAIL\\x1b[?2026l\\nDONE_SYNC\\n")
                    sys.stdout.flush()
                    time.sleep(0.1)
                """))
                private_json(active, dict(connectionID="omg-ssh-inline-sync"))
                config = root / "connection.json"
                private_json(config, dict(
                    transport="local", executable=str(BINARY), arguments=[],
                    cwd=str(root), bundle=str(BINARY.parent), revision="fixture",
                    local_shell="/bin/sh", local_state_directory=str(host),
                    tty_authentication=True,
                    policy=dict(detached_ttl_seconds=30, expires_at=None,
                                close_on_agent_done=False, host_idle_seconds=1,
                                record_retention_seconds=60),
                ))
                private_json(req_file.with_suffix(".accepted"), dict(
                    helper=str(BINARY),
                    token=req["token"], configuration=str(config), socket=str(root / "relay.sock"),
                    open=dict(
                        id=remote_id,
                        policy=dict(
                            detached_ttl_seconds=30, expires_at=None,
                            close_on_agent_done=False, host_idle_seconds=1,
                            record_retention_seconds=60),
                        create=True,
                        cwd=str(root),
                        inline_viewer=True,
                        launch=dict(
                            argv=[sys.executable, str(remote)],
                            env=dict(os.environ),
                            cwd=str(root),
                            cols=80,
                            rows=24,
                            pixel_width=640,
                            pixel_height=384,
                        ),
                    ),
                    context=dict(connection_id="omg-ssh-inline-sync", target="sync-fixture",
                                 local_cwd=str(root), active_record=str(active)),
                ))
                wait_until(lambda: b"DONE_SYNC" in output and b"omg-agent-sync" in output)
                done = False
                for _ in range(50):
                    pid_done, local_status = os.waitpid(parent, os.WNOHANG)
                    if pid_done:
                        done = True
                        break
                    read_output()
                self.assertTrue(done)
                raw = bytes(output)
                start_sync = raw.index(b"\x1b[?2026h\x1b[2JFRAME_HEAD")
                end_sync = raw.index(b"\x1b[?2026l", start_sync)
                between = raw[start_sync:end_sync]
                self.assertNotIn(b"\x1b]3008;", between, f"OSC 3008 spliced inside ?2026h..l: {between!r}")
                self.assertIn(b"omg-program-status", raw[end_sync:])
            finally:
                if (host / "host.sock").exists():
                    try:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(2)
                            control.connect(str(host / "host.sock"))
                            control.sendall(encode(b"K", 1, remote_id.encode()))
                            frame(control)
                    except OSError:
                        pass
                if local_status is None:
                    try:
                        os.kill(parent, signal.SIGTERM)
                        os.waitpid(parent, 0)
                    except ProcessLookupError:
                        pass
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)
                os.close(master)

    def _run_disconnect_scenario(self, *, cols, rows, remote_script, after_disconnect_fn=None):
        with tempfile.TemporaryDirectory(prefix="omg-inline-91-", dir="/tmp") as directory:
            root = Path(directory)
            host = root / "host"
            host.mkdir(mode=0o700)
            policy = dict(
                detached_ttl_seconds=60,
                expires_at=None,
                close_on_agent_done=False,
                agent_done_grace_seconds=1,
                terminate_grace_seconds=1,
                host_idle_seconds=2,
                record_retention_seconds=60,
            )
            private_json(host / "policy.json", policy)
            daemon = subprocess.Popen([str(BINARY), "host-local", str(host), "--", "/bin/sh"])
            parent, master = pty.fork()
            if parent == 0:
                env = dict(
                    os.environ,
                    OMG_SSH_HANDOFF_DIRECTORY=directory,
                    OMG_SSH_HANDOFF_TOKEN="inline-91",
                    OMGD=str(BINARY),
                )
                os.execve(
                    "/bin/sh",
                    [
                        "/bin/sh",
                        "-c",
                        'printf "LOCAL_PREFIX_MARKER\\n"; "$OMGD" handoff /usr/bin/ssh fixture; '
                        'status=$?; printf "LOCAL_DONE:%s\\n" "$status"; exit "$status"',
                    ],
                    env,
                )
            vt = MiniVT(cols, rows)
            output = bytearray()
            fcntl.ioctl(
                master,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", rows, cols, cols * 8, rows * 16),
            )
            remote_id = str(uuid.uuid4())
            active = root / "active.json"
            remote_py = root / "remote_app.py"
            remote_py.write_text(remote_script)
            local_status = None
            replies = 0

            def read_output():
                nonlocal replies
                if select.select([master], [], [], 0.04)[0]:
                    try:
                        chunk = os.read(master, 65536)
                        output.extend(chunk)
                        vt.feed(chunk)
                        while output.count(b"\x1b[6n") > replies:
                            os.write(master, f"\x1b[{vt.cy + 1};{vt.cx + 1}R".encode())
                            replies += 1
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise

            def wait_until(condition, seconds=12):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if condition():
                        return
                    read_output()
                self.fail(f"scenario timed out; tail={bytes(output[-1200:])!r}")

            try:
                wait_until(
                    lambda: any(
                        p.suffix == ".json" and p.name != "active.json"
                        for p in root.iterdir()
                    )
                )
                req_file = next(
                    p for p in root.iterdir() if p.suffix == ".json" and p.name != "active.json"
                )
                req = json.loads(req_file.read_text())
                conn_id = "omg-ssh-inline-" + req_file.stem
                private_json(active, dict(connectionID=conn_id))
                config = root / "connection.json"
                private_json(
                    config,
                    dict(
                        transport="local",
                        executable="/usr/bin/ssh",
                        arguments=["fixture"],
                        cwd=directory,
                        local_shell="/bin/sh",
                        bundle=str(BINARY.parent),
                        revision="fixture",
                        policy=policy,
                        local_state_directory=str(host),
                        tty_authentication=True,
                    ),
                )
                launch = dict(
                    argv=[sys.executable, str(remote_py), str(root)],
                    env={
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "HOME": directory,
                        "TERM": "xterm-256color",
                    },
                    cwd=directory,
                    cols=cols,
                    rows=rows,
                    pixel_width=cols * 8,
                    pixel_height=rows * 16,
                    input_base64=base64.b64encode(b"").decode(),
                )
                private_json(
                    req_file.with_suffix(".accepted"),
                    dict(
                        helper=str(BINARY),
                        token=req["token"],
                        configuration=str(config),
                        socket=str(root / "relay.sock"),
                        open=dict(
                            id=remote_id,
                            create=True,
                            policy=policy,
                            launch=launch,
                            inline_viewer=True,
                        ),
                        context=dict(
                            connection_id=conn_id,
                            target="fixture",
                            local_cwd=directory,
                            active_record=str(active),
                        ),
                    ),
                )
                wait_until(
                    lambda: (root / "pre_ready").exists()
                    and active.exists()
                    and json.loads(active.read_text()).get("phase") == "ready"
                )
                # Drain any remaining pre-disconnect bytes into MiniVT.
                for _ in range(5):
                    read_output()

                gen_before = json.loads(active.read_text())["attachmentGeneration"]
                daemon.terminate()
                daemon.wait(timeout=5)
                try:
                    (host / "host.sock").unlink()
                except FileNotFoundError:
                    pass
                # Hold host.lock while offline so auto-reconnect waits until offline output completes.
                lock_file = open(host / "host.lock", "a+")
                try:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                    wait_until(
                        lambda: active.exists()
                        and json.loads(active.read_text()).get("phase") != "ready"
                    )
                    if after_disconnect_fn is not None:
                        after_disconnect_fn(root, master, vt)
                    (root / "produce_disconnect_output").touch()
                    wait_until(lambda: (root / "disconnect_output_done").exists(), seconds=20)
                finally:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                    lock_file.close()

                daemon = subprocess.Popen(
                    [str(BINARY), "host-local", str(host), "--", "/bin/sh"]
                )
                wait_until(
                    lambda: active.exists()
                    and json.loads(active.read_text()).get("phase") == "ready"
                    and json.loads(active.read_text()).get("attachmentGeneration", 0)
                    > gen_before,
                    seconds=15,
                )
                # Let full scrollback replay drain into MiniVT before finishing remote app.
                os.write(master, b"FINISH\n")
                wait_until(lambda: b"LOCAL_DONE:" in output, seconds=15)
                for _ in range(50):
                    done, local_status = os.waitpid(parent, os.WNOHANG)
                    if done:
                        break
                    read_output()
                self.assertTrue(done)
                self.assertEqual(os.waitstatus_to_exitcode(local_status), 0, bytes(output[-1500:]))
                return vt, bytes(output)
            finally:
                if (host / "host.sock").exists():
                    try:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(2)
                            control.connect(str(host / "host.sock"))
                            control.sendall(encode(b"K", 1, remote_id.encode()))
                            frame(control)
                    except OSError:
                        pass
                if local_status is None:
                    try:
                        os.kill(parent, signal.SIGTERM)
                        os.waitpid(parent, 0)
                    except ProcessLookupError:
                        pass
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)
                os.close(master)

    def test_hidden_cursor_tui_preserves_multi_screen_disconnect_scrollback_without_artifacts(self):
        script = textwrap.dedent("""\
            import os, pathlib, select, sys, time, tty
            root = pathlib.Path(sys.argv[1])
            tty.setraw(0)
            os.write(1, b"\\x1b[?25l")
            for i in range(18):
                os.write(1, f"PRE_HIST_{i:02}\\r\\n".encode())
            os.write(1, b"TUI_STATUS_BEFORE_DROP")
            (root / "pre_ready").touch()
            while not (root / "produce_disconnect_output").exists():
                time.sleep(0.02)
            # Overwrite status line and emit 60 lines (multiple screens) while disconnected!
            os.write(1, b"\\r\\x1b[K")
            for i in range(60):
                os.write(1, f"DURING_DROP_{i:02}\\r\\n".encode())
            os.write(1, b"TUI_FINAL_ACTIVE")
            (root / "disconnect_output_done").touch()
            buf = b""
            deadline = time.monotonic() + 12
            while b"FINISH" not in buf and time.monotonic() < deadline:
                if select.select([0], [], [], 0.05)[0]:
                    buf += os.read(0, 4096)
            sys.exit(0)
        """)
        vt, _ = self._run_disconnect_scenario(cols=60, rows=12, remote_script=script)
        all_lines = vt.scrollback + vt.active_lines()
        self.assertTrue(
            any("LOCAL_PREFIX_MARKER" in line for line in vt.scrollback),
            f"local prefix must survive ?25l TUI reconnect: {vt.scrollback[:10]!r}",
        )
        for i in range(18):
            tag = f"PRE_HIST_{i:02}"
            self.assertIn(tag, all_lines)
        for i in range(60):
            tag = f"DURING_DROP_{i:02}"
            self.assertEqual(
                all_lines.count(tag),
                1,
                f"expected disconnect scrollback line {tag} exactly once; got {all_lines.count(tag)}",
            )
        self.assertTrue(any("TUI_FINAL_ACTIVE" in line for line in all_lines))

    def test_small_history_delta_smaller_than_rows_is_not_overwritten_by_home_sequence(self):
        # 40-row terminal where disconnect produces K = 5 (< 40) new scrollback lines!
        script = textwrap.dedent("""\
            import os, pathlib, select, sys, time, tty
            root = pathlib.Path(sys.argv[1])
            tty.setraw(0)
            os.write(1, b"\\x1b[?25l")
            # Fill 42 lines so 2 lines are in scrollback and 40 lines are on the active screen.
            for i in range(42):
                end = b"\\r\\n" if i < 41 else b""
                os.write(1, f"INIT_ROW_{i:02}".encode() + end)
            (root / "pre_ready").touch()
            while not (root / "produce_disconnect_output").exists():
                time.sleep(0.02)
            # Emit 5 new lines so K = 5 (< 40) lines scroll into history during disconnect!
            os.write(1, b"\\r\\n")
            for i in range(5):
                end = b"\\r\\n" if i < 4 else b""
                os.write(1, f"SMALL_DELTA_{i:02}".encode() + end)
            (root / "disconnect_output_done").touch()
            buf = b""
            deadline = time.monotonic() + 12
            while b"FINISH" not in buf and time.monotonic() < deadline:
                if select.select([0], [], [], 0.05)[0]:
                    buf += os.read(0, 4096)
            sys.exit(0)
        """)
        vt, _ = self._run_disconnect_scenario(cols=80, rows=40, remote_script=script)
        all_lines = vt.scrollback + vt.active_lines()
        # Init rows 02..06 were the 5 lines pushed into history by SMALL_DELTA_00..04!
        for i in range(2, 7):
            tag = f"INIT_ROW_{i:02}"
            self.assertIn(
                tag,
                vt.scrollback,
                f"{tag} (K=5 < 40 delta) must be pushed into outer scrollback, not overwritten by CSI H!",
            )
        for i in range(5):
            self.assertIn(f"SMALL_DELTA_{i:02}", all_lines)

    def test_four_mib_eviction_during_disconnect_preserves_pre_drop_screen_and_replays_bounded_tail(self):
        script = textwrap.dedent("""\
            import os, pathlib, select, sys, time, tty
            root = pathlib.Path(sys.argv[1])
            tty.setraw(0)
            os.write(1, b"\\x1b[?25l")
            for i in range(20):
                os.write(1, f"BEFORE_EVICT_{i:02}\\r\\n".encode())
            os.write(1, b"PRE_DROP_VIEWPORT_ANCHOR")
            (root / "pre_ready").touch()
            while not (root / "produce_disconnect_output").exists():
                time.sleep(0.02)
            # Write ~5 MiB of scrollback while disconnected to force >4 MiB whole-page eviction!
            os.write(1, b"\\r\\n")
            chunk = []
            for i in range(60000):
                chunk.append(f"EVICT_ROW_{i:05}_" + ("X" * 70) + "\\r\\n")
                if len(chunk) >= 500:
                    os.write(1, "".join(chunk).encode())
                    chunk.clear()
            if chunk:
                os.write(1, "".join(chunk).encode())
            os.write(1, b"POST_EVICT_ACTIVE_END")
            (root / "disconnect_output_done").touch()
            buf = b""
            deadline = time.monotonic() + 15
            while b"FINISH" not in buf and time.monotonic() < deadline:
                if select.select([0], [], [], 0.05)[0]:
                    buf += os.read(0, 4096)
            sys.exit(0)
        """)
        vt, _ = self._run_disconnect_scenario(cols=96, rows=16, remote_script=script)
        all_lines = vt.scrollback + vt.active_lines()
        self.assertTrue(
            any("PRE_DROP_VIEWPORT_ANCHOR" in line for line in vt.scrollback),
            "pre-disconnect viewport must be preserved via preserve_rows when >4 MiB evicts anchor",
        )
        self.assertFalse(
            any("EVICT_ROW_00010_" in line for line in all_lines),
            "evicted head rows beyond 4 MiB / 10k-row cap must not be replayed",
        )
        self.assertTrue(
            any("EVICT_ROW_59950_" in line for line in vt.scrollback),
            f"recent retained scrollback tail must be replayed after >4 MiB eviction; tail={vt.scrollback[-5:]!r}",
        )
        self.assertTrue(any("EVICT_ROW_59995_" in line for line in all_lines))
        self.assertTrue(any("POST_EVICT_ACTIVE_END" in line for line in all_lines))

    def test_resize_while_disconnected_resizes_remote_before_painting_reconnect_frame(self):
        script = textwrap.dedent("""\
            import fcntl, os, pathlib, select, signal, struct, sys, termios, time, tty
            root = pathlib.Path(sys.argv[1])
            tty.setraw(0)
            winch_sizes = []
            def on_winch(*_args):
                r, c, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\\0" * 8))
                winch_sizes.append(f"{c}x{r}")
                os.write(1, f"\\r\\nRESIZED_TO:{c}x{r}\\r\\n".encode())
            signal.signal(signal.SIGWINCH, on_winch)
            for i in range(20):
                os.write(1, f"HIST_BEFORE_RESIZE_{i:02}\\r\\n".encode())
            (root / "pre_ready").touch()
            while not (root / "produce_disconnect_output").exists():
                time.sleep(0.02)
            for i in range(10):
                os.write(1, f"WHILE_OFFLINE_{i:02}\\r\\n".encode())
            (root / "disconnect_output_done").touch()
            buf = b""
            deadline = time.monotonic() + 12
            while (b"FINISH" not in buf or "100x30" not in winch_sizes) and time.monotonic() < deadline:
                try:
                    if select.select([0], [], [], 0.05)[0]:
                        buf += os.read(0, 4096)
                except InterruptedError:
                    continue
            sys.exit(0 if "100x30" in winch_sizes else 92)
        """)

        def resize_while_offline(_root, master_fd, mini_vt):
            fcntl.ioctl(
                master_fd,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", 30, 100, 800, 480),
            )
            mini_vt.resize(100, 30)

        vt, raw_out = self._run_disconnect_scenario(
            cols=80,
            rows=24,
            remote_script=script,
            after_disconnect_fn=resize_while_offline,
        )
        all_lines = vt.scrollback + vt.active_lines()
        self.assertIn(b"RESIZED_TO:100x30", raw_out)
        for i in range(10):
            self.assertIn(f"WHILE_OFFLINE_{i:02}", all_lines)


if __name__ == "__main__":
    unittest.main()
