"""Credential automation contracts; never use a real login Keychain in tests."""

from contextlib import contextmanager
import ctypes
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("omg_keychain", ROOT / "dist/macos/omg_keychain.py")
keychain = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(keychain)
SIGN_SPEC = importlib.util.spec_from_file_location("omg_signing", ROOT / "dist/macos/omg_signing.py")
signing = importlib.util.module_from_spec(SIGN_SPEC)
SIGN_SPEC.loader.exec_module(signing)
PIN = "A" * 40
SIGNING = Path("/private/test/signing.keychain-db")
CREDENTIALS = Path("/private/test/credentials.keychain-db")


class FakeKeychain:
    def __init__(self, unlocked=False):
        self.is_unlocked = unlocked
        self.events = []
        self.fail_unlock = False
        self.fail_access = False
        self.secret = ctypes.create_string_buffer(b"fixture-password")

    @contextmanager
    def open(self, path):
        self.events.append(("open", path))
        yield path
        self.events.append(("close", path))

    def unlocked(self, handle):
        self.events.append(("status", handle))
        return self.is_unlocked

    def lock(self, handle):
        self.events.append(("lock", handle))
        self.is_unlocked = False

    def unlock(self, handle, length, pointer):
        self.events.append(("unlock", handle, length))
        if self.fail_unlock:
            raise keychain.KeychainError("wrong signing password")
        self.is_unlocked = True

    def store(self, handle, account, length, pointer):
        self.events.append(("store", handle, account, length))

    @contextmanager
    def password(self, handle, account):
        self.events.append(("password", handle, account))
        if self.fail_access:
            raise keychain.KeychainError("credential access denied")
        try:
            yield ctypes.sizeof(self.secret) - 1, ctypes.cast(self.secret, ctypes.c_void_p)
        finally:
            ctypes.memset(self.secret, 0, ctypes.sizeof(self.secret))


