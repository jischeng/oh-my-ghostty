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
        self.target_ids = {}
        self.dr_overrides = {}
        self.detail_overrides = {}
        self.commands = []
        self.patch_env = patch.dict(os.environ, ENV, clear=True)
        self.patch_env.start()
        self.addCleanup(self.patch_env.stop)

    def fake_run(self, *args, **kwargs):
        self.commands.append(args)
        out, err = b"", b""
        if args[:3] == ("codesign", "-d", "-r-"):
            target = args[3]
            if target in self.dr_overrides:
                dr = self.dr_overrides[target]
            elif target == str(self.app):
                dr = self.dr
            else:
                dr = signing.requirement(PIN, self.target_ids.get(target, signing.RELEASE_ID))
            err = ("designated => " + dr + "\n").encode()
        elif args[:2] == ("codesign", "-dv"):
            target = args[-1]
            detail = self.detail_overrides.get(target, self.detail)
            if "Identifier=" not in detail and target in self.target_ids:
                detail = f"Identifier={self.target_ids[target]}\n{detail}"
            err = detail.encode()
        elif args[0] == "csreq":
            Path(args[4]).write_bytes(args[2].encode())
        return subprocess.CompletedProcess(args, 0, out, err)

    def test_accepts_pinned_identity_and_verifies_nested_signer(self):
        downloader = signing.components(self.app)[1]
        downloader.mkdir(parents=True)
        autoupdate = signing.components(self.app)[3]
        autoupdate.parent.mkdir(parents=True, exist_ok=True)
        autoupdate.write_bytes(b"macho")
        runtime = self.app / "Contents/Resources/session-runtime"
        (runtime / "macos-aarch64").mkdir(parents=True)
        omgd = runtime / "omgd"
        mobile = runtime / "omg-mobile-support"
        libvt = runtime / "libghostty-vt.0.1.0.dylib"
        arch_omgd = runtime / "macos-aarch64/omgd"
        for item in (omgd, mobile, libvt, arch_omgd):
            item.write_bytes(b"macho")
        askpass = runtime / "askpass"
        askpass.write_text("#!/bin/sh\n")
        askpass.chmod(0o755)
        (self.app / "Contents/_CodeSignature").mkdir(parents=True, exist_ok=True)
        with (self.app / "Contents/_CodeSignature/CodeResources").open("wb") as stream:
            plistlib.dump({"files2": {"Resources/session-runtime/askpass": {}}}, stream)
        self.target_ids = {
            str(downloader): "org.sparkle-project.DownloaderService",
            str(autoupdate): "com.jischeng.omg.sparkle.autoupdate",
            str(omgd): "com.jischeng.omg.omgd",
            str(mobile): "com.jischeng.omg.mobile-support",
            str(libvt): "com.jischeng.omg.libghostty-vt",
            str(arch_omgd): "com.jischeng.omg.omgd",
        }
        with patch.object(signing, "run", side_effect=self.fake_run):
            self.assertEqual(signing.verify(self.app), self.dr)
        leaf_checks = [c for c in self.commands if "-R" in c]
        self.assertEqual(len(leaf_checks), 7)
        self.assertTrue(all(f'H"{PIN}"' in c[c.index("-R") + 1] for c in leaf_checks))

    def test_rejects_wrong_nested_identifier_or_nested_cdhash(self):
        omgd = self.app / "Contents/Resources/session-runtime/omgd"
        omgd.parent.mkdir(parents=True)
        omgd.write_bytes(b"macho")
        self.dr_overrides[str(omgd)] = signing.requirement(PIN, "omgd")
        self.detail_overrides[str(omgd)] = "Identifier=omgd\n" + self.detail
        with patch.object(signing, "run", side_effect=self.fake_run), self.assertRaisesRegex(ValueError, "identifier"):
            signing.verify(self.app)
        self.detail_overrides.clear()
        self.dr_overrides[str(omgd)] = f'cdhash H"{PIN}"'
        with patch.object(signing, "run", side_effect=self.fake_run), self.assertRaisesRegex(ValueError, "code-hash-bound"):
            signing.verify(self.app)

    def test_rejects_symlink_nonexec_or_unsealed_askpass(self):
        runtime = self.app / "Contents/Resources/session-runtime"
        runtime.mkdir(parents=True)
        askpass = runtime / "askpass"
        askpass.symlink_to("/bin/echo")
        with patch.object(signing, "run", side_effect=self.fake_run), self.assertRaisesRegex(ValueError, "symlink"):
            signing.verify(self.app)
        askpass.unlink()
        askpass.write_text("#!/bin/sh\n")
        askpass.chmod(0o644)
        with patch.object(signing, "run", side_effect=self.fake_run), self.assertRaisesRegex(ValueError, "executable"):
            signing.verify(self.app)
        askpass.chmod(0o755)
        (self.app / "Contents/_CodeSignature").mkdir(parents=True, exist_ok=True)
        with (self.app / "Contents/_CodeSignature/CodeResources").open("wb") as stream:
            plistlib.dump({"files2": {}}, stream)
        with patch.object(signing, "run", side_effect=self.fake_run), self.assertRaisesRegex(ValueError, "CodeResources"):
            signing.verify(self.app)

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


