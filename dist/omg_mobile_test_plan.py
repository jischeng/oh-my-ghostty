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


# Changes to the iOS app or its mobile companion/gateway endpoints select full
# mobile checks (native core + Simulator build + guest VM/Simulator UI).
MOBILE_UI_PATHS = (
    "session-runtime/src/mobile.rs",
    "session-runtime/src/mobile/**",
    "session-runtime/mobile-support/**",
    "dist/macos/build-mobile-support.py",
)

# Changes to libghostty-vt or snapshot wire compatibility linked into iOS select
# fast local native-core SwiftPackage tests without booting Simulator or VM.
# Desktop-only Ghostty (`src/omg/session/**`, `macos/**`) and non-mobile `omgd`
# modules (`server.rs`, `launchd.rs`, `host.rs`, `client.rs`, etc., already
# covered by `cargo test` and macOS `SessionRuntime*Tests`) do not select iOS.
MOBILE_VT_PATHS = (
    "include/ghostty/vt.h",
    "include/ghostty/vt/**",
    "src/lib_vt.zig",
    "src/terminal/**",
    "src/simd/**",
    "src/unicode/**",
    "src/input/paste.zig",
    "src/input/key.zig",
    "src/input/key_encode.zig",
    "src/input/key_mods.zig",
    "src/input/function_keys.zig",
    "src/input/kitty.zig",
    "src/input/mouse.zig",
    "src/input/mouse_encode.zig",
    "src/build/GhosttyLibVt.zig",
    "src/build/GhosttyZig.zig",
    "dist/macos/session-runtime-snapshot-compatibility.json",
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


IOS_SELECTOR_WRAPPERS = frozenset({
    "ios/scripts/test.sh",
    "ios/scripts/test-vm.sh",
})


def _is_ios_implementation(path):
    return (
        path.startswith("ios/")
        and path not in IOS_SELECTOR_WRAPPERS
        and not path.endswith((".md", ".gitignore"))
    )


def make_plan(paths, *, ios_version_only=False):
    ui_paths = sorted({
        path for path in paths
        if not (path == IOS_VERSION_SPEC and ios_version_only)
        and (
            _is_ios_implementation(path)
            or any(fnmatchcase(path, pattern) for pattern in MOBILE_UI_PATHS)
        )
    })
    vt_paths = sorted({
        path for path in paths
        if path not in ui_paths
        and any(fnmatchcase(path, pattern) for pattern in MOBILE_VT_PATHS)
    })
    relevant = sorted(set(ui_paths) | set(vt_paths))
    if ui_paths:
        checks = ["native-core", "simulator-build", "vm-simulator-ui"]
        reason = "Mobile implementation or companion gateway changed."
    elif vt_paths:
        checks = ["native-core"]
        reason = "Shared libghostty-vt or snapshot compatibility changed; run native mobile core checks only."
    else:
        checks = []
        reason = "No mobile implementation or shared VT dependency changed; do not start mobile tools."
    return {
        "run_mobile": bool(relevant),
        "relevant_paths": relevant,
        "checks": checks,
        "reason": reason,
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
