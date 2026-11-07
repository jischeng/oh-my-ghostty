#!/usr/bin/env python3
"""Observe a GUI-created guest session and drive the real Mac input path."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import struct
import subprocess
import time


def encode(kind, sequence=0, data=b""):
    return struct.pack(">cQI", kind, sequence, len(data)) + data


def gui_type(command, new_window=False):
    lines = [
        'tell application "System Events" to tell process "omg"',
        "set frontmost to true",
    ]
    if new_window:
        lines.extend(['keystroke "n" using command down', "delay 2"])
    quoted = command.replace("\\", "\\\\").replace('"', '\\"')
    lines.extend([f'keystroke "{quoted}"', "key code 36", "end tell"])
    subprocess.run(["/usr/bin/osascript", "-e", "\n".join(lines)], check=True, timeout=15)


def wait_for(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"Timed out: {description}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--listen", required=True)
    args = parser.parse_args()
    directory = args.directory
    if not re.fullmatch(r"/tmp/omg-mobile-vm-[a-f0-9]+", str(directory)):
        parser.error("use a fresh /tmp/omg-mobile-vm-<hex> evidence directory")
    directory.mkdir(mode=0o700)
    (directory / "fixture.pid").write_text(str(os.getpid()))
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    binary = Path("/Applications/OMG.app/Contents/Resources/session-runtime/omgd")
    support = Path.home() / "Library/Application Support/OMG Dev"
    gateway = None
    control = None
    session = None
    with (directory / "gateway.log").open("wb") as log:
        try:
            pid_file = directory / "desktop.pid"
            startup_command = f'printf "%s" "$$" > {pid_file}; printf "OMG VM desktop ready\\n"'
            gui_type(startup_command, new_window=True)
            last_probe = time.monotonic()

            def shell_ready():
                nonlocal last_probe
                if pid_file.exists() and pid_file.read_text().isdigit():
                    return True
                # Cmd-N may finish before its surface has a first responder.
                # Retry only this idempotent readiness probe, never test input.
                if time.monotonic() - last_probe >= 1:
                    gui_type(startup_command)
                    last_probe = time.monotonic()
                return False

            wait_for(shell_ready, "GUI shell PID")
            pid = int(pid_file.read_text())
            parents = {
                int(child): int(parent)
                for child, parent in (
                    row.split() for row in subprocess.check_output(
                        ["ps", "-axo", "pid=,ppid="], text=True).splitlines()
                )
            }
            ancestors = {pid}
            parent = pid
            while parent in parents and parents[parent] not in ancestors:
                parent = parents[parent]
                ancestors.add(parent)

            def inventory():
                result = subprocess.check_output([
                    str(binary), "sessions", "list", "--local", "--json",
                    "--app-support", str(support),
                ], text=True, timeout=10)
                # Native Mac launches can retain /usr/bin/login as the PTY root;
                # the interactive shell's $$ is its descendant, not that PID.
                return next((entry for entry in json.loads(result)["sessions"]
                             if entry["pid"] in ancestors and entry["ended"] is None), None)

            session = wait_for(inventory, "GUI-created session in runtime catalogue")
            current = (binary.parent / "revision").read_text().strip()
            if session["revision"] != current:
                raise RuntimeError("The GUI session is not using the newly packaged runtime")
            namespace = hashlib.sha256(f'{support}\0{current}'.encode()).hexdigest()[:20]
            host = Path.home() / ".omg/run" / namespace / "host.sock"
            control = socket.socket(socket.AF_UNIX)
            control.settimeout(5)
            control.connect(str(host))
            control.sendall(encode(b"U", 1, json.dumps({
                "id": session["id"], "generation": session["generation"],
            }).encode()))
            token = directory / "pair.token"
            token.write_text("t" * 64)
            token.chmod(0o600)
            gateway = subprocess.Popen([
                str(binary), "mobile", "--listen", args.listen,
                "--socket", str(host), "--token-file", str(token),
            ], stdout=log, stderr=log)
            pending = bytearray()
            output = bytearray()
            ready = False
            mobile = False
            mac = False
            reported = False
            last_ping = 0
            deadline = time.monotonic() + 600
            while not stopped and time.monotonic() < deadline:
                if gateway.poll() is not None:
                    raise RuntimeError("Guest mobile gateway exited")
                if time.monotonic() - last_ping > 10:
                    control.sendall(encode(b"P"))
                    last_ping = time.monotonic()
                if not select.select([control], [], [], 0.1)[0]:
                    continue
                data = control.recv(65536)
                if not data:
                    raise RuntimeError("Guest runtime observer disconnected")
                pending.extend(data)
                while len(pending) >= 13:
                    kind, _, size = struct.unpack(">cQI", pending[:13])
                    if size > 16 * 1024 * 1024:
                        raise RuntimeError("Oversized observer frame")
                    if len(pending) < 13 + size:
                        break
                    payload = bytes(pending[13:13 + size])
                    del pending[:13 + size]
                    if kind == b"E":
                        raise RuntimeError(payload.decode(errors="replace"))
                    if kind != b"D":
                        continue
                    inner, sequence, _ = struct.unpack(">cQI", payload[:13])
                    body = payload[13:]
                    if inner == b"J" and not json.loads(body).get("writer_transfer"):
                        raise RuntimeError("Guest runtime does not support writer transfer")
                    if inner == b"S":
                        # This connection is an observer: never claim or inject input.
                        control.sendall(encode(b"D", 1, encode(b"A", sequence)))
                        if not ready:
                            wait_for(lambda: "listening on" in (directory / "gateway.log").read_text(),
                                     "guest gateway listener")
                            (directory / "ready.json").write_text(json.dumps({
                                "id": session["id"], "pid": session["pid"], "shell_pid": pid,
                                "generation": session["generation"], "revision": current,
                                "server": args.listen,
                            }))
                            ready = True
                    if inner != b"O":
                        continue
                    output.extend(body)
                    output[:] = output[-262144:]
                    if f"MOBILE_UI_EXECUTED pid={pid}".encode() in output and not mobile:
                        mobile = True
                        # Keystrokes go through the actual Mac GUI/SessionBackend.
                        gui_type("printf '\\115\\101\\103\\137\\122\\105\\103\\114"
                                 "\\101\\111\\115\\105\\104 pid=%s\\n' \"$$\"")
                    if f"MAC_RECLAIMED pid={pid}".encode() in output:
                        mac = True
                    if mac and f"MOBILE_RECONNECTED pid={pid}".encode() in output and not reported:
                        current_session = inventory()
                        if (current_session is None
                                or current_session["generation"] != session["generation"]
                                or current_session["pid"] != session["pid"]):
                            raise RuntimeError("Session identity changed after reconnect")
                        (directory / "output.bin").write_bytes(output)
                        (directory / "result.json").write_text(json.dumps({
                            "session": session["id"], "pid": session["pid"], "shell_pid": pid,
                            "generation": session["generation"], "revision": current,
                            "mobile_executed": mobile, "mac_gui_reclaimed": mac,
                            "mobile_reconnected": True, "same_pid_and_generation": True,
                        }, indent=2))
                        reported = True
            if not stopped:
                raise RuntimeError("Guest mobile fixture deadline expired")
        finally:
            if control is not None:
                if session is not None:
                    try:
                        control.sendall(encode(b"K", 2, session["id"].encode()))
                        time.sleep(0.2)
                    except OSError:
                        pass
                control.close()
            if gateway is not None:
                gateway.terminate()
                try:
                    gateway.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    gateway.kill()
                    gateway.wait()
            (directory / "stopped").touch()


if __name__ == "__main__":
    main()