class TrustStatusAndInstallTests(unittest.TestCase):
    def setUp(self):
        self.meta = {
            "common_name": "OMG Release Signing",
            "subject": "CN = OMG Release Signing",
            "issuer": "CN = OMG Release Signing",
            "sha1": PIN,
            "self_signed": True,
            "has_code_signing_eku": True,
            "is_ca": False,
        }
        self.trust = {
            "self_signed": True,
            "trusted_in_admin_domain": True,
            "trusted_in_user_domain": False,
            "is_code_signing_trusted": True,
            "is_non_code_signing_blocked": True,
            "has_unscoped_trust": False,
        }

    def _inspector(self):
        class Inspector:
            def __init__(self, payload):
                self.payload = payload

            def inspect(self, der_bytes):
                return dict(self.payload)

        return Inspector(self.trust)

    def test_trust_status_modes(self):
        with patch.object(signing, "_resolve_cert_der", return_value=b"DER"), patch.object(
            signing, "_parse_x509_metadata", return_value=self.meta
        ):
            healthy = signing.trust_status(app=Path("/Applications/OMG.app"), inspector=self._inspector())
            self.assertEqual(healthy["mode"], "self_signed_admin_trusted")
            self.assertTrue(healthy["healthy"])

            self.trust.update({"trusted_in_admin_domain": False, "trusted_in_user_domain": True})
            user_only = signing.trust_status(cert=Path("cert.pem"), inspector=self._inspector())
            self.assertEqual(user_only["mode"], "self_signed_user_only_trusted")
            self.assertFalse(user_only["healthy"])

            self.trust.update({"trusted_in_user_domain": False, "is_code_signing_trusted": False})
            untrusted = signing.trust_status(cert=Path("cert.pem"), inspector=self._inspector())
            self.assertEqual(untrusted["mode"], "self_signed_untrusted")
            self.assertFalse(untrusted["healthy"])

            self.trust.update(
                {
                    "trusted_in_admin_domain": True,
                    "is_code_signing_trusted": True,
                    "is_non_code_signing_blocked": False,
                    "has_unscoped_trust": True,
                }
            )
            unscoped = signing.trust_status(cert=Path("cert.pem"), inspector=self._inspector())
            self.assertFalse(unscoped["healthy"])

            self.trust["self_signed"] = False
            non_ss = signing.trust_status(cert=Path("cert.pem"), inspector=self._inspector())
            self.assertEqual(non_ss["mode"], "non_self_signed")
            self.assertFalse(non_ss["healthy"])

    def test_install_trust_rejects_non_self_signed_or_missing_codesign_eku(self):
        with patch.object(signing.sys, "platform", "darwin"), patch.object(
            signing, "_resolve_cert_der", return_value=b"DER"
        ):
            bad_ss = {**self.meta, "self_signed": False}
            with patch.object(signing, "_parse_x509_metadata", return_value=bad_ss), self.assertRaisesRegex(
                ValueError, "non-self-signed"
            ):
                signing.install_trust(cert=Path("cert.pem"), inspector=self._inspector())

            bad_eku = {**self.meta, "has_code_signing_eku": False}
            with patch.object(signing, "_parse_x509_metadata", return_value=bad_eku), self.assertRaisesRegex(
                ValueError, "Code Signing"
            ):
                signing.install_trust(cert=Path("cert.pem"), inspector=self._inspector())

    def test_install_trust_uses_admin_trust_root_code_sign_and_verifies(self):
        recorded = {}

        def fake_run(*args, **kwargs):
            recorded["cmd"] = args
            recorded["der_mode"] = os.stat(args[-1]).st_mode & 0o777
            recorded["der_bytes"] = Path(args[-1]).read_bytes()
            return subprocess.CompletedProcess(args, 0, b"", b"")

        with patch.object(signing.sys, "platform", "darwin"), patch.object(
            signing, "_resolve_cert_der", return_value=b"DERBYTES"
        ), patch.object(signing, "_parse_x509_metadata", return_value=self.meta), patch.object(
            signing.os, "geteuid", return_value=501
        ), patch.object(
            signing, "run", side_effect=fake_run
        ):
            result = signing.install_trust(cert=Path("cert.pem"), inspector=self._inspector())
        self.assertTrue(result["healthy"])
        cmd = recorded["cmd"]
        self.assertEqual(cmd[0], "sudo")
        self.assertIn("-d", cmd)
        self.assertEqual(cmd[cmd.index("-r") + 1], "trustRoot")
        self.assertEqual(cmd[cmd.index("-p") + 1], "codeSign")
        self.assertEqual(cmd[cmd.index("-k") + 1], str(signing.ADMIN_SYSTEM_KEYCHAIN))
        self.assertEqual(recorded["der_mode"], 0o600)
        self.assertEqual(recorded["der_bytes"], b"DERBYTES")

    def test_install_trust_user_opt_in_and_post_verify_failure(self):
        recorded = {}

        def fake_run(*args, **kwargs):
            recorded["cmd"] = args
            return subprocess.CompletedProcess(args, 0, b"", b"")

        self.trust.update({"trusted_in_admin_domain": False, "trusted_in_user_domain": True})
        with patch.object(signing.sys, "platform", "darwin"), patch.object(
            signing, "_resolve_cert_der", return_value=b"DER"
        ), patch.object(signing, "_parse_x509_metadata", return_value=self.meta), patch.object(
            signing, "run", side_effect=fake_run
        ), patch("sys.stderr") as stderr:
            result = signing.install_trust(cert=Path("cert.pem"), user_only=True, inspector=self._inspector())
        self.assertEqual(result["mode"], "self_signed_user_only_trusted")
        self.assertNotIn("-d", recorded["cmd"])
        self.assertNotIn("sudo", recorded["cmd"])
        self.assertIn("Accessibility", "".join(str(c) for c in stderr.write.call_args_list))

        self.trust["is_non_code_signing_blocked"] = False
        with patch.object(signing.sys, "platform", "darwin"), patch.object(
            signing, "_resolve_cert_der", return_value=b"DER"
        ), patch.object(signing, "_parse_x509_metadata", return_value=self.meta), patch.object(
            signing, "run", side_effect=fake_run
        ), self.assertRaisesRegex(
            ValueError, "post-install verification failed"
        ):
            signing.install_trust(cert=Path("cert.pem"), inspector=self._inspector())

    def test_cli_trust_status_exit_codes_and_json(self):
        import io
        import json

        unhealthy = {
            "certificate_cn": "OMG Release Signing",
            "certificate_sha1": PIN,
            "self_signed": True,
            "is_ca": False,
            "has_code_signing_eku": True,
            "trusted_in_admin_domain": False,
            "trusted_in_user_domain": False,
            "is_code_signing_trusted": False,
            "is_non_code_signing_blocked": True,
            "has_unscoped_trust": False,
            "mode": "self_signed_untrusted",
            "healthy": False,
        }
        stdout = io.StringIO()
        with patch.object(sys, "argv", ["omg_signing.py", "trust-status", "--json"]), patch.object(
            signing, "trust_status", return_value=unhealthy
        ), patch("sys.stdout", stdout):
            self.assertEqual(signing.main(), 1)
        self.assertEqual(json.loads(stdout.getvalue())["mode"], "self_signed_untrusted")

        healthy = {**unhealthy, "trusted_in_admin_domain": True, "is_code_signing_trusted": True, "mode": "self_signed_admin_trusted", "healthy": True}
        with patch.object(sys, "argv", ["omg_signing.py", "trust-status"]), patch.object(
            signing, "trust_status", return_value=healthy
        ), patch("sys.stdout", io.StringIO()):
            self.assertEqual(signing.main(), 0)


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("OMG_RUN_SIGNING_SMOKE") == "1", "opt-in macOS static signing/launch smoke; no TCC desktop test")
class NativeSigningSmokeTests(unittest.TestCase):
    def test_same_certificate_survives_code_change_and_rejects_impostor(self):
        import json
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
                    dylib_src = temp / f"lib-{index}.c"
                    dylib_src.write_text(f"int omg_vt_probe_{index}(void) {{ return {index}; }}\n")
                    runtime = app / "Contents/Resources/session-runtime"
                    (runtime / "macos-aarch64").mkdir(parents=True)
                    for exe in (runtime / "omgd", runtime / "omg-mobile-support", runtime / "macos-aarch64/omgd"):
                        subprocess.run(["/usr/bin/clang", str(source), "-o", str(exe)], check=True, capture_output=True)
                    libvt = runtime / "libghostty-vt.0.1.0.dylib"
                    subprocess.run(["/usr/bin/clang", "-dynamiclib", str(dylib_src), "-o", str(libvt)], check=True, capture_output=True)
                    askpass = runtime / "askpass"
                    askpass.write_text("#!/bin/sh\nexit 0\n")
                    askpass.chmod(0o755)
                    manifest = runtime / "macos-aarch64/manifest.json"
                    manifest.write_text(json.dumps({"files": [{"name": "omgd", "sha256": "stale"}]}) + "\n")
                    sparkle_ver = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
                    (sparkle_ver / "Resources").mkdir(parents=True)
                    subprocess.run(["/usr/bin/clang", "-dynamiclib", str(dylib_src), "-o", str(sparkle_ver / "Sparkle")], check=True, capture_output=True)
                    subprocess.run(["/usr/bin/clang", str(source), "-o", str(sparkle_ver / "Autoupdate")], check=True, capture_output=True)
                    with (sparkle_ver / "Resources/Info.plist").open("wb") as stream:
                        plistlib.dump({"CFBundleIdentifier": "org.sparkle-project.Sparkle", "CFBundleExecutable": "Sparkle", "CFBundlePackageType": "FMWK", "CFBundleVersion": "2.0", "CFBundleShortVersionString": "2.0"}, stream)
                    (sparkle_ver.parent / "Current").symlink_to("B")
                    (sparkle_ver.parents[1] / "Resources").symlink_to("Versions/Current/Resources")
                    (sparkle_ver.parents[1] / "Sparkle").symlink_to("Versions/Current/Sparkle")
                    with (app / "Contents/Info.plist").open("wb") as stream:
                        plistlib.dump({"CFBundleIdentifier": signing.RELEASE_ID, "CFBundleExecutable": "omg", "CFBundlePackageType": "APPL", "CFBundleVersion": str(index + 1)}, stream)
                    result = subprocess.run(["/bin/bash", str(ROOT / "dist/macos/sign_omg_app.sh"), str(app)], env={**os.environ, **env}, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    with patch.dict(os.environ, env):
                        drs.append(signing.verify(app))
                    updated_manifest = json.loads(manifest.read_text())
                    self.assertNotEqual(updated_manifest["files"][0]["sha256"], "stale")
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
                self.assertRegex(output, r"build mode\s*:\s*\.(?:fast|ReleaseFast)")
            finally:
                keychain = identity_dir / "release.keychain-db"
                if keychain.exists():
                    subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()
