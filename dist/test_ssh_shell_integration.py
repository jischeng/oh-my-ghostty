#!/usr/bin/env python3
"""Exercise the real +ssh-generated startup via a local fake transport and PTY.

No network, user dotfiles, or SSH credentials are used. Example:
  python3 dist/test_ssh_shell_integration.py --omg macos/build/Debug/OMG.app/Contents/MacOS/omg
Build the native GhosttyKit and macOS app first; never point at a user installation.
"""
import argparse
import fcntl
import os
from pathlib import Path
import re
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
OSC = re.compile(rb"\x1b\]133;([^\x07\x1b]*)(?:\x07|\x1b\\)")


class Session:
    def __init__(self, argv, env):
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))

        def controlling_tty():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(argv, env=env, stdin=slave, stdout=slave,
                                        stderr=slave, preexec_fn=controlling_tty)
        os.close(slave)

    def read(self, required=b"TEST>", timeout=8):
        output = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.15)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            elif required in output and b"133;B" in output:
                return bytes(output)
            if self.process.poll() is not None:
                break
        raise AssertionError(f"prompt not received (exit={self.process.poll()}): {bytes(output)[-1200:]!r}")

    def command(self, text):
        os.write(self.master, text.encode() + b"\n")
        return self.read()

    def close(self):
        if self.process.poll() is None:
            os.write(self.master, b"exit\n")
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.close(self.master)
                self.process.kill()
                self.process.wait(timeout=5)
                return
        os.close(self.master)


def markers(data, kind):
    return [m for m in OSC.findall(data) if m.split(b";", 1)[0] == kind]


