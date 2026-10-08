"""Offline signing policy contracts; opt-in real macOS signing/launch smoke test."""

import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("omg_signing", ROOT / "dist/macos/omg_signing.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)
PIN = "A" * 40
OTHER = "B" * 40
ENV = {"OMG_SIGNING_MODE": "self-signed", "OMG_SIGNING_IDENTITY": PIN}


class SigningPolicyTests(unittest.TestCase):
    def test_default_requires_persistent_fingerprint(self):
        self.assertEqual(signing.policy({"OMG_SIGNING_IDENTITY": PIN.lower()}), ("self-signed", PIN))
        for identity in ("", "-", "OMG Release Signing", "A" * 39, 'A" or true'):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                signing.policy({"OMG_SIGNING_IDENTITY": identity})

    def test_ad_hoc_is_explicit_only(self):
        self.assertEqual(signing.policy({"OMG_SIGNING_MODE": "ad-hoc", "OMG_SIGNING_IDENTITY": "-"}), ("ad-hoc", "-"))
        with self.assertRaises(ValueError):
            signing.policy({"OMG_SIGNING_MODE": "ad-hoc", "OMG_SIGNING_IDENTITY": PIN})

    def test_development_and_developer_id_modes(self):
        for mode in ("development", "developer-id"):
            self.assertEqual(signing.policy({"OMG_SIGNING_MODE": mode, "OMG_SIGNING_IDENTITY": "certificate"}), (mode, "certificate"))
            with self.assertRaises(ValueError):
                signing.policy({"OMG_SIGNING_MODE": mode, "OMG_SIGNING_IDENTITY": "-"})
        with self.assertRaises(ValueError):
            signing.policy({"OMG_SIGNING_MODE": "typo", "OMG_SIGNING_IDENTITY": PIN})

    def test_requirement_pins_both_signer_and_identifier(self):
        self.assertEqual(signing.requirement(PIN.lower()), f'identifier "com.jischeng.omg" and certificate leaf = H"{PIN}"')
        with self.assertRaises(ValueError):
            signing.requirement('bad" or true')

    def test_public_packaging_rejects_ad_hoc_and_development(self):
        for mode, identity in [("ad-hoc", "-"), ("development", PIN)]:
            with patch.dict(os.environ, {"OMG_SIGNING_MODE": mode, "OMG_SIGNING_IDENTITY": identity}, clear=True):
                with self.assertRaises(ValueError):
                    signing.verify(Path("nonexistent"))

    def test_release_wrapper_rejects_non_release_modes_before_signing(self):
        script = ROOT / ".agents/skills/omg-release/scripts/package-release.sh"
        for mode, identity in [("ad-hoc", "-"), ("development", PIN)]:
            env = {**os.environ, "OMG_SIGNING_MODE": mode, "OMG_SIGNING_IDENTITY": identity, "PREVIOUS_TAG": "v0.0.0"}
            result = subprocess.run(["/bin/bash", str(script), "0.0.0"], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("public releases require persistent", result.stderr)

    def test_signing_script_rejects_bad_policy_before_mutating_app(self):
        env = {**os.environ, "OMG_SIGNING_MODE": "self-signed", "OMG_SIGNING_IDENTITY": "-"}
        result = subprocess.run(["/bin/bash", str(ROOT / "dist/macos/sign_omg_app.sh"), "nonexistent.app"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no ad-hoc fallback", result.stderr)

    def test_existing_identity_is_never_regenerated(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(signing.sys, "platform", "darwin"), patch.object(signing, "run") as run:
            with self.assertRaisesRegex(ValueError, "already exists"):
                signing.create_identity(Path(temp), "not-a-real-password")
            run.assert_not_called()

    def test_provisioning_refuses_repository_secret_files(self):
        with patch.object(signing.sys, "platform", "darwin"), patch.object(signing, "run") as run:
            with self.assertRaisesRegex(ValueError, "outside the repository"):
                signing.create_identity(ROOT / ".pi/signing-test", "test-password")
            run.assert_not_called()

    def test_cli_does_not_print_password_bearing_command(self):
        with patch.object(sys, "argv", ["omg_signing.py", "create", "/unused"]), patch("sys.stdin.isatty", return_value=True), patch.object(signing.getpass, "getpass", return_value="SECRET"), patch.object(signing, "create_identity", side_effect=subprocess.CalledProcessError(1, ["security", "-p", "SECRET"])), patch("sys.stderr") as stderr:
            self.assertEqual(signing.main(), 1)
            self.assertNotIn("SECRET", "".join(str(c) for c in stderr.write.call_args_list))


class SignatureVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "OMG.app"
        (self.app / "Contents").mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": signing.RELEASE_ID}, stream)
        self.dr = signing.requirement(PIN)
        self.detail = "CodeDirectory v=20400 flags=0x0(none)\nTeamIdentifier=not set\n"
        self.commands = []
        self.patch_env = patch.dict(os.environ, ENV, clear=True)
        self.patch_env.start()
        self.addCleanup(self.patch_env.stop)

    def fake_run(self, *args, **kwargs):
        self.commands.append(args)
        out, err = b"", b""
        if args[:3] == ("codesign", "-d", "-r-"):
            err = ("designated => " + self.dr + "\n").encode()
        elif args[:2] == ("codesign", "-dv"):
            err = self.detail.encode()
        elif args[0] == "csreq":
            Path(args[4]).write_bytes(args[2].encode())
        return subprocess.CompletedProcess(args, 0, out, err)

    def test_accepts_pinned_identity_and_verifies_nested_signer(self):
        nested = signing.components(self.app)[1]
        nested.mkdir(parents=True)
        with patch.object(signing, "run", side_effect=self.fake_run):
            self.assertEqual(signing.verify(self.app), self.dr)
        leaf_checks = [c for c in self.commands if "-R" in c]
        self.assertEqual(len(leaf_checks), 2)
        self.assertTrue(all(f'H"{PIN}"' in c[c.index("-R") + 1] for c in leaf_checks))

    def test_rejects_weak_wrong_signer_and_cdhash_requirements(self):
        for dr in ['identifier "com.jischeng.omg"', signing.requirement(OTHER), 'cdhash H"' + PIN + '"']:
            self.dr = dr
            with self.subTest(dr=dr), patch.object(signing, "run", side_effect=self.fake_run), self.assertRaises(ValueError):
                signing.verify(self.app)

    def test_rejects_hardened_runtime_for_no_team_identity(self):
        self.detail = "CodeDirectory v=20400 flags=0x10000(runtime)\n"
        with patch.object(signing, "run", side_effect=self.fake_run), self.assertRaisesRegex(ValueError, "runtime"):
            signing.verify(self.app)

    def test_previous_persistent_release_requires_mutual_matching(self):
        with patch.object(signing, "run", side_effect=self.fake_run):
            signing.verify(self.app, self.app)
        checks = [c for c in self.commands if "-R" in c and c[c.index("-R") + 1] == "=" + self.dr]
        self.assertEqual(len(checks), 2)

    def test_provisioning_restores_keychain_search_list_on_failure(self):
        def fake(*args, **kwargs):
            if args[:3] == ("security", "list-keychains", "-d"):
                return subprocess.CompletedProcess(args, 0, b'"/existing/keychain"\n', b"")
            raise subprocess.CalledProcessError(1, args)
        with tempfile.TemporaryDirectory() as temp, patch.object(signing.sys, "platform", "darwin"), patch.object(signing, "run", side_effect=fake) as mocked:
            with self.assertRaises(subprocess.CalledProcessError):
                signing.create_identity(Path(temp) / "identity", "test-password")
            self.assertEqual(mocked.call_args_list[-1].args, ("security", "list-keychains", "-d", "user", "-s", "/existing/keychain"))
            self.assertFalse(any(Path(temp).rglob("password")))


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("OMG_RUN_SIGNING_SMOKE") == "1", "opt-in macOS static signing/launch smoke; no TCC desktop test")
class NativeSigningSmokeTests(unittest.TestCase):
    def test_same_certificate_survives_code_change_and_rejects_impostor(self):
        import secrets
        with tempfile.TemporaryDirectory(prefix="omg-signing-smoke-") as temp:
            temp = Path(temp)
            directories = [temp / "signer with spaces", temp / "impostor"]
            try:
                for directory in directories:
                    try:
                        signing.create_identity(directory, secrets.token_urlsafe(32))
                    except subprocess.CalledProcessError as error:
                        raise AssertionError(f"native provisioning failed (exit {error.returncode}); command omitted to protect credentials") from None
                configs = []
                for directory in directories:
                    lines = (directory / "signing.env").read_text().splitlines()
                    configs.append({line.split("=", 1)[0].removeprefix("export "): signing.shlex.split(line.split("=", 1)[1])[0] for line in lines})
                apps, drs = [], []
                for index, env in enumerate([configs[0], configs[0], configs[1]]):
                    app = temp / f"version-{index}/OMG.app"
                    (app / "Contents/MacOS").mkdir(parents=True)
                    source = temp / f"probe-{index}.c"
                    source.write_text(f'#include <stdio.h>\nint main(void) {{ puts("probe-{index}"); return 0; }}\n')
                    subprocess.run(["/usr/bin/clang", str(source), "-o", str(app / "Contents/MacOS/omg")], check=True, capture_output=True)
                    with (app / "Contents/Info.plist").open("wb") as stream:
                        plistlib.dump({"CFBundleIdentifier": signing.RELEASE_ID, "CFBundleExecutable": "omg", "CFBundlePackageType": "APPL", "CFBundleVersion": str(index + 1)}, stream)
                    result = subprocess.run(["/bin/bash", str(ROOT / "dist/macos/sign_omg_app.sh"), str(app)], env={**os.environ, **env}, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    with patch.dict(os.environ, env):
                        drs.append(signing.verify(app))
                    self.assertEqual(subprocess.check_output([str(app / "Contents/MacOS/omg")]).decode().strip(), f"probe-{index}")
                    apps.append(app)
                self.assertEqual(drs[0], drs[1])
                self.assertNotEqual(drs[0], drs[2])
                with patch.dict(os.environ, configs[0]):
                    signing.verify(apps[1], apps[0])
                    with self.assertRaises(subprocess.CalledProcessError):
                        signing.run("codesign", "--verify", "--strict", "-R", "=" + drs[0], str(apps[2]))
            finally:
                for directory in directories:
                    keychain = directory / "release.keychain-db"
                    if keychain.exists():
                        subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True, check=True)

    @unittest.skipUnless(os.environ.get("OMG_SIGNING_SMOKE_APP"), "no existing app supplied for artifact smoke")
    def test_existing_app_nested_signatures_and_version_launch(self):
        import secrets
        import shutil
        with tempfile.TemporaryDirectory(prefix="omg-artifact-smoke-") as temp:
            temp = Path(temp)
            identity_dir = temp / "identity"
            try:
                try:
                    signing.create_identity(identity_dir, secrets.token_urlsafe(32))
                except subprocess.CalledProcessError as error:
                    raise AssertionError(f"provisioning failed (exit {error.returncode}); credentials omitted") from None
                config = {
                    line.split("=", 1)[0].removeprefix("export "): signing.shlex.split(line.split("=", 1)[1])[0]
                    for line in (identity_dir / "signing.env").read_text().splitlines()
                }
                app = temp / "OMG.app"
                shutil.copytree(os.environ["OMG_SIGNING_SMOKE_APP"], app, symlinks=True)
                result = subprocess.run(["/bin/bash", str(ROOT / "dist/macos/sign_omg_app.sh"), str(app)], env={**os.environ, **config}, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                with patch.dict(os.environ, config):
                    signing.verify(app)
                output = subprocess.check_output([str(app / "Contents/MacOS/omg"), "--version"]).decode()
                self.assertIn(".ReleaseFast", output)
            finally:
                keychain = identity_dir / "release.keychain-db"
                if keychain.exists():
                    subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()
