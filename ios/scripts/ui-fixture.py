#!/usr/bin/env python3
"""Isolated real PTY/Unix-writer/LAN gateway fixture for OMGMobileUITests."""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "session-runtime/tests"))
from test_sessions import encode, frame  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--listen", default="127.0.0.1:18790")
    args = parser.parse_args()
    directory = args.directory
    directory.mkdir(mode=0o700)
    binary = ROOT / "session-runtime/target/debug/omgd"
    session_id = "77777777-1111-2222-3333-444444444444"
    token = directory / "pair.token"
    token.write_text("t" * 64)
    token.chmod(0o600)
    children = []
    control = None
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log = (directory / "runtime.log").open("wb")
    try:
        children.append(subprocess.Popen(
            [str(binary), "host", str(directory), "--", "/bin/sh", "-i"],
            stdout=log, stderr=log))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                control = socket.socket(socket.AF_UNIX)
                control.connect(str(directory / "host.sock"))
                break
            except OSError:
                control.close()
                control = None
                time.sleep(0.05)
        if control is None:
            raise RuntimeError("fixture host did not start")
        control.settimeout(5)
        request = {"id": session_id, "policy": {}, "create": True, "cwd": "/tmp"}
        control.sendall(encode(b"C", 1, json.dumps(request).encode()))
        pid = None
        while True:
            kind, _, payload = frame(control)
            if kind != b"D":
                raise RuntimeError(f"session create failed: {kind!r} {payload!r}")
            inner, sequence, size = struct.unpack(">cQI", payload[:13])
            data = payload[13:]
            if inner == b"J":
                pid = json.loads(data)["pid"]
            if inner == b"S":
                control.sendall(encode(b"D", 1, encode(b"A", sequence, b"")))
                control.sendall(encode(b"D", 1, encode(b"W", 0, b"")))
                control.sendall(encode(b"D", 1, encode(
                    b"I", 0, "printf '你好，OMG Mobile\\n'\r".encode())))
                break
        children.append(subprocess.Popen(
            [str(binary), "mobile", "--listen", args.listen,
             "--socket", str(directory / "host.sock"), "--token-file", str(token)],
            stdout=log, stderr=log))
        (directory / "ready.json").write_text(json.dumps({
            "id": session_id, "pid": pid, "fixture_pid": os.getpid(),
            "server": args.listen,
        }))
        print(f"UI fixture ready: {directory}", flush=True)
        pending = bytearray()
        executed = False
        reclaimed = False
        reported = False
        deadline = time.monotonic() + 600
        last_ping = 0
        while not stopped and time.monotonic() < deadline:
            if time.monotonic() - last_ping > 10:
                control.sendall(encode(b"P", 0, b""))
                last_ping = time.monotonic()
            if not select.select([control], [], [], 0.1)[0]:
                continue
            chunk = control.recv(65536)
            if not chunk:
                raise RuntimeError("Unix observer disconnected")
            pending.extend(chunk)
            while len(pending) >= 13:
                kind, _, length = struct.unpack(">cQI", pending[:13])
                if len(pending) < 13 + length:
                    break
                data = bytes(pending[13:13 + length])
                del pending[:13 + length]
                if kind != b"D":
                    continue
                inner, _, _ = struct.unpack(">cQI", data[:13])
                output = data[13:]
                if inner == b"O":
                    with (directory / "output.bin").open("ab") as target:
                        target.write(output)
                    if b"MOBILE_UI_EXECUTED" in (directory / "output.bin").read_bytes() and not executed:
                        executed = True
                        control.sendall(encode(b"D", 1, encode(b"W", 0, b"takeover/1")))
                    if reclaimed and not reported and b"MAC_RECLAIMED" in (directory / "output.bin").read_bytes():
                        reported = True
                        (directory / "result.json").write_text(json.dumps({
                            "session": session_id, "pid": pid, "mobile_executed": executed,
                            "mac_reclaimed": reclaimed, "mac_executed": True,
                        }, indent=2))
                if inner == b"W" and executed and not reclaimed:
                    reclaimed = True
                    # A desktop writer returns to its own larger viewport.
                    # The phone must keep the cursor visible without resizing it.
                    control.sendall(encode(b"D", 1, encode(b"R", 0, struct.pack(">HH", 120, 50))))
                    control.sendall(encode(b"D", 1, encode(b"I", 0,
                        b"printf '\\115\\101\\103\\137\\122\\105\\103\\114\\101\\111\\115\\105\\104\\n'\r")))
        if not stopped:
            raise RuntimeError("UI fixture deadline expired")
    finally:
        if control:
            try:
                control.sendall(encode(b"K", 2, session_id.encode()))
                time.sleep(0.2)
            except OSError:
                pass
            control.close()
        for child in reversed(children):
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        log.close()


if __name__ == "__main__":
    main()
