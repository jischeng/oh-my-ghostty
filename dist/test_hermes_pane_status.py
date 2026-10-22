"""Exercise the production Hermes reporter/probe, including cross-pane isolation.

The Python bodies are embedded in Swift so both local and SSH use exactly the
same implementation. These tests execute those bodies with bounded ps fixtures;
they do not require Hermes, a model provider, or user credentials.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SOURCE = (Path(__file__).resolve().parents[1] /
          "macos/Sources/Features/Plugins/AgentStatusPlugin.swift").read_text()


def body(name):
    return SOURCE.split('static let ' + name + ' = #"""\n', 1)[1].split('\n"""#', 1)[0]


class HermesPaneStatusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"HOME": str(self.home),
                                                  "HERMES_HOME": str(self.home / ".hermes")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.namespace = {}
        exec(body("probe"), self.namespace)
        self.tty = "/dev/pts/7"
        self.sid = "local-" + "a" * 64
        self.crumb(self.tty, self.sid)

    def crumb(self, tty, sid, timestamp=None):
        directory = self.home / ".hermes/terminal-sessions"
        directory.mkdir(parents=True, exist_ok=True)
        name = "tty-" + tty.strip("/").replace("/", "-")
        (directory / name).write_text(json.dumps({
            "session_id": sid, "cwd": "/work/project", "ts": timestamp or time.time()}))

    def report(self, sid, state):
        result = subprocess.run([sys.executable, "-c", body("reporter"), state],
                                input=json.dumps({"session_id": sid}), text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def probe(self, tty=None, foreground=True, active=True):
        def ps(args, **kwargs):
            if "etime=" in args:
                return SimpleNamespace(stdout="00:10\n", returncode=0)
            lines = ""
            if active:
                flags = "S+" if foreground else "S"
                lines = (f"321 320 {flags} /home/user/.hermes/tools/node/bin/node "
                         "--expose-gc /home/user/.hermes/hermes-agent/ui-tui/dist/entry.js\n")
            return SimpleNamespace(stdout=lines, returncode=0)
        with patch.object(self.namespace["subprocess"], "run", side_effect=ps):
            return self.namespace["snapshot"](tty or self.tty)

    def test_real_client_is_identified_before_any_hook(self):
        result = self.probe()
        self.assertEqual(result["pgid"], 320)
        self.assertEqual(result["state"], "idle")
        self.assertEqual(result["conversation"], self.sid)

    def test_daemon_event_matches_only_its_own_terminal_session(self):
        other_sid = "local-" + "b" * 64
        self.crumb("/dev/pts/8", other_sid)
        self.report(self.sid, "working")
        self.report(other_sid, "done")
        self.assertEqual(self.probe()["state"], "working")
        result = self.probe("/dev/pts/8")
        self.assertEqual(result["state"], "done")
        self.assertEqual(result["conversation"], other_sid)

    def test_hook_test_cannot_poison_session_restoration(self):
        self.report(self.sid, "working")
        self.report("test-session", "done")
        self.assertEqual(self.probe()["state"], "working")
        directory = self.home / ".config/oh-my-ghostty/agent-status/hermes"
        self.assertEqual(len(list(directory.glob("*.json"))), 1)
        self.crumb(self.tty, "test-session")
        self.assertNotIn("conversation", self.probe())

    def test_exited_or_background_client_is_not_shown(self):
        self.report(self.sid, "working")
        self.assertEqual(self.probe(active=False), {})
        self.assertEqual(self.probe(foreground=False), {})

    def test_reused_tty_does_not_resume_old_breadcrumb(self):
        self.crumb(self.tty, self.sid, time.time() - 3600)
        self.assertNotIn("conversation", self.probe())

    def test_reporter_permissions_and_payload_boundaries(self):
        self.report(self.sid, "working")
        directory = self.home / ".config/oh-my-ghostty/agent-status/hermes"
        path = directory / (hashlib.sha256(self.sid.encode()).hexdigest() + ".json")
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.report("../../other", "done")
        self.assertEqual(len(list(directory.glob("*.json"))), 1)

    def test_symlink_breadcrumb_is_rejected(self):
        path = self.home / ".hermes/terminal-sessions/tty-dev-pts-7"
        original = path.read_text()
        path.unlink()
        target = self.home / "other.json"
        target.write_text(original)
        path.symlink_to(target)
        self.assertNotIn("conversation", self.probe())


if __name__ == "__main__":
    unittest.main()
