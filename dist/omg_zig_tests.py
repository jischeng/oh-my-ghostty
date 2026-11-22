#!/usr/bin/env python3
"""Run the Zig unit tests of changed files with the repository's toolchain and flags.

`zig build test` has several traps when it is typed by hand: the `zig` on PATH
may be the wrong release, a commit carrying an OMG tag makes the build panic
unless the version is passed explicitly, a filter that matches nothing still
exits 0 because unnamed tests run under every filter, and without a filter the
build also replaces GhosttyKit with a Debug build and runs the app's tests on
the host desktop. This wrapper picks the toolchain and flags, derives filters
from changed files, and reports how many selected tests actually ran.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import omg_test_plan  # noqa: E402

SOURCE_ROOT = "src/"
# A name no test can contain. Unnamed tests ignore filters, so a build with
# only this filter runs exactly the tests that run under every filter.
BASELINE_FILTER = "omg-zig-tests-baseline-matches-no-test"
DECLARED_TEST = re.compile(r'^[ \t]*test[ \t]+(?:"|@"|[A-Za-z_])', re.MULTILINE)
TESTS_PASSED = re.compile(r"(\d+)/(\d+) tests passed(?: \(([^)]*)\))?")
FAILED_TEST = re.compile(r"^error: '(.+)' (?:failed|terminated|leaked|logged|timed out)", re.MULTILINE)
LOGGED_WARNING = re.compile(r"^\s*\[[\w.]+\] \((?:warn|info|debug)\):")


def zon_value(root, key):
    match = re.search(rf'^\s*\.{key}\s*=\s*"([^"]+)"', (root / "build.zig.zon").read_text(), re.MULTILINE)
    if not match:
        raise SystemExit(f"build.zig.zon has no .{key}")
    return match.group(1)


def filter_for(path):
    """`src/terminal/Terminal.zig` -> `terminal.Terminal.`.

    A test's full name starts with its file's path below `src/`, with dots for
    slashes. The trailing dot keeps tests nested in a container of that file
    (`terminal.page.Page.test.…`) while leaving out `terminal.Terminal2.…`.
    """
    if not path.startswith(SOURCE_ROOT) or not path.endswith(".zig"):
        return None
    return path[len(SOURCE_ROOT) : -len(".zig")].replace("/", ".") + "."


def declared_tests(root, path):
    try:
        return len(DECLARED_TEST.findall((root / path).read_text()))
    except (OSError, UnicodeDecodeError):
        return 0


def make_plan(root, paths):
    """Select the changed Zig files that still exist and declare named tests."""
    selected, without_tests = [], []
    for path in sorted(set(paths)):
        name = filter_for(path)
        if name is None or not (root / path).is_file():
            continue
        declared = declared_tests(root, path)
        if declared:
            selected.append({"path": path, "filter": name, "declared": declared})
        else:
            without_tests.append(path)
    return {
        "run_zig": bool(selected),
        "files": selected,
        "filters": [item["filter"] for item in selected],
        "declared": sum(item["declared"] for item in selected),
        "files_without_tests": without_tests,
    }


def zig_command(root, filters, run_id=None):
    """`run_id` makes this build differ from every earlier one.

    zig reuses the result of an identical earlier test run and then prints no
    counts, so a repeated run could not tell "passed" from "selected nothing".
    The id goes into the version's build metadata, the same place a normal
    development build carries its commit, and forces the tests to really run.
    """
    version = zon_value(root, "version")
    if run_id:
        version += f"+omgtests.{run_id}"
    command = [
        "mise",
        "exec",
        f"zig@{zon_value(root, 'minimum_zig_version')}",
        "--",
        "zig",
        "build",
        "test",
        # On macOS an unfiltered `zig build test` otherwise also builds a Debug
        # GhosttyKit over macos/GhosttyKit.xcframework and runs the app's
        # XCTest through raw xcodebuild on the host desktop.
        "-Demit-macos-app=false",
        "-Demit-xcframework=false",
        # Without this the build reads the version from Git and panics on a
        # commit that carries an OMG `vX.Y.Z` tag.
        f"-Dversion-string={version}",
        "--summary",
        "all",
    ]
    return command + [f"-Dtest-filter={name}" for name in filters]


def parse_summary(output):
    """Totals of the last `Build Summary` line, and the tests zig named as failing."""
    passed = total = 0
    detail = ""
    for line in output.splitlines():
        if line.startswith("Build Summary:"):
            match = TESTS_PASSED.search(line)
            passed, total, detail = (int(match.group(1)), int(match.group(2)), match.group(3) or "") if match else (0, 0, "")
    return {"passed": passed, "total": total, "detail": detail, "failed_tests": sorted(set(FAILED_TEST.findall(output)))}


def error_excerpt(output, per_test=30):
    """Each failing test with the start of its report, without the warnings tests log.

    The raw output is thousands of lines: every shard's stderr, then the whole
    step tree. A build error has no per-test report, so its first lines are
    returned instead.
    """
    lines = output.splitlines()
    picked = []
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if FAILED_TEST.match(line):
            picked.append(line)
            kept = 0
            while index < len(lines) and lines[index].startswith("       "):
                if kept < per_test and not LOGGED_WARNING.match(lines[index]):
                    picked.append(lines[index])
                    kept += 1
                index += 1
        elif line.startswith("Build Summary:"):
            picked.append(line)
    if any(FAILED_TEST.match(line) for line in picked):
        return "\n".join(picked)
    head = [line for line in lines if line.strip() and not LOGGED_WARNING.match(line)]
    return "\n".join(head[:80])


def run_zig(root, filters):
    env = dict(os.environ)
    # A stale absolute SDKROOT outlives the Xcode that provided it.
    env.pop("SDKROOT", None)
    command = zig_command(root, filters, run_id=f"{time.time_ns():x}")
    proc = subprocess.run(command, cwd=root, capture_output=True, env=env)
    # Tests log raw terminal input, so the output is not valid UTF-8.
    output = b"\n".join([proc.stdout or b"", proc.stderr or b""]).decode("utf-8", errors="replace")
    return proc.returncode, output


def run(root, filters, *, declared=None, log=print):
    """Run `filters` and report how many selected tests ran.

    With no filters the whole suite runs. Otherwise a first build measures the
    tests that run under any filter, so the selected count is exact.
    """
    report = {"filters": list(filters), "declared": declared}
    baseline = 0
    if filters:
        code, output = run_zig(root, [BASELINE_FILTER])
        summary = parse_summary(output)
        if code != 0:
            log(error_excerpt(output))
            return {**report, "status": "failed", "stage": "baseline", "failed_tests": summary["failed_tests"]}
        baseline = summary["total"]

    code, output = run_zig(root, filters)
    summary = parse_summary(output)
    selected = max(summary["total"] - baseline, 0)
    report.update(
        {
            "baseline": baseline,
            "selected": selected,
            "passed": summary["passed"],
            "total": summary["total"],
            "detail": summary["detail"],
            "failed_tests": summary["failed_tests"],
        }
    )
    if code != 0:
        log(error_excerpt(output))
        return {**report, "status": "failed", "stage": "tests"}
    if filters and selected == 0:
        return {**report, "status": "no_tests_matched"}
    return {**report, "status": "passed"}


def describe(report):
    status = report["status"]
    if status == "no_tests_matched":
        return (
            f"no test matched {report['filters']}: only the {report['baseline']} unnamed tests ran. "
            "The file is not part of this platform's test binary, or the filter is misspelled."
        )
    if status == "failed":
        names = "".join(f"\n  {name}" for name in report.get("failed_tests", []))
        return f"FAILED ({report.get('detail') or report['stage']}){names}"
    line = f"{report['selected']} selected tests ran, {report['passed']}/{report['total']} passed"
    if report["baseline"]:
        line += f" ({report['baseline']} of them are unnamed tests that run under every filter)"
    if report.get("detail"):
        line += f"; {report['detail']}"
    declared = report.get("declared")
    if declared is not None and report["selected"] < declared:
        line += (
            f"\nNOTE: the selected files declare {declared} tests, {declared - report['selected']} more than ran. "
            "Those are not compiled into this platform's test binary; rerun one file with --filter to see which."
        )
    return line


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument("--changed-since", metavar="REF", help="test the Zig files changed since REF, including the worktree")
    scope.add_argument("--filter", action="append", metavar="TEXT", help="run tests whose full name contains TEXT (repeatable)")
    scope.add_argument("--all", action="store_true", help="run the whole Zig suite (slow)")
    parser.add_argument("--plan-only", action="store_true", help="print the selection as JSON without building")
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    args = parser.parse_args(argv)

    plan = None
    if args.changed_since:
        paths, _ = omg_test_plan.changed_paths(ROOT, args.changed_since)
        plan = make_plan(ROOT, paths)
        filters, declared = plan["filters"], plan["declared"]
    else:
        filters, declared = (args.filter or []), None

    if args.plan_only:
        payload = plan or {"run_zig": True, "filters": filters}
        print(json.dumps({**payload, "command": zig_command(ROOT, filters)}, indent=2))
        return 0
    if plan is not None and not plan["run_zig"]:
        report = {"status": "not_selected", "files_without_tests": plan["files_without_tests"]}
        print(json.dumps(report, indent=2) if args.json else "[zig-tests] no changed Zig file declares tests; nothing ran")
        return 0

    log = (lambda text: print(text, file=sys.stderr)) if args.json else print
    for item in (plan or {}).get("files", []):
        log(f"[zig-tests] {item['path']}: filter {item['filter']} ({item['declared']} declared)")
    report = run(ROOT, filters, declared=declared, log=log)
    if plan is not None:
        report["files"] = plan["files"]
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[zig-tests] {describe(report)}")
    # A selection made from changed files may legitimately match nothing (a
    # Linux-only file on macOS). A filter typed by hand that matches nothing is
    # a mistake, so it must not look like a pass.
    if report["status"] == "passed":
        return 0
    if report["status"] == "no_tests_matched" and plan is not None:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
