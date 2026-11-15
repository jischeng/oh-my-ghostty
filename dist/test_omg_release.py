"""Offline contract tests for dist/macos/omg_release.py, altstore_source.py, and iOS installer."""

from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("omg_release", ROOT / "dist/macos/omg_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

ALTSTORE_SPEC = importlib.util.spec_from_file_location("altstore_source", ROOT / "dist/macos/altstore_source.py")
altstore = importlib.util.module_from_spec(ALTSTORE_SPEC)
ALTSTORE_SPEC.loader.exec_module(altstore)


SAMPLE_PBXPROJ = """\
/* Begin XCBuildConfiguration section */
\t\tAA1 = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCURRENT_PROJECT_VERSION = 53;
\t\t\t\tMARKETING_VERSION = 0.20.3;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.jischeng.omg;
\t\t\t};
\t\t};
\t\tBB2 = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.jischeng.omg.DockTilePlugin;
\t\t\t};
\t\t};
\t\tCC3 = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCURRENT_PROJECT_VERSION = 53;
\t\t\t\tMARKETING_VERSION = 0.20.3;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.jischeng.omg.debug;
\t\t\t};
\t\t};
\t\tDD4 = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCURRENT_PROJECT_VERSION = 53;
\t\t\t\tMARKETING_VERSION = 0.20.3;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.jischeng.omg;
\t\t\t};
\t\t};
/* End XCBuildConfiguration section */
"""

SAMPLE_IOS_YML = """\
settings:
  base:
    OMG_MOBILE_BUNDLE_ID: com.jischeng.omg.mobile
    MARKETING_VERSION: "0.20.3"
    CURRENT_PROJECT_VERSION: "53"
"""

SAMPLE_VERSION_TEST = """\
struct OhMyGhosttyVersionTests {
    @Test func appBundlePublishesReleaseMetadata() {
        let versions = OhMyGhosttyVersion()

        #expect(versions.omg == "0.20.3")
        #expect(versions.ghostty == "1.3.2-dev")
    }

    @Test func appBundleUsesIndependentOMGIdentity() {
        let info = Bundle.main.infoDictionary ?? [:]

        #expect(info["CFBundleVersion"] as? String == "53")
    }

    @Test func readsIndependentOMGAndGhosttyVersions() {
        let versions = OhMyGhosttyVersion(infoDictionary: ["OMGVersion": "0.4.2"])

        #expect(versions.omg == "0.4.2")
    }
}
"""


class ReleaseOrchestratorTests(unittest.TestCase):
    def test_semver_policy_enforces_pre_1_0_and_ghostty_base_rules(self):
        base = ("1.3.2-dev", "abc123")
        updated = ("1.3.2-dev", "def456")

        release.validate_release_version("0.20.4", "v0.20.3", prev_ghostty=base, curr_ghostty=base)
        release.validate_release_version("0.21.0", "v0.20.3", prev_ghostty=base, curr_ghostty=updated)

        with self.assertRaisesRegex(ValueError, "requires minor version 0.21.0"):
            release.validate_release_version("0.20.4", "v0.20.3", prev_ghostty=base, curr_ghostty=updated)

        with self.assertRaisesRegex(ValueError, "explicit human product decision"):
            release.validate_release_version("1.0.0", "v0.20.3", prev_ghostty=base, curr_ghostty=base)

        release.validate_release_version(
            "1.0.0",
            "v0.20.3",
            prev_ghostty=base,
            curr_ghostty=base,
            allow_major_milestone=True,
        )

        with self.assertRaises(ValueError):
            release.validate_release_version("0.20.3", "v0.20.3", prev_ghostty=base, curr_ghostty=base)

        with self.assertRaises(ValueError):
            release.infer_next_version("0.20.3", "patch", ghostty_changed=True)
        self.assertEqual(release.infer_next_version("0.20.3", "patch", ghostty_changed=False), "0.20.4")
        self.assertEqual(release.infer_next_version("0.20.3", "minor", ghostty_changed=True), "0.21.0")

    def test_apply_version_bump_updates_three_targets_and_preserves_subtargets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pbx = root / release.PBXPROJ_REL
            ios = root / release.IOS_SPEC_REL
            ver_test = root / release.VERSION_TEST_REL
            for p in (pbx, ios, ver_test):
                p.parent.mkdir(parents=True, exist_ok=True)
            pbx.write_text(SAMPLE_PBXPROJ)
            ios.write_text(SAMPLE_IOS_YML)
            ver_test.write_text(SAMPLE_VERSION_TEST)

            self.assertEqual(release.read_current_pbxproj_versions(pbx.read_text()), ("0.20.3", 53))
            res = release.apply_version_bump(root, "0.20.4", 54)
            self.assertEqual(res["omg_version"], "0.20.4")
            self.assertEqual(res["bundle_version"], "54")
            self.assertEqual(release.read_current_pbxproj_versions(pbx.read_text()), ("0.20.4", 54))
            # DockTilePlugin remains untouched at 1.0 / 1
            self.assertIn("MARKETING_VERSION = 1.0;", pbx.read_text())
            self.assertIn("CURRENT_PROJECT_VERSION = 1;", pbx.read_text())
            self.assertIn('MARKETING_VERSION: "0.20.4"', ios.read_text())
            self.assertIn('CURRENT_PROJECT_VERSION: "54"', ios.read_text())
            self.assertIn('#expect(versions.omg == "0.20.4")', ver_test.read_text())
            self.assertIn('#expect(info["CFBundleVersion"] as? String == "54")', ver_test.read_text())
            # Fixed sample versions in other tests are not rewritten.
            self.assertIn('#expect(versions.omg == "0.4.2")', ver_test.read_text())

    def test_real_repository_pbxproj_parses_cleanly(self):
        ver, build = release.read_current_pbxproj_versions((ROOT / release.PBXPROJ_REL).read_text())
        self.assertRegex(ver, r"^\d+\.\d+\.\d+$")
        self.assertGreaterEqual(build, 53)
        latest = release.latest_published_tag(ROOT)
        self.assertRegex(latest, r"^v0\.\d+\.\d+$")

    def test_load_signing_env_parses_exports_without_overwriting_existing_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "signing.env"
            env_file.write_text(
                "# comment\n"
                "export OMG_SIGNING_MODE='self-signed'\n"
                "export OMG_SIGNING_IDENTITY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'\n"
                "export OMG_SIGNING_KEYCHAIN='/tmp/my release.keychain-db'\n"
            )
            env = {"OMG_SIGNING_MODE": "developer-id"}
            loaded = release.load_signing_env(env_file, env)
            self.assertEqual(loaded["OMG_SIGNING_MODE"], "developer-id")
            self.assertEqual(loaded["OMG_SIGNING_IDENTITY"], "A" * 40)
            self.assertEqual(loaded["OMG_SIGNING_KEYCHAIN"], "/tmp/my release.keychain-db")

    def test_parse_failed_swift_suites_handles_swift_testing_and_xctest(self):
        sample_log = """\
✔ Suite WorkspaceProviderTests passed after 0.394 seconds.
✘ Suite VerticalTabsIntegrationTests failed after 4.120 seconds with 1 issue.
Failing tests:
\tNativeHoverRoutingTests.stationaryPointerReconcilesHoverAfterClipViewScroll()
\t-[GhosttyTests.TerminalSplitTests testZoomRestore]

** TEST FAILED **
"""
        self.assertEqual(
            release.parse_failed_swift_suites(sample_log),
            [
                "GhosttyTests/NativeHoverRoutingTests",
                "GhosttyTests/TerminalSplitTests",
                "GhosttyTests/VerticalTabsIntegrationTests",
            ],
        )

    def test_clean_release_builds_preserves_artifacts_and_latest_universal_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rb = root / ".release-build"
            for ver in ("0.20.2", "0.20.3"):
                for sub in ("artifacts", "universal/Release/OMG.app", "arm64/Release/OMG.app", "obj-universal", "session-runtime"):
                    d = rb / ver / sub
                    d.mkdir(parents=True, exist_ok=True)
                    (d / "payload.bin").write_bytes(b"x" * 128)
                (rb / ver / "signing-requirement.txt").write_text("designated => ...\n")
            (rb / "test-old.log").write_text("log")

            dry = release.clean_release_builds(root, keep_latest=1, dry_run=True)
            self.assertGreater(dry["reclaimed_bytes"], 0)
            self.assertTrue((rb / "0.20.2/obj-universal").exists())

            done = release.clean_release_builds(root, keep_latest=1, dry_run=False)
            self.assertEqual(done["protected_versions"], ["0.20.3"])
            # Preserved in both versions: artifacts + signing-requirement.txt
            for ver in ("0.20.2", "0.20.3"):
                self.assertTrue((rb / ver / "artifacts/payload.bin").is_file())
                self.assertTrue((rb / ver / "signing-requirement.txt").is_file())
                self.assertFalse((rb / ver / "obj-universal").exists())
                self.assertFalse((rb / ver / "arm64").exists())
            # Latest release keeps universal/Release/OMG.app for OMG_PREVIOUS_SIGNED_APP
            self.assertTrue((rb / "0.20.3/universal/Release/OMG.app/payload.bin").is_file())
            # Older release universal app is reclaimed
            self.assertFalse((rb / "0.20.2/universal").exists())
            self.assertFalse((rb / "test-old.log").exists())

    def test_altstore_source_generation_prepending_and_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plist_path = root / "Info.plist"
            info = {
                "CFBundleIdentifier": "com.jischeng.omg.mobile",
                "CFBundleDisplayName": "OMG Mobile",
                "CFBundleShortVersionString": "0.21.0",
                "CFBundleVersion": "55",
                "MinimumOSVersion": "17.0",
                "NSCameraUsageDescription": "Scan pairing QR codes.",
                "NSLocalNetworkUsageDescription": "Connect to your Mac on LAN.",
            }
            plist_path.write_bytes(plistlib.dumps(info))
            ipa = root / "OMG-Mobile-0.21.0-ios-unsigned.ipa"
            ipa_bytes = b"PK\x03\x04fake-ipa-payload" * 10
            ipa.write_bytes(ipa_bytes)

            prev_source = {
                "apps": [{
                    "versions": [{
                        "version": "0.20.9",
                        "buildVersion": "54",
                        "date": "2026-10-01T00:00:00Z",
                        "downloadURL": "https://github.com/jischeng/oh-my-ghostty/releases/download/v0.20.9/OMG-Mobile-0.20.9-ios-unsigned.ipa",
                        "size": 100,
                        "sha256": "0" * 64,
                        "minOSVersion": "17.0",
                    }]
                }]
            }
            built = altstore.build_altstore_source(
                altstore.read_app_info_plist(plist_path),
                ipa,
                "v0.21.0",
                info_plist_path=plist_path,
                release_date="2026-11-15T12:00:00Z",
                previous_source=prev_source,
            )
            altstore.validate_altstore_source(
                built,
                expected_version="0.21.0",
                expected_ipa=ipa,
                expected_release_tag="v0.21.0",
            )
            app = built["apps"][0]
            self.assertEqual(app["bundleIdentifier"], "com.jischeng.omg.mobile")
            self.assertEqual(
                app["appPermissions"]["privacy"],
                {
                    "NSCameraUsageDescription": "Scan pairing QR codes.",
                    "NSLocalNetworkUsageDescription": "Connect to your Mac on LAN.",
                },
            )
            self.assertEqual(len(app["versions"]), 2)
            self.assertEqual(app["versions"][0]["size"], len(ipa_bytes))
            self.assertEqual(app["versions"][0]["sha256"], hashlib.sha256(ipa_bytes).hexdigest())
            self.assertEqual(app["versions"][1]["version"], "0.20.9")

            # Tampered size must fail validation
            built["apps"][0]["versions"][0]["size"] = 1
            with self.assertRaises(ValueError):
                altstore.validate_altstore_source(built, expected_version="0.21.0", expected_ipa=ipa)

    def test_verify_packaged_artifacts_validates_altstore_source_and_checksums(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ver = "0.21.0"
            build_root = root / ".release-build" / ver
            artifacts = build_root / "artifacts"
            rt_dir = build_root / "universal/Release/OMG.app/Contents/Resources/session-runtime"
            artifacts.mkdir(parents=True)
            rt_dir.mkdir(parents=True)
            (rt_dir / "revision").write_text("rev1\n")
            (rt_dir / "snapshot-revision").write_text("snap1\n")
            (build_root / "signing-requirement.txt").write_text("designated => identifier \"com.jischeng.omg\"\n")

            ipa_path = artifacts / f"OMG-Mobile-{ver}-ios-unsigned.ipa"
            for fname in (
                f"OMG-{ver}-macos-arm64.dmg",
                f"OMG-{ver}-macos-x86_64.dmg",
                f"OMG-{ver}-macos-universal.dmg",
                f"OMG-Mobile-{ver}-ios-installer.tar.gz",
                ipa_path.name,
            ):
                (artifacts / fname).write_bytes(fname.encode("utf-8") * 4)

            info = {
                "CFBundleIdentifier": "com.jischeng.omg.mobile",
                "CFBundleShortVersionString": ver,
                "CFBundleVersion": "55",
                "MinimumOSVersion": "17.0",
                "NSLocalNetworkUsageDescription": "LAN access.",
            }
            src = altstore.build_altstore_source(info, ipa_path, f"v{ver}")
            (artifacts / "altstore-source.json").write_text(json.dumps(src))

            (artifacts / "appcast.xml").write_text(
                '<?xml version="1.0" encoding="utf-8"?>'
                '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                f"<channel><item><sparkle:shortVersionString>{ver}</sparkle:shortVersionString>"
                "<sparkle:version>55</sparkle:version></item></channel></rss>"
            )

            sums = []
            for fname in (
                f"OMG-{ver}-macos-arm64.dmg",
                f"OMG-{ver}-macos-x86_64.dmg",
                f"OMG-{ver}-macos-universal.dmg",
                f"OMG-Mobile-{ver}-ios-installer.tar.gz",
                ipa_path.name,
                "altstore-source.json",
            ):
                digest = hashlib.sha256((artifacts / fname).read_bytes()).hexdigest()
                sums.append(f"{digest}  {fname}")
            (artifacts / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n")

            info_out = release.verify_packaged_artifacts(root, ver)
            self.assertIn("altstore-source.json", info_out["files"])

    def test_install_script_dry_run_supports_modern_properties_and_preserves_bundle_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            fake_home = td / "home"
            fake_bin = td / "bin"
            prof_dir = fake_home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
            fake_bin.mkdir(parents=True)
            prof_dir.mkdir(parents=True)

            cert_der = b"dummy-cert-der-bytes"
            cert_sha1 = hashlib.sha1(cert_der).hexdigest().upper()
            udid = "00008120-000631D42E44201E"
            prof_uuid = "11111111-2222-3333-4444-555555555555"
            prof_plist = plistlib.dumps({
                "UUID": prof_uuid,
                "TeamIdentifier": ["5K863NP6ZU"],
                "ExpirationDate": (datetime.now(timezone.utc) + timedelta(days=5)).replace(tzinfo=None),
                "ProvisionedDevices": [udid],
                "DeveloperCertificates": [cert_der],
                "Entitlements": {"application-identifier": "5K863NP6ZU.com.jischeng.omg.mobile"},
            })
            prof_path = prof_dir / f"{prof_uuid}.mobileprovision"
            prof_path.write_bytes(prof_plist)

            def write_shim(name: str, body: str) -> None:
                p = fake_bin / name
                p.write_text("#!/bin/bash\n" + body)
                p.chmod(p.stat().st_mode | stat.S_IEXEC)

            # Modern devicectl schema using device.properties.hardware / state / connection,
            # mixed with an iOS Simulator (reality=simulated, transportType=sameMachine)
            # and an unpaired physical iPhone — auto-selection must pick the single paired physical iPhone.
            write_shim("xcrun", f"""
if [[ "$1" == "devicectl" && "$2" == "list" ]]; then
  out=""
  while [[ $# -gt 0 ]]; do [[ "$1" == "--json-output" ]] && out="$2"; shift; done
  cat > "$out" <<'JSON'
{{
  "result": {{
    "devices": [
      {{
        "identifier": "315B3717-14B5-4D3D-9BD6-9C91A5CB31D0",
        "name": "iPhone 18 Pro",
        "properties": {{
          "hardware": {{"udid": "315B3717-14B5-4D3D-9BD6-9C91A5CB31D0", "platform": "iOS", "deviceType": "iPhone", "reality": "simulated"}},
          "state": {{"name": "connected"}},
          "connection": {{"transportType": "sameMachine", "pairingState": "paired"}}
        }}
      }},
      {{
        "identifier": "UNPAIRED-PHYSICAL-1",
        "name": "UnpairedPhone",
        "hardwareProperties": {{"udid": "UNPAIRED-UDID-1", "platform": "iOS", "deviceType": "iPhone", "reality": "physical"}},
        "connectionProperties": {{"transportType": "localNetwork", "pairingState": "unpaired"}}
      }},
      {{
        "identifier": "5F72D461-0173-5907-85D9-60ED4D6179C3",
        "name": "TestPhone",
        "properties": {{
          "hardware": {{"udid": "{udid}", "platform": "iOS", "deviceType": "iPhone", "reality": "physical"}},
          "state": {{"name": "available (paired)"}},
          "connection": {{"transportType": "localNetwork", "pairingState": "paired"}}
        }}
      }}
    ]
  }}
}}
JSON
  exit 0
fi
if [[ "$1" == "devicectl" && "$2" == "device" && "$3" == "info" && "$4" == "apps" ]]; then
  out=""
  while [[ $# -gt 0 ]]; do [[ "$1" == "--json-output" ]] && out="$2"; shift; done
  cat > "$out" <<'JSON'
{{"result": {{"apps": [{{"properties": {{"bundleIdentifier": "com.jischeng.omg.mobile.custom"}}}}]}}}}
JSON
  exit 0
fi
exit 1
""")
            write_shim("security", f"""
if [[ "$1" == "find-identity" ]]; then
  echo '  1) {cert_sha1} "Apple Development: test@example.com (TEST1234)"'
  exit 0
fi
if [[ "$1" == "find-certificate" ]]; then
  echo 'SHA-1 hash: {cert_sha1}'
  echo '-----BEGIN CERTIFICATE-----'
  echo 'AAAA'
  echo '-----END CERTIFICATE-----'
  exit 0
fi
if [[ "$1" == "cms" ]]; then
  cat "$4"
  exit 0
fi
exit 0
""")
            write_shim("openssl", 'echo "subject=OU = 5K863NP6ZU"')
            write_shim("defaults", 'exit 1')

            env = os.environ.copy()
            env["HOME"] = str(fake_home)
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            res = subprocess.run(
                ["bash", str(ROOT / "ios/scripts/install-to-iphone.sh"), "--dry-run"],
                env=env, capture_output=True, text=True, check=True,
            )
            plan = json.loads(res.stdout)
            self.assertEqual(plan["device_udid"], udid)
            self.assertEqual(plan["transport"], "localNetwork")
            self.assertEqual(plan["team_id"], "5K863NP6ZU")
            # Installed app bundle ID must win to preserve pairings
            self.assertEqual(plan["bundle_id"], "com.jischeng.omg.mobile.custom")
            self.assertEqual(plan["installed_bundle_id"], "com.jischeng.omg.mobile.custom")
            self.assertEqual(plan["cached_profile_uuid"], "")

            # Now test when installed app matches cached profile bundle ID
            write_shim("xcrun", f"""
if [[ "$1" == "devicectl" && "$2" == "list" ]]; then
  out=""
  while [[ $# -gt 0 ]]; do [[ "$1" == "--json-output" ]] && out="$2"; shift; done
  cat > "$out" <<'JSON'
{{"result": {{"devices": [{{"identifier": "DEV1", "hardwareProperties": {{"udid": "{udid}", "platform": "iOS", "deviceType": "iPhone"}}, "deviceProperties": {{"name": "LegacyPhone"}}, "connectionProperties": {{"transportType": "wired"}}}}]}}}}
JSON
  exit 0
fi
exit 1
""")
            res2 = subprocess.run(
                ["bash", str(ROOT / "ios/scripts/install-to-iphone.sh"), "--dry-run"],
                env=env, capture_output=True, text=True, check=True,
            )
            plan2 = json.loads(res2.stdout)
            self.assertEqual(plan2["device_name"], "LegacyPhone")
            self.assertEqual(plan2["transport"], "wired")
            self.assertEqual(plan2["bundle_id"], "com.jischeng.omg.mobile")
            self.assertEqual(plan2["cached_profile_uuid"], prof_uuid)


if __name__ == "__main__":
    unittest.main()