def exercise(binary, shell, mode, preintegrated=False):
    name = Path(shell).name
    with tempfile.TemporaryDirectory(prefix="omg-ssh shell's-") as temporary:
        home = Path(temporary)
        config = home / ".config" / "fish"
        config.mkdir(parents=True)
        # Prompt exposes status at its entry, before any printing. It is a
        # stand-in for themes such as Starship which consume these variables.
        if name == "fish":
            (config / "config.fish").write_text(
                "function fish_prompt; builtin printf '[S:%s P:%s] TEST> ' $status \"$pipestatus\"; end\n"
                "function ll; builtin printf 'LIST\\n'; end\n"
                "function user_hook --on-event fish_preexec; builtin printf x >> \"$HOME/user-hook\"; end\n"
            )
        elif name == "zsh":
            (home / ".zshrc").write_text(
                "PROMPT='[S:%?] TEST> '\nPS2='CONT> '\nalias ll=\"printf 'LIST\\\\n'\"\n"
                "user_hook() { builtin print -rn x >> \"$HOME/user-hook\"; }\n"
                "preexec_functions+=(user_hook)\n"
            )
        else:
            (home / ".bashrc").write_text(
                "user_prompt() { local result=$?; PS1=\"[S:$result] TEST> \"; }\n"
                "PROMPT_COMMAND='user_prompt;'\nPS2='CONT> '\nalias ll=\"printf 'LIST\\\\n'\"\n"
                "trap 'builtin printf x >> \"$HOME/user-hook\"' DEBUG\n"
            )
        if preintegrated:
            rc = config / "config.fish" if name == "fish" else home / (".zshrc" if name == "zsh" else ".bashrc")
            integration = ("fish/vendor_conf.d/ghostty-shell-integration.fish" if name == "fish"
                           else "zsh/ghostty-integration" if name == "zsh" else "bash/ghostty.bash")
            with rc.open("a") as f:
                f.write(f'\nsource "{ROOT}/src/shell-integration/{integration}"\n')
        fixture = {p: p.read_bytes() for p in [config / "config.fish", home / ".zshrc", home / ".bashrc"] if p.exists()}
        # Explicit --ssh executable captures the real generated payload and
        # executes it locally; it cannot make an SSH connection.
        fake = home / "fake-ssh"
        fake.write_text("#!/bin/sh\n[ \"$1\" = fixture ] && [ \"$2\" = -tt ] && [ $# = 3 ] || exit 91\n"
                        "printf %s \"$3\" | wc -c > \"$HOME/payload-size\"\nexec /bin/sh -c \"$3\"\n")
        fake.chmod(0o700)
        env = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
               "TERM": "dumb", "SHELL": shell, "TMPDIR": str(home),
               "PATH": f"{Path(shell).parent}:/usr/bin:/bin:/usr/sbin:/sbin",
               "GHOSTTY_RESOURCES_DIR": str(ROOT / "src"), "GHOSTTY_SHELL_FEATURES": "",
               "fish_features": "no-keyboard-protocols"}
        if mode == "remote":
            argv = [binary, "+ssh", "--terminfo=false", "--forward-env=false", "--cache=false", f"--ssh={fake}", "--", "fixture"]
        else:
            if name == "fish":
                argv = [shell, "-i", "-C", f'source "{ROOT}/src/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"']
            else:
                rc = home / (".zshrc" if name == "zsh" else ".bashrc")
                integration = "zsh/ghostty-integration" if name == "zsh" else "bash/ghostty.bash"
                with rc.open("a") as f:
                    f.write(f'\nsource "{ROOT}/src/shell-integration/{integration}"\n')
                argv = [shell, "-i"]
            fixture = {p: p.read_bytes() for p in fixture}
        session = Session(argv, env)
        try:
            session.read()
            if mode == "remote":
                # Leave headroom below Linux's common single-argument limit.
                assert int((home / "payload-size").read_text()) < 120 * 1024
            for _ in range(4):
                result = session.command("ll")
                assert len(markers(result, b"C")) == 1, (name, mode, "duplicate/missing C", result[-700:])
            failed = session.command("false")
            assert b"[S:1" in failed, (name, mode, "prompt status changed", failed[-700:])
            assert any(m.startswith(b"D;1") for m in markers(failed, b"D")), (name, mode, "wrong D", markers(failed, b"D"))
            if name == "fish":
                pipeline = session.command("false | true")
                assert b"[S:0 P:1 0]" in pipeline, (name, mode, "pipestatus changed", pipeline[-700:])
            if name != "fish":
                session.command("PS2='NEXT_CONT> '")
                declaration = session.command("typeset -p PS2")
                # Legacy Bash/Zsh preexec remove markers before the command;
                # modern Bash's PS0 runs in a subshell and leaves one wrapper.
                assert declaration.count(b"133;P;k=s") <= 1, (name, mode, "accumulating PS2 wrappers")
                assert b"NEXT_CONT> " in declaration, (name, mode, "lost user PS2")
            multiline = session.command('printf "%s\\n" "one\ntwo"')
            assert len(markers(multiline, b"C")) == 1, (name, mode, "multiline C", multiline[-800:])
            if name != "fish":
                continuation = [m for m in markers(multiline, b"P") if m.startswith(b"P;k=s")]
                assert continuation, (name, mode, "PS2 unmarked")
                assert b"NEXT_CONT> " in multiline, (name, mode, "overwrote user PS2")
            assert (home / "user-hook").stat().st_size >= 4, "lost existing user hook"
            # Re-sourcing the shared integration must not wrap the prompt or
            # register preexec twice. The SSH path uses the same runtime guard.
            if mode == "local":
                integration = ("fish/ghostty-command-markers.fish" if name == "fish"
                               else "zsh/ghostty-integration" if name == "zsh" else "bash/ghostty.bash")
                session.command(f'source "{ROOT}/src/shell-integration/{integration}"')
                if name == "fish":
                    session.command("__ghostty_command_markers_init")
                again = session.command("ll")
                assert len(markers(again, b"C")) == 1, "reinitialization duplicated preexec"
            empty = session.command("")
            assert not markers(empty, b"C"), "empty Enter recorded as execution"
            os.write(session.master, b"echo NEVER_RUN")
            time.sleep(0.05)  # Let the editor render before cancelling its input.
            os.write(session.master, b"\x03\x0c")
            cancelled = session.read()
            assert not markers(cancelled, b"C"), "cancelled input recorded as execution"
            # Resize/repaint must not create a new command record.
            fcntl.ioctl(session.master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 70, 0, 0))
            os.write(session.master, b"\x0c")
            redraw = session.read()
            assert not markers(redraw, b"C"), (name, mode, "redraw emitted C")
            for p, original in fixture.items():
                assert p.read_bytes() == original, f"modified user config: {p.name}"
            assert not list(home.glob("omg-ssh.*")), "temporary bootstrap leaked"
            existing = " (existing integration)" if preintegrated else ""
            print(f"PASS {mode} {shell}{existing}: repeats, status, PS2, empty/cancel, resize, user hooks, rc preservation")
        finally:
            session.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omg", required=True)
    parser.add_argument("--shell", action="append", help="test selected Shell executable(s)")
    args = parser.parse_args()
    binary = str(Path(args.omg).resolve())
    candidates = args.shell or ["/bin/bash", "/opt/homebrew/bin/bash", "/bin/zsh", shutil.which("fish")]
    for shell in dict.fromkeys(candidates):
        if shell and Path(shell).is_file():
            for mode in ["local", "remote"]:
                exercise(binary, shell, mode)
            exercise(binary, shell, "remote", preintegrated=True)


if __name__ == "__main__":
    main()