class CredentialContracts(unittest.TestCase):
    def test_already_unlocked_does_not_read_a_credential(self):
        api = FakeKeychain(unlocked=True)
        self.assertEqual(keychain.unlock(SIGNING, PIN, api, CREDENTIALS), "already-unlocked")
        self.assertFalse(any(event[0] in ("password", "unlock") for event in api.events))
        self.assertNotIn(("open", CREDENTIALS), api.events)

    def test_auto_unlock_uses_matching_certificate_and_clears_buffer(self):
        api = FakeKeychain()
        self.assertEqual(keychain.unlock(SIGNING, PIN.lower(), api, CREDENTIALS), "unlocked")
        self.assertIn(("password", CREDENTIALS, PIN.encode()), api.events)
        self.assertTrue(api.is_unlocked)
        self.assertEqual(api.secret.raw, b"\0" * ctypes.sizeof(api.secret))

    def test_denied_access_fails_closed(self):
        api = FakeKeychain()
        api.fail_access = True
        with self.assertRaisesRegex(keychain.KeychainError, "denied"):
            keychain.unlock(SIGNING, PIN, api, CREDENTIALS)
        self.assertFalse(any(event[0] == "unlock" for event in api.events))

    def test_wrong_saved_password_still_clears_retrieved_buffer(self):
        api = FakeKeychain()
        api.fail_unlock = True
        with self.assertRaises(keychain.KeychainError):
            keychain.unlock(SIGNING, PIN, api, CREDENTIALS)
        self.assertEqual(api.secret.raw, b"\0" * ctypes.sizeof(api.secret))

    def test_store_validates_password_before_saving(self):
        api = FakeKeychain(unlocked=True)
        with patch.object(keychain.ctypes, "memset", wraps=ctypes.memset) as clear:
            keychain.store_password(SIGNING, PIN, "fixture-password", api, CREDENTIALS)
        operations = [event[0] for event in api.events]
        self.assertLess(operations.index("lock"), operations.index("unlock"))
        self.assertLess(operations.index("unlock"), operations.index("store"))
        self.assertIn(("store", CREDENTIALS, PIN.encode(), 16), api.events)
        clear.assert_called_once()

    def test_wrong_input_is_not_saved_and_buffer_is_cleared(self):
        api = FakeKeychain()
        api.fail_unlock = True
        with patch.object(keychain.ctypes, "memset", wraps=ctypes.memset) as clear:
            with self.assertRaises(keychain.KeychainError):
                keychain.store_password(SIGNING, PIN, "fixture-password", api, CREDENTIALS)
        self.assertFalse(any(event[0] == "store" for event in api.events))
        clear.assert_called_once()

    def test_login_and_signing_keychains_cannot_be_the_same(self):
        api = FakeKeychain()
        with self.assertRaisesRegex(keychain.KeychainError, "separate"):
            keychain.store_password(SIGNING, PIN, "fixture-password", api, SIGNING)
        with self.assertRaisesRegex(keychain.KeychainError, "separate"):
            keychain.unlock(SIGNING, PIN, api, SIGNING)
        self.assertEqual(api.events, [])

    def test_invalid_passwords_and_identity_do_not_access_keychains(self):
        api = FakeKeychain()
        for value in ("", "line\nbreak", "nul\0byte"):
            with self.assertRaises(keychain.KeychainError):
                keychain.store_password(SIGNING, PIN, value, api, CREDENTIALS)
        with self.assertRaises(keychain.KeychainError):
            keychain.unlock(SIGNING, "untrusted-name", api, CREDENTIALS)
        self.assertEqual(api.events, [])

    def test_interaction_is_enabled_only_for_manual_setup(self):
        api = FakeKeychain()
        with patch.object(keychain, "MacKeychain", return_value=api) as backend:
            keychain.store_password(SIGNING, PIN, "fixture-password", credential_path=CREDENTIALS)
            backend.assert_called_once_with(interactive=True)
        with patch.object(keychain, "MacKeychain", return_value=api) as backend:
            keychain.unlock(SIGNING, PIN, credential_path=CREDENTIALS)
            backend.assert_called_once_with(interactive=False)

    def test_cli_rejects_noninteractive_setup_without_reading_password(self):
        with patch.object(sys, "argv", ["omg_signing.py", "store-password"]), patch("sys.stdin.isatty", return_value=False), patch.object(signing.getpass, "getpass") as prompt, patch("sys.stderr"):
            self.assertEqual(signing.main(), 1)
            prompt.assert_not_called()

    def test_cli_store_never_prints_secret(self):
        with patch.object(sys, "argv", ["omg_signing.py", "store-password"]), patch("sys.stdin.isatty", return_value=True), patch.object(signing.getpass, "getpass", return_value="fixture-secret"), patch.object(signing, "unlock_signing_keychain") as store, patch("sys.stdout") as output:
            self.assertEqual(signing.main(), 0)
            store.assert_called_once_with("fixture-secret")
            self.assertNotIn("fixture-secret", "".join(str(c) for c in output.write.call_args_list))


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("OMG_RUN_SIGNING_SMOKE") == "1", "opt-in isolated macOS credential smoke")
class NativeCredentialSmoke(unittest.TestCase):
    def test_private_fixture_keychains_round_trip_without_login_changes(self):
        import secrets
        with tempfile.TemporaryDirectory(prefix="omg-keychain-smoke-") as temp:
            temp = Path(temp)
            paths = [temp / "signing", temp / "credentials"]
            password = secrets.token_urlsafe(32)
            try:
                for path, value in [(paths[0], password), (paths[1], secrets.token_urlsafe(32))]:
                    try:
                        signing.create_identity(path, value)
                    except subprocess.CalledProcessError as error:
                        raise AssertionError(f"fixture creation failed (exit {error.returncode}); credentials omitted") from None
                config = dict(
                    (line[7:].split("=", 1)[0], signing.shlex.split(line.split("=", 1)[1])[0])
                    for line in (paths[0] / "signing.env").read_text().splitlines()
                )
                path = Path(config["OMG_SIGNING_KEYCHAIN"])
                credentials = paths[1] / "release.keychain-db"
                identity = config["OMG_SIGNING_IDENTITY"]
                keychain.store_password(path, identity, password, credential_path=credentials)
                api = keychain.MacKeychain()
                with api.open(path) as handle:
                    api.lock(handle)
                    self.assertFalse(api.unlocked(handle))
                self.assertEqual(keychain.unlock(path, identity, credential_path=credentials), "unlocked")
                self.assertEqual(keychain.unlock(path, identity, credential_path=credentials), "already-unlocked")
                # Updating an existing generic item must also work without reading it.
                keychain.store_password(path, identity, password, credential_path=credentials)
            finally:
                for directory in paths:
                    file = directory / "release.keychain-db"
                    if file.exists():
                        subprocess.run(["security", "delete-keychain", str(file)], capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()
