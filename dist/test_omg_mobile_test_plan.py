"""Mobile selection contracts; these checks never launch Xcode, VM or Simulator."""
import unittest

from omg_mobile_test_plan import make_plan


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


if __name__ == "__main__":
    unittest.main()
