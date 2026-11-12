"""Offline contract tests for dist/macos/omg_release.py."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("omg_release", ROOT / "dist/macos/omg_release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


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


if __name__ == "__main__":
    unittest.main()
