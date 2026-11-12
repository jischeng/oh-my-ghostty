#!/usr/bin/env python3
"""Select mobile checks without building apps, booting a VM or a Simulator."""
import argparse
from collections import Counter
from fnmatch import fnmatchcase
import json
import re
import subprocess

from omg_test_plan import ROOT, changed_paths, git

IOS_VERSION_SPEC = "ios/project.yml"


# These files are linked into the mobile VT library or define its host transport.
# A macOS feature, version bump or release alone does not select mobile checks.
SHARED_PATHS = (
    "session-runtime/src/mobile.rs", "session-runtime/src/mobile/**", "session-runtime/src/host.rs",
    "session-runtime/src/server.rs", "session-runtime/src/lib.rs",
    "session-runtime/src/main.rs", "session-runtime/src/session_cli.rs",
    "session-runtime/src/registry.rs", "session-runtime/src/record.rs",
    "session-runtime/src/holder.rs", "session-runtime/src/lifecycle.rs",
    "session-runtime/src/activity.rs",
    "session-runtime/src/terminal_output.rs",
    "session-runtime/src/vt.c", "session-runtime/src/client.rs",
    "session-runtime/mobile-support/**",
    "session-runtime/Cargo.*", "session-runtime/build.rs",
    "src/omg/session/**", "src/terminal/**", "src/input/**",
    "src/lib_vt.zig", "src/simd/**", "src/build/GhosttyLibVt.zig",
    "src/build/SharedDeps.zig", "src/build/Config.zig",
    "include/ghostty/vt.h", "include/ghostty/vt/**",
    "dist/macos/build-session-runtime.py",
    "dist/macos/build-mobile-support.py",
    "dist/macos/session-runtime-snapshot-compatibility.json",
    "build.zig", "build.zig.zon",
)


def ios_version_only_change(root, commit):
    """Metadata-only version bumps in ios/project.yml do not select mobile UI gates."""
    changed = []
    for comparison in [(commit, "HEAD"), ("HEAD",)]:
        diff = git(root, "diff", "--no-ext-diff", "--no-textconv", "--unified=0", *comparison, "--", IOS_VERSION_SPEC)
        changed.extend(
            line for line in diff.splitlines()
            if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))
        )
    if not changed:
        return False
    counts = {"+": Counter(), "-": Counter()}
    for line in changed:
        match = re.fullmatch(r'[+-]\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION):\s*"[^"]+"', line)
        if not match:
            return False
        counts[line[0]][match[1]] += 1
    return counts["+"] == counts["-"]


def make_plan(paths, *, ios_version_only=False):
    relevant = sorted({
        path for path in paths
        if not (path == IOS_VERSION_SPEC and ios_version_only)
        and (
            (path.startswith("ios/") and not path.endswith((".md", ".gitignore")))
            or any(fnmatchcase(path, pattern) for pattern in SHARED_PATHS)
        )
    })
    return {
        "run_mobile": bool(relevant),
        "relevant_paths": relevant,
        "checks": ["native-core", "simulator-build", "vm-simulator-ui"] if relevant else [],
        "reason": "Mobile implementation or shared dependency changed." if relevant
        else "No mobile implementation or shared dependency changed; do not start mobile tools.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-since", required=True)
    args = parser.parse_args()
    try:
        paths, commit = changed_paths(ROOT, args.changed_since)
        version_only = IOS_VERSION_SPEC in paths and ios_version_only_change(ROOT, commit)
        print(json.dumps({**make_plan(paths, ios_version_only=version_only), "base_commit": commit}, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"Mobile test plan error: {error}\n")


if __name__ == "__main__":
    main()
