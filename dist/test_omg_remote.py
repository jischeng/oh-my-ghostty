"""Exercise the unified remote OMG command without an SSH server."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

SOURCE = Path(__file__).resolve().parents[1] / "src/shell-integration/omg/omg.py"
spec = importlib.util.spec_from_file_location("omg_remote", SOURCE)
omg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(omg)


class RemoteOMGTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"HOME": str(self.home)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        with patch.object(os, "ttyname", return_value="/dev/pts/42"):
            omg.main(["install", "session"])
            omg.main(["session-start", "session", "nano"])
        self.directory = omg.session_directory("session")
        self.request = str(uuid.uuid4()).upper()

    def test_full_draft_preserves_agent_file_and_private_modes(self):
        draft = self.home / "draft.md"
        text = "中文 draft\nsecond line\n"
        draft.write_text(text)
        omg.main(["draft-begin", "session", self.request, "/dev/pts/42"])
        omg.main(["editor", "session", str(draft)])
        response = self.directory / (self.request + ".response")
        self.assertEqual(response.read_text(), text)
        self.assertEqual(draft.read_text(), text)
        self.assertEqual(response.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        omg.main(["draft-finish", "session", self.request])
        self.assertFalse(response.exists())
        self.assertFalse((self.directory / "request.json").exists())

    def test_shared_execution_entry_preserves_command(self):
        with patch.object(os, "execv", side_effect=RuntimeError("executed")) as execute:
            with self.assertRaisesRegex(RuntimeError, "executed"):
                omg.main(["exec", "exec python3 -"])
        execute.assert_called_once_with("/bin/sh", ["sh", "-c", "exec python3 -"])

    def test_shared_execution_preserves_stdin_and_exit_code(self):
        import subprocess
        import sys
        result = subprocess.run([sys.executable, str(SOURCE), "exec", "cat; exit 7"],
                                input="中文 task\n".encode(), capture_output=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "中文 task\n".encode())

    def test_wrong_tty_cannot_arm_editor(self):
        with self.assertRaises(ValueError):
            omg.main(["draft-begin", "session", self.request, "/dev/pts/99"])
        self.assertFalse((self.directory / "request.json").exists())

    def test_expired_request_delegates_to_original_editor(self):
        (self.directory / "request.json").write_text(json.dumps({"id": self.request, "expires": 0}))
        with patch.object(os, "execv", side_effect=RuntimeError("delegated")) as execute:
            with self.assertRaisesRegex(RuntimeError, "delegated"):
                omg.main(["editor", "session", "draft"])
        self.assertIn("nano", execute.call_args.args[1][2])

    def test_invalid_draft_is_rejected(self):
        for data in (b"\0", b"\xff", b"x" * (omg.LIMIT + 1)):
            with self.assertRaises((ValueError, UnicodeError)):
                omg.validate(data)

    def test_requests_are_isolated_and_cleanup_does_not_delete_newer_request(self):
        omg.main(["draft-begin", "session", self.request, "/dev/pts/42"])
        newer = str(uuid.uuid4()).upper()
        omg.main(["draft-begin", "session", newer, "/dev/pts/42"])
        omg.main(["draft-finish", "session", self.request])
        self.assertEqual(omg.read_json(self.directory / "request.json")["id"], newer)
        self.assertNotEqual(omg.session_directory("another"), self.directory)

    def test_symlink_root_is_rejected(self):
        runtime = omg.root()
        runtime.rename(runtime.with_name("real"))
        runtime.symlink_to(runtime.with_name("real"), target_is_directory=True)
        with self.assertRaises(ValueError):
            omg.root()


if __name__ == "__main__":
    unittest.main()
