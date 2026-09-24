#!/usr/bin/env python3
"""Network-free sshd stand-in for test_ssh_shell_integration.py.

Use a SECOND controlling PTY, as real SSH does. Reusing the client PTY would
send Ctrl-C to the local wrapper and remote Shell together, masking bugs or
creating failures that cannot occur over an actual SSH transport.
"""
import fcntl
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import termios
import tty


def main():
    if len(sys.argv) != 4 or sys.argv[1:3] != ["fixture", "-tt"]:
        return 91
    payload = sys.argv[3]
    Path(os.environ["HOME"], "payload-size").write_text(str(len(payload.encode())))
    master, slave = os.openpty()
    previous = termios.tcgetattr(0)

    def resize(*_):
        try:
            size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
            fcntl.ioctl(master, termios.TIOCSWINSZ, size)
        except OSError:
            pass

    def controlling_tty():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    child = None
    try:
        resize()
        tty.setraw(0)
        signal.signal(signal.SIGWINCH, resize)
        # sshd uses the account's login Shell, NOT necessarily /bin/sh.
        child = subprocess.Popen([os.environ["SHELL"], "-c", payload],
                                 stdin=slave, stdout=slave, stderr=slave,
                                 preexec_fn=controlling_tty)
        os.close(slave)
        slave = -1
        while True:
            readable, _, _ = select.select([0, master], [], [], 0.1)
            for descriptor in readable:
                try:
                    data = os.read(descriptor, 65536)
                except OSError:
                    data = b""
                if not data:
                    return child.wait(timeout=3)
                destination = master if descriptor == 0 else 1
                view = memoryview(data)
                while view:
                    size = os.write(destination, view)
                    view = view[size:]
            if child.poll() is not None and not readable:
                return child.returncode
    finally:
        termios.tcsetattr(0, termios.TCSANOW, previous)
        os.close(master)
        if slave != -1:
            os.close(slave)
        if child is not None and child.poll() is None:
            child.kill()
            child.wait(timeout=3)


if __name__ == "__main__":
    sys.exit(main())
