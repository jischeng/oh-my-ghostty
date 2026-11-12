"""Mobile selection contracts; these checks never launch Xcode, VM or Simulator."""
from pathlib import Path
import tempfile
import unittest

from omg_mobile_test_plan import IOS_VERSION_SPEC, ios_version_only_change, make_plan
from omg_test_plan import git


class MobileTestPlanTests(unittest.TestCase):
    def test_unrelated_macos_features_and_releases_do_not_select_mobile(self):
        self.assertFalse(make_plan([
            "macos/Sources/Features/Git/GitHistoryService.swift",
            "macos/Ghostty.xcodeproj/project.pbxproj",
            "docs/RELEASE_NOTES_0.20.0.md",
            "dist/appcast.xml",
        ])["run_mobile"])

    def test_documentation_and_selector_only_changes_do_not_select_mobile(self):
        self.assertFalse(make_plan([
            "ios/README.md", "ios/.gitignore", "docs/TESTING.md",
            "dist/omg_mobile_test_plan.py", "dist/test_omg_mobile_test_plan.py",
        ])["run_mobile"])

    def test_mobile_files_and_shared_dependencies_select_integration(self):
        for path in [
            "ios/Sources/App.swift", "ios/Core/RuntimeFrame.swift",
            "ios/Vendor/Termio/StreamTerminalView.swift", "ios/project.yml",
            "ios/scripts/vm-fixture.py", "src/omg/session/SessionBackend.zig",
            "session-runtime/src/host.rs", "session-runtime/src/registry.rs",
            "session-runtime/src/mobile/control.rs",
            "session-runtime/src/activity.rs",
            "src/terminal/stream.zig", "include/ghostty/vt/terminal.h",
            "src/lib_vt.zig", "src/build/GhosttyLibVt.zig",
            "dist/macos/build-session-runtime.py",
            "dist/macos/build-mobile-support.py",
            "session-runtime/mobile-support/Support.swift",
        ]:
            with self.subTest(path=path):
                result = make_plan([path])
                self.assertTrue(result["run_mobile"])
                self.assertIn("vm-simulator-ui", result["checks"])
                self.assertEqual(result["relevant_paths"], [path])

    def test_unknown_mobile_code_is_not_silently_skipped(self):
        self.assertTrue(make_plan(["ios/NewFeature/new-file.swift"])["run_mobile"])

    def test_no_changes_and_unrelated_runtime_features_skip_mobile(self):
        self.assertFalse(make_plan([])["run_mobile"])
        self.assertFalse(make_plan(["session-runtime/src/remote_draft.rs"])["run_mobile"])

    def test_ios_project_version_bump_only_does_not_select_mobile(self):
        self.assertFalse(make_plan([IOS_VERSION_SPEC], ios_version_only=True)["run_mobile"])
        self.assertTrue(make_plan([IOS_VERSION_SPEC], ios_version_only=False)["run_mobile"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            git(root, "config", "user.email", "test@example.invalid")
            git(root, "config", "user.name", "Fixture")
            spec = root / IOS_VERSION_SPEC
            spec.parent.mkdir(parents=True)
            spec.write_text('settings:\n  base:\n    MARKETING_VERSION: "0.20.3"\n    CURRENT_PROJECT_VERSION: "53"\n')
            git(root, "add", ".")
            git(root, "commit", "-qm", "base")
            base_commit = git(root, "rev-parse", "HEAD").strip()
            spec.write_text('settings:\n  base:\n    MARKETING_VERSION: "0.20.4"\n    CURRENT_PROJECT_VERSION: "54"\n')
            self.assertTrue(ios_version_only_change(root, base_commit))
            spec.write_text('settings:\n  base:\n    MARKETING_VERSION: "0.20.4"\n    CURRENT_PROJECT_VERSION: "54"\n    SWIFT_VERSION: "6.0"\n')
            self.assertFalse(ios_version_only_change(root, base_commit))


if __name__ == "__main__":
    unittest.main()
