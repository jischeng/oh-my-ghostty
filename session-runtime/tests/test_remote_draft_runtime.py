"""Persistent SSH sessions must provision the explicit-request editor bridge."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import uuid

from test_sessions import BINARY, encode, frame
from test_local_runtime import wait_socket, inner_event

ROOT = Path(__file__).resolve().parents[2]


class RemoteRuntimeDraftTests(unittest.TestCase):
    def test_runtime_editor_import_preserves_draft_and_binds_generation(self):
        with tempfile.TemporaryDirectory(prefix="omg-runtime-draft-", dir="/tmp") as directory:
            home = Path(directory)
            revision = "draft-fixture"
            state = home / ".omg/run" / hashlib.sha256(revision.encode()).hexdigest()[:12]
            state.mkdir(parents=True, mode=0o700)
            original = home / "input.txt"
            original.write_text("中文 draft\nsecond line")
            agent = home / "agent.py"
            agent.write_text(textwrap.dedent("""
                import os, pathlib, subprocess, tty
                tty.setraw(0)
                pathlib.Path(os.environ['DRAFT_INPUT']).with_suffix('.ready').touch()
                while True:
                    data = os.read(0, 64)
                    if not data: break
                    if b'\\x07' in data:
                        subprocess.run([os.environ['VISUAL'], os.environ['DRAFT_INPUT']], check=True)
            """))
            environment = dict(os.environ, HOME=directory, VISUAL="/bin/false", DRAFT_INPUT=str(original))
            daemon = subprocess.Popen([str(BINARY), "host", str(state), "--", sys.executable, str(agent)],
                                      env=environment)
            identity = str(uuid.uuid4()).upper()
            stream = socket.socket(socket.AF_UNIX)
            stream.settimeout(8)
            try:
                wait_socket(state / "host.sock", daemon)
                stream.connect(str(state / "host.sock"))
                stream.sendall(encode(b"H", 1, identity.encode()))
                inner_event(stream, 1, b"J")
                offset, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", offset)))
                stream.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(stream, 1, b"W")
                session = "omg-runtime-" + identity.lower()
                root = state / "draft"
                scope = root / "sessions" / hashlib.sha256(session.encode()).hexdigest()
                metadata = json.loads((scope / "session.json").read_text())
                self.assertEqual(metadata["runtime_id"], identity)
                self.assertEqual(metadata["editor"], "/bin/false")
                env = dict(environment, OMG_REMOTE_ROOT=str(root))
                request = str(uuid.uuid4())
                command = [sys.executable, str(root / "omg")]
                wrong = subprocess.run(command + ["draft-begin", session, request, metadata["tty"], "wrong"],
                                       env=env, capture_output=True, timeout=5)
                self.assertNotEqual(wrong.returncode, 0)
                subprocess.run(command + ["draft-begin", session, request, metadata["tty"], metadata["runtime_generation"]],
                               env=env, capture_output=True, check=True, timeout=5)
                for _ in range(100):
                    if original.with_suffix(".ready").exists(): break
                    time.sleep(.02)
                self.assertTrue(original.with_suffix(".ready").exists())
                stream.sendall(encode(b"D", 1, encode(b"I", 0, b"\x07")))
                result = subprocess.run(command + ["draft-read", session, request], env=env,
                                        capture_output=True, check=True, timeout=8)
                self.assertEqual(result.stdout, "OMG_REMOTE_DRAFT_V1\n中文 draft\nsecond line".encode())
                self.assertEqual(original.read_text(), "中文 draft\nsecond line")
                source = (ROOT / "macos/Sources/Features/QuickInput/QuickInputRemoteDraftBridge.swift").read_text()
                probe = textwrap.dedent(source.split('static let runtimeProbe = #"""', 1)[1].split('"""#', 1)[0])
                result = subprocess.run([sys.executable, "-", revision, identity], input=probe, env=environment,
                                        capture_output=True, text=True, check=True, timeout=8)
                target = json.loads(result.stdout)
                self.assertEqual(target["session"], session)
                self.assertEqual(target["tty"], metadata["tty"])
                self.assertEqual(target["generation"], metadata["runtime_generation"])
                metadata["runtime_generation"] = "replacement"
                (scope / "session.json").write_text(json.dumps(metadata))
                changed = subprocess.run(command + ["draft-read", session, request], env=env,
                                         capture_output=True, timeout=5)
                self.assertNotEqual(changed.returncode, 0)
            finally:
                stream.close()
                try:
                    deadline = time.monotonic() + 8
                    while True:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(3)
                            control.connect(str(state / "host.sock"))
                            control.sendall(encode(b"K", 1, identity.encode()))
                            _, _, data = frame(control)
                        if data[13:] == b"closed" or time.monotonic() > deadline: break
                        time.sleep(.05)
                finally:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_runtime_probe_resolves_unified_remote_state_dir_and_epoch_fallback(self):
        with tempfile.TemporaryDirectory(prefix="omg-runtime-sstate-", dir="/tmp") as directory:
            home = Path(directory)
            revision = "unified-epoch-rev-1"
            rstate = "s-0123456789ab"
            state = home / ".omg/run" / rstate
            state.mkdir(parents=True, mode=0o700)
            vdir = home / ".local/share/oh-my-ghostty/session-runtime/versions" / revision
            vdir.mkdir(parents=True, mode=0o700)
            (vdir / "remote-state-dir").write_text(rstate + "\n")

            # Also seed an ended record in another epoch directory to ensure ended records are skipped.
            stale_state = home / ".omg/run/s-deadbeef0000"
            (stale_state / "sessions").mkdir(parents=True, mode=0o700)
            stale_state.chmod(0o700)

            original = home / "agy-draft.txt"
            original.write_text("远端 agy 草稿\n第二行")
            agent = home / "agy"
            agent.write_text(textwrap.dedent("""
                import os, pathlib, subprocess, tty
                tty.setraw(0)
                pathlib.Path(os.environ['DRAFT_INPUT']).with_suffix('.ready').touch()
                while True:
                    data = os.read(0, 64)
                    if not data: break
                    if b'\\x07' in data:
                        subprocess.run([os.environ['VISUAL'], os.environ['DRAFT_INPUT']], check=True)
            """))
            environment = dict(os.environ, HOME=directory, VISUAL="/bin/false", DRAFT_INPUT=str(original))
            daemon = subprocess.Popen([str(BINARY), "host", str(state), "--", sys.executable, str(agent)],
                                      env=environment)
            identity = str(uuid.uuid4()).upper()
            (stale_state / "sessions" / f"{identity}.json").write_text(json.dumps({
                "id": identity,
                "generation": "ended-gen",
                "ended": "explicit_close",
                "pid": 999999,
            }))
            stream = socket.socket(socket.AF_UNIX)
            stream.settimeout(8)
            try:
                wait_socket(state / "host.sock", daemon)
                stream.connect(str(state / "host.sock"))
                stream.sendall(encode(b"H", 1, identity.encode()))
                inner_event(stream, 1, b"J")
                offset, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", offset)))
                stream.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(stream, 1, b"W")
                for _ in range(100):
                    if original.with_suffix(".ready").exists():
                        break
                    time.sleep(.02)
                self.assertTrue(original.with_suffix(".ready").exists())

                source = (ROOT / "macos/Sources/Features/QuickInput/QuickInputRemoteDraftBridge.swift").read_text()
                probe = textwrap.dedent(source.split('static let runtimeProbe = #"""', 1)[1].split('"""#', 1)[0])

                # 1. Resolves via versions/<revision>/remote-state-dir -> ~/.omg/run/s-<hash12>.
                result = subprocess.run([sys.executable, "-", revision, identity], input=probe, env=environment,
                                        capture_output=True, text=True, check=True, timeout=8)
                target = json.loads(result.stdout)
                session = "omg-runtime-" + identity.lower()
                self.assertEqual(target["session"], session)
                self.assertEqual(target["root"], str(state / "draft"))
                self.assertIn(str(agent), target["commands"])

                # 2. Full draft-begin + Ctrl+G + draft-read + draft-replace round trip under s-<hash12>.
                env = dict(environment, OMG_REMOTE_ROOT=target["root"])
                command = [sys.executable, str(Path(target["root"]) / "omg")]
                import_req = str(uuid.uuid4())
                subprocess.run(command + ["draft-begin", session, import_req, target["tty"], target["generation"]],
                               env=env, capture_output=True, check=True, timeout=5)
                stream.sendall(encode(b"D", 1, encode(b"I", 0, b"\x07")))
                imported = subprocess.run(command + ["draft-read", session, import_req], env=env,
                                          capture_output=True, check=True, timeout=8)
                self.assertEqual(imported.stdout, "OMG_REMOTE_DRAFT_V1\n远端 agy 草稿\n第二行".encode())

                replace_req = str(uuid.uuid4())
                replacement = "替换后的完整远端消息\n第三行"
                subprocess.run(command + ["draft-replace", session, replace_req, target["tty"], target["generation"]],
                               input=replacement.encode(), env=env, capture_output=True, check=True, timeout=5)
                stream.sendall(encode(b"D", 1, encode(b"I", 0, b"\x07")))
                replaced = subprocess.run(command + ["draft-read", session, replace_req], env=env,
                                          capture_output=True, check=True, timeout=8)
                self.assertEqual(replaced.stdout, ("OMG_REMOTE_DRAFT_V1\n" + replacement).encode())
                self.assertEqual(original.read_text(), replacement)

                # 3. After compatible in-place upgrade where gc-remote removed old versions/<old_revision>,
                #    scanning ~/.omg/run/s-* sorted by mtime descending picks the newest live epoch
                #    even when an older epoch has a lexicographically larger directory name (s-ffff...).
                (vdir / "remote-state-dir").unlink()
                older_lex_later = home / ".omg/run/s-ffffffffffff"
                (older_lex_later / "sessions").mkdir(parents=True, mode=0o700)
                older_lex_later.chmod(0o700)
                (older_lex_later / "sessions" / f"{identity}.json").write_text(json.dumps({
                    "id": identity,
                    "generation": "stale-live-gen",
                    "ended": None,
                    "pid": 999999,
                }))
                old_ts = time.time() - 3600
                os.utime(older_lex_later, (old_ts, old_ts))
                now_ts = time.time()
                os.utime(state, (now_ts, now_ts))
                fallback = subprocess.run([sys.executable, "-", "gc-removed-old-rev", identity],
                                          input=probe, env=environment, capture_output=True,
                                          text=True, check=True, timeout=8)
                self.assertEqual(json.loads(fallback.stdout)["root"], str(state / "draft"))
            finally:
                stream.close()
                try:
                    deadline = time.monotonic() + 8
                    while True:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(3)
                            control.connect(str(state / "host.sock"))
                            control.sendall(encode(b"K", 1, identity.encode()))
                            _, _, data = frame(control)
                        if data[13:] == b"closed" or time.monotonic() > deadline:
                            break
                        time.sleep(.05)
                finally:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_probe_safe_identity_preserves_wrappers_without_leaking_prompt_arguments(self):
        source = (ROOT / "macos/Sources/Features/QuickInput/QuickInputRemoteDraftBridge.swift").read_text()
        probe = textwrap.dedent(source.split('static let runtimeProbe = #"""', 1)[1].split('"""#', 1)[0])
        fn_src = "import os\ndef safe_identity" + probe.split("def safe_identity", 1)[1].split("def probe_tty_and_foreground", 1)[0]
        ns = {}
        exec(fn_src, ns)
        safe_identity = ns["safe_identity"]

        self.assertEqual(safe_identity(["agy", "secret prompt text"]), ["agy"])
        self.assertEqual(
            safe_identity(["python3.12", "-u", "/home/user/.local/bin/aider", "my secret/prompt"]),
            ["python3.12", "-u", "/home/user/.local/bin/aider"],
        )
        self.assertEqual(
            safe_identity(["/usr/bin/env", "HTTPS_PROXY=http://u:p@proxy/secret", "python3", "/opt/tools/bin/kimi", "confidential"]),
            ["/usr/bin/env", "python3", "/opt/tools/bin/kimi"],
        )
        self.assertEqual(
            safe_identity(["/usr/bin/env", "AGY_CLI_OSC7501=on", "agy", "fix src/secret.py"]),
            ["/usr/bin/env", "agy"],
        )
        self.assertEqual(
            safe_identity(["/bin/bash", "/home/user/.local/bin/agy", "secret"]),
            ["/bin/bash", "/home/user/.local/bin/agy"],
        )
        self.assertEqual(
            safe_identity(["node", "-r", "/opt/preload.js", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "secret/arg"]),
            ["node", "-r", "/opt/preload.js", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
        )

    def test_login_shell_rc_editor_override_preserves_draft_bridge_and_delegates_fallback(self):
        shells = [s for s in ("/bin/bash", "/bin/zsh") if Path(s).is_file()]
        self.assertTrue(shells)
        for shell_path in shells:
            with self.subTest(shell=shell_path), tempfile.TemporaryDirectory(prefix="omg-rc-editor-", dir="/tmp") as directory:
                home = Path(directory)
                state = home / ".omg/run/s-abcdef012345"
                state.mkdir(parents=True, mode=0o700)
                rc_marker = home / "rc_editor_ran.txt"
                rc_editor = home / "user_rc_editor.py"
                rc_editor.write_text(textwrap.dedent(f"""\
                    #!{sys.executable}
                    import pathlib, sys
                    pathlib.Path({str(rc_marker)!r}).write_text(sys.argv[1])
                """))
                rc_editor.chmod(0o700)
                rc_line = f'export EDITOR="{rc_editor}"\nexport VISUAL="{rc_editor}"\n'
                for rc_name in (".bash_profile", ".bashrc", ".zshrc"):
                    (home / rc_name).write_text(rc_line)

                draft_file = home / "shell-draft.txt"
                draft_file.write_text("RC 覆盖后仍可导入草稿")
                ordinary_file = home / "ordinary.txt"
                ordinary_file.write_text("ordinary edit")

                environment = dict(os.environ, HOME=directory, SHELL=shell_path, TERM="xterm-256color")
                environment.pop("ZDOTDIR", None)
                environment.pop("PROMPT_COMMAND", None)
                daemon = subprocess.Popen([str(BINARY), "host", str(state), "--", shell_path, "-l"],
                                          env=environment)
                identity = str(uuid.uuid4()).upper()
                stream = socket.socket(socket.AF_UNIX)
                stream.settimeout(8)
                try:
                    wait_socket(state / "host.sock", daemon)
                    stream.connect(str(state / "host.sock"))
                    stream.sendall(encode(b"H", 1, identity.encode()))
                    inner_event(stream, 1, b"J")
                    offset, _ = inner_event(stream, 1, b"S")
                    stream.sendall(encode(b"D", 1, encode(b"A", offset)))
                    stream.sendall(encode(b"D", 1, encode(b"W")))
                    inner_event(stream, 1, b"W")

                    # Wait for the interactive login shell to finish RC + first prompt hook.
                    ready_sentinel = home / "prompt.ready"
                    stream.sendall(encode(b"D", 1, encode(b"I", 0, f'touch "{ready_sentinel}"\r'.encode())))
                    for _ in range(100):
                        if ready_sentinel.exists():
                            break
                        time.sleep(0.03)
                    self.assertTrue(ready_sentinel.exists())

                    session = "omg-runtime-" + identity.lower()
                    root = state / "draft"
                    scope = root / "sessions" / hashlib.sha256(session.encode()).hexdigest()
                    metadata = json.loads((scope / "session.json").read_text())
                    env = dict(environment, OMG_REMOTE_ROOT=str(root))
                    command = [sys.executable, str(root / "omg")]
                    req = str(uuid.uuid4())
                    subprocess.run(command + ["draft-begin", session, req, metadata["tty"], metadata["runtime_generation"]],
                                   env=env, capture_output=True, check=True, timeout=5)
                    stream.sendall(encode(b"D", 1, encode(b"I", 0, f'"$EDITOR" "{draft_file}"\r'.encode())))
                    imported = subprocess.run(command + ["draft-read", session, req], env=env,
                                              capture_output=True, check=True, timeout=8)
                    self.assertEqual(imported.stdout, "OMG_REMOTE_DRAFT_V1\nRC 覆盖后仍可导入草稿".encode())
                    self.assertFalse(rc_marker.exists(), "Active draft import must not open user RC editor")
                    subprocess.run(command + ["draft-finish", session, req], env=env,
                                   capture_output=True, check=True, timeout=5)

                    # Without an active draft request, $EDITOR delegates to the user's RC editor.
                    stream.sendall(encode(b"D", 1, encode(b"I", 0, f'"$EDITOR" "{ordinary_file}"\r'.encode())))
                    for _ in range(100):
                        if rc_marker.exists():
                            break
                        time.sleep(0.03)
                    self.assertTrue(rc_marker.exists())
                    self.assertEqual(rc_marker.read_text(), str(ordinary_file))
                finally:
                    stream.close()
                    try:
                        deadline = time.monotonic() + 8
                        while True:
                            with socket.socket(socket.AF_UNIX) as control:
                                control.settimeout(3)
                                control.connect(str(state / "host.sock"))
                                control.sendall(encode(b"K", 1, identity.encode()))
                                _, _, data = frame(control)
                            if data[13:] == b"closed" or time.monotonic() > deadline:
                                break
                            time.sleep(0.05)
                    finally:
                        daemon.terminate()
                        daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
