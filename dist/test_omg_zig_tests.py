"""Zig test selection contracts; these checks never invoke zig."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import omg_zig_tests as zig

ROOT = Path(__file__).resolve().parent.parent

PASSING = """\
Build Summary: 118/118 steps succeeded; 87/87 tests passed
test success
+- run test ghostty-test 6 pass (6 total) 1s MaxRSS:31M
"""
BASELINE = """\
Build Summary: 118/118 steps succeeded; 79/79 tests passed
test success
"""
CRASHING = """\
test
+- run test ghostty-test 79 pass, 1 crash (80 total)
+- run test ghostty-test stderr
[stream] (warn): invalid set mode command: ESC [   { 6 } h
error: 'terminal.Terminal.test.Terminal: grapheme transfer' terminated with signal ABRT with stderr:
       [kitty_gfx] (warn): erroneous kitty graphics response: EINVAL: invalid data
       [page] (err): page integrity violation, crashing. err=error.InvalidWideLocation
       thread 5997325 panic: page integrity violation
failed command: ./.zig-cache/o/eab5/ghostty-test --listen=-
error: 'terminal.page.test.Page clone' failed:
       expected 12, found 6
Build Summary: 104/106 steps succeeded (1 failed); 79/81 tests passed (1 crashed, 1 failed)
test transitive failure
+- run test ghostty-test 79 pass, 1 crash (80 total)
"""


class ZigTestSelectionTests(unittest.TestCase):
    def test_filter_is_the_dotted_path_below_src_and_ends_with_a_dot(self):
        self.assertEqual(zig.filter_for("src/terminal/Terminal.zig"), "terminal.Terminal.")
        self.assertEqual(zig.filter_for("src/cli/ssh.zig"), "cli.ssh.")
        self.assertEqual(zig.filter_for("src/terminal/kitty/graphics_exec.zig"), "terminal.kitty.graphics_exec.")
        self.assertEqual(zig.filter_for("src/Surface.zig"), "Surface.")
        for path in ["pkg/macos/main.zig", "build.zig", "src/terminal/res/README.md", "macos/Sources/App.swift"]:
            self.assertIsNone(zig.filter_for(path), path)

    def test_plan_keeps_existing_zig_files_that_declare_named_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src/terminal").mkdir(parents=True)
            (root / "src/terminal/Terminal.zig").write_text(
                'const std = @import("std");\n'
                'test "one" {}\n'
                "pub const Inner = struct {\n"
                '    test "nested" {}\n'
                "};\n"
                "test decl {}\n"
                "test {\n    _ = Inner;\n}\n"
                '// test "in a comment" is not at the start of a line\n'
            )
            (root / "src/terminal/plain.zig").write_text("pub const x = 1;\n")
            plan = zig.make_plan(root, [
                "src/terminal/Terminal.zig",
                "src/terminal/plain.zig",
                "src/terminal/deleted.zig",
                "docs/TESTING.md",
            ])
        self.assertTrue(plan["run_zig"])
        self.assertEqual(plan["filters"], ["terminal.Terminal."])
        # The unnamed block is not counted: it runs under every filter.
        self.assertEqual(plan["declared"], 3)
        self.assertEqual(plan["files_without_tests"], ["src/terminal/plain.zig"])

        self.assertFalse(zig.make_plan(ROOT, ["docs/TESTING.md", "macos/build.nu"])["run_zig"])

    def test_command_takes_the_toolchain_and_version_from_build_zig_zon(self):
        command = zig.zig_command(ROOT, ["cli.ssh.", "terminal.Terminal."])
        zon = (ROOT / "build.zig.zon").read_text()
        toolchain = command[2]
        self.assertEqual(command[:2], ["mise", "exec"])
        self.assertTrue(toolchain.startswith("zig@"))
        self.assertIn(f'.minimum_zig_version = "{toolchain[len("zig@"):]}"', zon)
        # Without both, an unfiltered run rebuilds GhosttyKit in Debug and
        # starts the app's XCTest on the host desktop.
        self.assertIn("-Demit-macos-app=false", command)
        self.assertIn("-Demit-xcframework=false", command)
        version = next(arg for arg in command if arg.startswith("-Dversion-string="))
        self.assertIn(f'.version = "{version.split("=", 1)[1]}"', zon)
        self.assertEqual(command[-2:], ["-Dtest-filter=cli.ssh.", "-Dtest-filter=terminal.Terminal."])
        # The count comes from the Build Summary line, which needs this flag.
        self.assertIn("--summary", command)
        self.assertEqual(zig.zig_command(ROOT, [])[-2:], ["--summary", "all"])

    def test_every_run_is_a_different_build_so_zig_cannot_reuse_a_result(self):
        # A reused result prints no counts: "passed" and "selected nothing"
        # would look the same on the second run.
        plain = next(arg for arg in zig.zig_command(ROOT, []) if arg.startswith("-Dversion-string="))
        first = next(arg for arg in zig.zig_command(ROOT, [], run_id="a1") if arg.startswith("-Dversion-string="))
        self.assertEqual(first, plain + "+omgtests.a1")
        commands = []
        # Tests log raw terminal input, so zig's output is not valid UTF-8.
        result = mock.Mock(returncode=0, stdout=BASELINE.encode(), stderr=b"[stream] (warn): \xb6\xff\n")
        with mock.patch.object(zig.subprocess, "run", lambda command, **kwargs: commands.append(command) or result):
            zig.run_zig(ROOT, ["cli.ssh."])
            code, output = zig.run_zig(ROOT, ["cli.ssh."])
        self.assertNotEqual(commands[0], commands[1])
        self.assertEqual((code, zig.parse_summary(output)["total"]), (0, 79))

    def test_summary_reads_totals_and_names_failing_tests(self):
        self.assertEqual(
            zig.parse_summary(PASSING),
            {"passed": 87, "total": 87, "detail": "", "failed_tests": []},
        )
        self.assertEqual(
            zig.parse_summary(CRASHING),
            {
                "passed": 79,
                "total": 81,
                "detail": "1 crashed, 1 failed",
                "failed_tests": [
                    "terminal.Terminal.test.Terminal: grapheme transfer",
                    "terminal.page.test.Page clone",
                ],
            },
        )
        self.assertEqual(zig.parse_summary("error: build.zig panicked\n")["total"], 0)

    def run_with(self, *results, filters=("terminal.Terminal.",), declared=None):
        calls = []

        def fake(root, names):
            calls.append(list(names))
            return results[len(calls) - 1]

        with mock.patch.object(zig, "run_zig", fake):
            report = zig.run(ROOT, list(filters), declared=declared, log=lambda text: None)
        return report, calls

    def test_selected_count_excludes_the_tests_that_run_under_every_filter(self):
        report, calls = self.run_with((0, BASELINE), (0, PASSING), declared=9)
        self.assertEqual(calls, [[zig.BASELINE_FILTER], ["terminal.Terminal."]])
        self.assertEqual(report["status"], "passed")
        self.assertEqual((report["baseline"], report["selected"], report["total"]), (79, 8, 87))
        self.assertIn("declare 9 tests, 1 more than ran", zig.describe(report))

    def test_a_filter_that_matches_nothing_is_not_a_pass(self):
        report, _ = self.run_with((0, BASELINE), (0, BASELINE), filters=("terminal.Termnal.",))
        self.assertEqual(report["status"], "no_tests_matched")
        self.assertIn("no test matched", zig.describe(report))
        with mock.patch.object(zig, "run", lambda *args, **kwargs: report):
            self.assertEqual(zig.main(["--filter", "terminal.Termnal."]), 1)

    def test_failures_report_the_test_names(self):
        report, _ = self.run_with((0, BASELINE), (1, CRASHING))
        self.assertEqual(report["status"], "failed")
        self.assertIn("terminal.page.test.Page clone", zig.describe(report))

        report, calls = self.run_with((1, "error: build.zig panicked\n"))
        self.assertEqual((report["status"], report["stage"]), ("failed", "baseline"))
        self.assertEqual(len(calls), 1)

    def test_failure_excerpt_keeps_each_report_and_drops_logged_warnings(self):
        excerpt = zig.error_excerpt(CRASHING)
        self.assertIn("panic: page integrity violation", excerpt)
        self.assertIn("[page] (err): page integrity violation", excerpt)
        self.assertIn("expected 12, found 6", excerpt)
        self.assertIn("Build Summary:", excerpt)
        self.assertNotIn("(warn)", excerpt)
        self.assertNotIn("+- run test", excerpt)

        compile_error = "test\n+- compile test ghostty-test 1 errors\nsrc/a.zig:1:1: error: expected ';'\n"
        self.assertIn("src/a.zig:1:1: error", zig.error_excerpt(compile_error))

    def test_the_whole_suite_runs_without_a_baseline_build(self):
        report, calls = self.run_with((0, PASSING), filters=())
        self.assertEqual(calls, [[]])
        self.assertEqual((report["status"], report["baseline"], report["selected"]), ("passed", 0, 87))


if __name__ == "__main__":
    unittest.main()
