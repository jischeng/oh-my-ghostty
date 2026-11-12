#!/usr/bin/env python3
"""End-to-end OMG macOS/iOS release orchestrator with caching, parallel gates, and disk hygiene."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "dist"))

import omg_mobile_test_plan  # noqa: E402
import omg_test_plan  # noqa: E402

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
RELEASE_REPO = "jischeng/oh-my-ghostty"
PBXPROJ_REL = "macos/Ghostty.xcodeproj/project.pbxproj"
IOS_SPEC_REL = "ios/project.yml"
VERSION_TEST_REL = "macos/Tests/Helpers/OhMyGhosttyVersionTests.swift"
INFO_PLIST_REL = "macos/Ghostty-Info.plist"
DRAFT_MARKER = "<!-- TODO(release-notes): replace draft bullets with user-facing highlights -->"

RUNTIME_GATE_PREFIXES = (
    "session-runtime/",
    "dist/macos/build-session-runtime.py",
    "dist/macos/build-mobile-support.py",
    "dist/macos/check-session-runtime.py",
    "dist/macos/session-runtime-",
    "src/shell-integration/omg/",
)


def parse_semver(version: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(version.strip())
    if not match:
        raise ValueError(f"invalid SemVer version: {version!r} (expected X.Y.Z)")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def format_semver(parts: tuple[int, int, int]) -> str:
    return f"{parts[0]}.{parts[1]}.{parts[2]}"


def git_out(root: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True)
    return result.stdout


def latest_published_tag(root: Path) -> str:
    tags = []
    raw = git_out(root, "for-each-ref", "refs/tags/v[0-9]*", "--format=%(refname:short)|%(contents:subject)")
    for line in raw.splitlines():
        tag_name, _, subject = line.partition("|")
        tag_name = tag_name.strip()
        match = TAG_RE.fullmatch(tag_name)
        # Upstream Ghostty tags (e.g. v1.4.0) live in the same repo; OMG release tags
        # always carry an annotated subject starting with "OMG ".
        if match and subject.strip().startswith("OMG "):
            tags.append(((int(match.group(1)), int(match.group(2)), int(match.group(3))), tag_name))
    if not tags:
        raise ValueError("no published OMG vX.Y.Z tags found in repository")
    tags.sort()
    return tags[-1][1]


def read_ghostty_base(plist_bytes: bytes) -> tuple[str, str]:
    data = plistlib.loads(plist_bytes)
    return str(data.get("GhosttyBaseVersion", "")), str(data.get("GhosttyBaseRevision", ""))


def ghostty_base_at_ref(root: Path, ref: str | None = None) -> tuple[str, str]:
    if ref is None:
        return read_ghostty_base((root / INFO_PLIST_REL).read_bytes())
    raw = subprocess.run(
        ["git", "show", f"{ref}:{INFO_PLIST_REL}"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout
    return read_ghostty_base(raw)


def infer_next_version(
    prev_version: str,
    bump: str,
    *,
    ghostty_changed: bool = False,
) -> str:
    major, minor, patch = parse_semver(prev_version)
    if bump == "patch":
        if major == 0 and ghostty_changed:
            raise ValueError(
                "GhosttyBaseVersion/GhosttyBaseRevision changed; pre-1.0 policy requires '--bump minor'"
            )
        return format_semver((major, minor, patch + 1))
    if bump == "minor":
        return format_semver((major, minor + 1, 0))
    raise ValueError(f"unsupported bump kind: {bump!r}")


def validate_release_version(
    target_version: str,
    prev_tag: str,
    *,
    prev_ghostty: tuple[str, str],
    curr_ghostty: tuple[str, str],
    allow_major_milestone: bool = False,
) -> None:
    if not TAG_RE.fullmatch(prev_tag):
        raise ValueError(f"invalid previous tag: {prev_tag!r} (expected vX.Y.Z)")
    prev = parse_semver(prev_tag[1:])
    target = parse_semver(target_version)
    if target <= prev:
        raise ValueError(f"target version {target_version} must be greater than {prev_tag[1:]}")
    if prev[0] == 0 and target[0] >= 1 and not allow_major_milestone:
        raise ValueError(
            "Reaching 1.0.0 requires an explicit human product decision and release-plan update; "
            "pass --allow-major-milestone only when explicitly authorized."
        )
    ghostty_changed = prev_ghostty != curr_ghostty
    if prev[0] == 0 and target[0] == 0:
        expected_patch = (0, prev[1], prev[2] + 1)
        expected_minor = (0, prev[1] + 1, 0)
        if ghostty_changed and target == expected_patch:
            raise ValueError(
                f"Ghostty base changed since {prev_tag} ({prev_ghostty} -> {curr_ghostty}); "
                f"pre-1.0 policy requires minor version {format_semver(expected_minor)}."
            )
        if target not in (expected_patch, expected_minor):
            raise ValueError(
                f"unexpected pre-1.0 jump from {prev_tag[1:]} to {target_version}; "
                f"expected {format_semver(expected_patch)} or {format_semver(expected_minor)}"
            )


def read_current_pbxproj_versions(pbxproj_text: str) -> tuple[str, int]:
    block_re = re.compile(
        r"\{[^{}]*PRODUCT_BUNDLE_IDENTIFIER = com\.jischeng\.omg(?:\.debug)?;[^{}]*\}",
        re.DOTALL,
    )
    blocks = block_re.findall(pbxproj_text)
    if len(blocks) != 3:
        raise ValueError(f"expected 3 OMG app build configuration blocks in pbxproj, found {len(blocks)}")
    marketings = set()
    builds = set()
    for block in blocks:
        m_ver = re.search(r"MARKETING_VERSION = ([^;\s]+);", block)
        b_ver = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", block)
        if not m_ver or not b_ver:
            raise ValueError("missing MARKETING_VERSION or CURRENT_PROJECT_VERSION in OMG app configuration")
        marketings.add(m_ver.group(1))
        builds.add(int(b_ver.group(1)))
    if len(marketings) != 1 or len(builds) != 1:
        raise ValueError(f"inconsistent OMG app versions in pbxproj: marketing={marketings}, build={builds}")
    return next(iter(marketings)), next(iter(builds))


def apply_version_bump(root: Path, version: str, build_number: int) -> dict[str, str]:
    parse_semver(version)
    if build_number < 1:
        raise ValueError(f"invalid build_number: {build_number}")

    pbx_path = root / PBXPROJ_REL
    pbx_text = pbx_path.read_text()
    block_re = re.compile(
        r"\{[^{}]*PRODUCT_BUNDLE_IDENTIFIER = com\.jischeng\.omg(?:\.debug)?;[^{}]*\}",
        re.DOTALL,
    )
    replaced_blocks = 0

    def update_block(match: re.Match[str]) -> str:
        nonlocal replaced_blocks
        block = match.group(0)
        block, c1 = re.subn(r"(MARKETING_VERSION = )[^;\s]+(;)", rf"\g<1>{version}\2", block)
        block, c2 = re.subn(r"(CURRENT_PROJECT_VERSION = )\d+(;)", rf"\g<1>{build_number}\2", block)
        if c1 != 1 or c2 != 1:
            raise ValueError("unexpected MARKETING_VERSION / CURRENT_PROJECT_VERSION count in OMG block")
        replaced_blocks += 1
        return block

    new_pbx = block_re.sub(update_block, pbx_text)
    if replaced_blocks != 3:
        raise ValueError(f"expected 3 OMG configuration blocks in {PBXPROJ_REL}, updated {replaced_blocks}")

    ios_path = root / IOS_SPEC_REL
    ios_text = ios_path.read_text()
    new_ios, ios_c1 = re.subn(
        r'(MARKETING_VERSION:\s*")[^"]+(")',
        rf"\g<1>{version}\2",
        ios_text,
    )
    new_ios, ios_c2 = re.subn(
        r'(CURRENT_PROJECT_VERSION:\s*")[^"]+(")',
        rf"\g<1>{build_number}\2",
        new_ios,
    )
    if ios_c1 != 1 or ios_c2 != 1:
        raise ValueError(f"expected 1 MARKETING_VERSION and 1 CURRENT_PROJECT_VERSION in {IOS_SPEC_REL}")

    test_path = root / VERSION_TEST_REL
    test_text = test_path.read_text()
    # The release metadata test asserts the app's own version, while other tests
    # in the same file assert fixed sample versions; only rewrite the former.
    new_test, t_c1 = re.subn(
        r'(func appBundlePublishesReleaseMetadata\(\) \{.*?#expect\(versions\.omg == ")[^"]+("\))',
        rf"\g<1>{version}\g<2>",
        test_text,
        count=1,
        flags=re.DOTALL,
    )
    new_test, t_c2 = re.subn(
        r'(func appBundleUsesIndependentOMGIdentity\(\) \{.*?#expect\(info\["CFBundleVersion"\] as\? String == ")[^"]+("\))',
        rf"\g<1>{build_number}\g<2>",
        new_test,
        count=1,
        flags=re.DOTALL,
    )
    if t_c1 != 1 or t_c2 != 1:
        raise ValueError(f"expected version assertions in {VERSION_TEST_REL}")

    pbx_path.write_text(new_pbx)
    ios_path.write_text(new_ios)
    test_path.write_text(new_test)
    return {
        "omg_version": version,
        "bundle_version": str(build_number),
        "updated": [PBXPROJ_REL, IOS_SPEC_REL, VERSION_TEST_REL],
    }


def load_signing_env(signing_env: Path | None = None, environ: dict[str, str] | None = None) -> dict[str, str]:
    target_env = os.environ if environ is None else environ
    candidates = []
    if signing_env is not None:
        candidates.append(signing_env)
    elif target_env.get("OMG_SIGNING_ENV"):
        candidates.append(Path(target_env["OMG_SIGNING_ENV"]).expanduser())
    else:
        candidates.append(Path.home() / "Library/Application Support/OMG/ReleaseSigning/signing.env")

    chosen = next((p for p in candidates if p.is_file()), None)
    if chosen is None:
        return dict(target_env)

    for raw_line in chosen.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, raw_val = line.split("=", 1)
        key = key.strip()
        tokens = shlex.split(raw_val, comments=True)
        val = tokens[0] if tokens else ""
        if key and key not in target_env:
            target_env[key] = val
    return dict(target_env)


def run_signing_preflight(root: Path, env: dict[str, str]) -> str:
    policy_proc = subprocess.run(
        ["/bin/bash", str(root / "dist/macos/signing-python.sh"), "policy"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    mode = policy_proc.stdout.strip()
    if mode not in ("self-signed", "developer-id"):
        raise RuntimeError(f"public release builds require self-signed or developer-id mode, got {mode!r}")
    if mode == "self-signed":
        subprocess.run(
            ["/bin/bash", str(root / "dist/macos/signing-python.sh"), "unlock"],
            cwd=root,
            env=env,
            check=True,
        )
    return mode


def scaffold_release_notes(
    root: Path,
    *,
    version: str,
    build_number: int,
    prev_tag: str,
    ghostty_version: str,
    ghostty_revision: str,
    ghostty_changed: bool,
) -> tuple[Path, bool]:
    notes_path = root / f"docs/RELEASE_NOTES_{version}.md"
    if notes_path.is_file():
        return notes_path, False

    commits_raw = git_out(root, "log", "--no-merges", "--format=- `%h` %s", f"{prev_tag}..HEAD").strip()
    if not commits_raw:
        commits_raw = "- Describe the user-visible changes in this release."

    base_note = (
        f"updated from `{prev_tag}`" if ghostty_changed else f"unchanged from `{prev_tag[1:]}`"
    )
    content = f"""# OMG {version} · Ghostty {ghostty_version}

{DRAFT_MARKER}
OMG {version} updates Oh My Ghostty since `{prev_tag}`.

## Highlights

{commits_raw}

## Version and distribution

- OMG **{version}**, bundle version **{build_number}**.
- Ghostty **{ghostty_version}**, revision `{ghostty_revision}` ({base_note}).
- Includes the changes since the published `{prev_tag}` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-{version}-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-{version}-ios-unsigned.ipa`).

## Validation

- Routine change-selected quality gates and packaged artifact checks recorded by
  `dist/macos/omg_release.py` (see `.release-build/{version}/release-summary.md`).
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, and full TCC
  upgrade experiments were **not run** unless explicitly noted above.
"""
    notes_path.write_text(content)
    return notes_path, True


def release_notes_have_draft_markers(notes_path: Path) -> bool:
    if not notes_path.is_file():
        return True
    text = notes_path.read_text()
    return DRAFT_MARKER in text or "TODO(release-notes)" in text


def parse_failed_swift_suites(output: str) -> list[str]:
    """Extract GhosttyTests/<Suite> identifiers from xcodebuild test failure logs."""
    suites: set[str] = set()
    in_failing_section = False
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line == "Failing tests:":
            in_failing_section = True
            continue
        if in_failing_section:
            if not line or line.startswith("**"):
                in_failing_section = False
                continue
            objc_match = re.match(r"^-\[GhosttyTests\.([A-Za-z0-9_]+)\s+", line)
            if objc_match:
                suites.add(f"GhosttyTests/{objc_match.group(1)}")
                continue
            swift_match = re.match(r"^(?:GhosttyTests[./])?([A-Za-z0-9_]+)\.[A-Za-z0-9_]+\(\)$", line)
            if swift_match:
                suites.add(f"GhosttyTests/{swift_match.group(1)}")
                continue
        suite_fail = re.search(r"✘\s+Suite\s+([A-Za-z0-9_]+)\s+failed", line)
        if suite_fail:
            suites.add(f"GhosttyTests/{suite_fail.group(1)}")
    return sorted(suites)


def clean_release_builds(
    root: Path,
    *,
    keep_latest: int = 1,
    dry_run: bool = False,
) -> dict[str, object]:
    release_root = root / ".release-build"
    if not release_root.is_dir():
        return {"removed_paths": [], "reclaimed_bytes": 0}

    version_dirs = []
    for child in release_root.iterdir():
        if child.is_dir() and SEMVER_RE.fullmatch(child.name):
            version_dirs.append((parse_semver(child.name), child))
    version_dirs.sort(key=lambda item: item[0], reverse=True)
    protected_versions = {child.name for _, child in version_dirs[: max(keep_latest, 0)]}

    disposable_always = (
        "obj-arm64",
        "obj-x86_64",
        "obj-universal",
        "appcast-work",
        "session-runtime",
        "arm64",
        "x86_64",
    )
    removed: list[str] = []
    reclaimed = 0

    def dir_size(path: Path) -> int:
        if path.is_file() or path.is_symlink():
            return path.lstat().st_size
        total = 0
        for sub in path.rglob("*"):
            if sub.is_file() or sub.is_symlink():
                try:
                    total += sub.lstat().st_size
                except OSError:
                    pass
        return total

    for _, ver_dir in version_dirs:
        for sub_name in disposable_always:
            candidate = ver_dir / sub_name
            if candidate.exists():
                reclaimed += dir_size(candidate)
                removed.append(str(candidate.relative_to(root)))
                if not dry_run:
                    shutil.rmtree(candidate, ignore_errors=True)
        # Keep universal/Release/OMG.app only for the newest `keep_latest` release(s)
        # so OMG_PREVIOUS_SIGNED_APP DR continuity checks always have a reference app.
        if ver_dir.name not in protected_versions:
            univ = ver_dir / "universal"
            if univ.exists():
                reclaimed += dir_size(univ)
                removed.append(str(univ.relative_to(root)))
                if not dry_run:
                    shutil.rmtree(univ, ignore_errors=True)

    # Remove old loose log files directly under .release-build/*.log
    for log_file in sorted(release_root.glob("*.log")):
        reclaimed += dir_size(log_file)
        removed.append(str(log_file.relative_to(root)))
        if not dry_run:
            log_file.unlink(missing_ok=True)

    return {
        "removed_paths": removed,
        "reclaimed_bytes": reclaimed,
        "protected_versions": sorted(protected_versions),
        "dry_run": dry_run,
    }


def run_parallel_static_gates(root: Path, changed: list[str]) -> list[dict[str, object]]:
    dev_tool = str(root / "dist/macos/dev-tool.sh")
    zig_changed = [p for p in changed if p.endswith(".zig") and (root / p).is_file()]

    tasks: list[tuple[str, list[str]]] = [
        ("swiftlint", ["bash", dev_tool, "swiftlint", "lint", "--strict", "--config", "macos/.swiftlint.yml", "macos"]),
        ("settings-schema", ["bash", dev_tool, "python3", "-m", "json.tool", "docs/settings/schema.json"]),
        ("omg-docs", ["bash", dev_tool, "python3", "dist/check_omg_docs.py"]),
        ("info-plist", ["/usr/bin/plutil", "-lint", "macos/Ghostty-Info.plist"]),
        (
            "mainmenu-xib",
            [
                "bash",
                dev_tool,
                "xcrun",
                "ibtool",
                "--warnings",
                "--errors",
                "--notices",
                "--output-format",
                "human-readable-text",
                "macos/Sources/App/MainMenu.xib",
            ],
        ),
        ("signing-contract", ["bash", dev_tool, "python3", "-m", "unittest", "discover", "-s", "dist", "-p", "test_omg_signing.py"]),
        ("keychain-contract", ["bash", dev_tool, "python3", "-m", "unittest", "discover", "-s", "dist", "-p", "test_omg_keychain.py"]),
        ("test-plan-contract", ["bash", dev_tool, "python3", "-m", "unittest", "discover", "-s", "dist", "-p", "test_omg_test_plan.py"]),
        ("mobile-plan-contract", ["bash", dev_tool, "python3", "-m", "unittest", "discover", "-s", "dist", "-p", "test_omg_mobile_test_plan.py"]),
        ("release-contract", ["bash", dev_tool, "python3", "-m", "unittest", "discover", "-s", "dist", "-p", "test_omg_release.py"]),
    ]
    if zig_changed:
        tasks.append(("zig-fmt", ["mise", "exec", "zig@0.16.0", "--", "zig", "fmt", "--check", *zig_changed]))

    results: list[dict[str, object]] = []
    if not zig_changed:
        results.append({"name": "zig-fmt", "status": "skipped", "seconds": 0.0, "detail": "no .zig files changed"})

    def execute(name: str, cmd: list[str]) -> dict[str, object]:
        t0 = time.monotonic()
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
        elapsed = round(time.monotonic() - t0, 2)
        if proc.returncode != 0:
            raise RuntimeError(f"[{name}] failed (exit {proc.returncode}):\n{proc.stdout}\n{proc.stderr}")
        return {"name": name, "status": "passed", "seconds": elapsed}

    with ThreadPoolExecutor(max_workers=min(8, len(tasks))) as pool:
        futures = {pool.submit(execute, name, cmd): name for name, cmd in tasks}
        for fut in as_completed(futures):
            results.append(fut.result())

    (root / "default.profraw").unlink(missing_ok=True)
    results.sort(key=lambda item: str(item["name"]))
    return results


def runtime_build_env() -> dict[str, str]:
    """Pin Apple's toolchain for the runtime build script.

    A Homebrew binutils entry on PATH shadows Apple's `ar` with GNU ar, whose
    archives ld64 rejects as `not 8-byte aligned`, which makes every
    session-runtime link fail.
    """
    env = dict(os.environ)
    env.setdefault("OMG_RUNTIME_CC", "/usr/bin/cc")
    env.setdefault("OMG_RUNTIME_AR", "/usr/bin/ar")
    return env


def run_cargo_gate_step(root: Path, cmd: list[str], *, attempts: int = 2) -> None:
    """Run one session-runtime gate command, rebuilding cached artifacts once.

    ``cargo clippy --all-targets`` can leave a partially written
    ``out/libomg_vt.a`` behind, and the next step then fails in the linker with
    ``ld: ignoring archive member 'vt.o' - 64-bit mach-o not 8-byte aligned``.
    Clearing this crate's cached artifacts is enough to recover, so retry once
    instead of failing the whole release.
    """
    env = runtime_build_env()
    for attempt in range(1, attempts + 1):
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True, env=env)
        if proc.returncode == 0:
            if proc.stdout:
                print(proc.stdout, end="")
            return
        combined = f"{proc.stdout or ''}\n{proc.stderr or ''}"
        retryable = "8-byte aligned" in combined or "libomg_vt.a" in combined
        if attempt < attempts and retryable:
            print(f"[runtime] {cmd[0]} failed on a cached VT archive; rebuilding the crate")
            subprocess.run(
                ["cargo", "clean", "--manifest-path", "session-runtime/Cargo.toml", "-p", "omg-session-runtime"],
                cwd=root,
                check=True,
                capture_output=True,
                env=env,
            )
            continue
        raise RuntimeError(f"session-runtime gate failed (exit {proc.returncode}): {cmd}\n{combined}")


def run_serial_test_gates(
    root: Path,
    prev_tag: str,
    changed: list[str],
    *,
    max_isolated_retry_suites: int = 3,
) -> dict[str, object]:
    report: dict[str, object] = {}

    runtime_touched = any(p.startswith(RUNTIME_GATE_PREFIXES) for p in changed)
    if runtime_touched:
        t0 = time.monotonic()
        runtime_cmds = [
            ["cargo", "fmt", "--manifest-path", "session-runtime/Cargo.toml", "--check"],
            ["cargo", "clippy", "--manifest-path", "session-runtime/Cargo.toml", "--all-targets", "--", "-D", "warnings"],
            ["cargo", "test", "--manifest-path", "session-runtime/Cargo.toml", "--", "--test-threads=1"],
            ["cargo", "build", "--manifest-path", "session-runtime/Cargo.toml"],
            ["bash", "dist/macos/dev-tool.sh", "python3", "-m", "unittest", "discover", "-s", "session-runtime/tests", "-p", "test_*.py"],
        ]
        for cmd in runtime_cmds:
            run_cargo_gate_step(root, cmd)
        report["session_runtime"] = {"status": "passed", "seconds": round(time.monotonic() - t0, 2)}
    else:
        report["session_runtime"] = {"status": "not_selected", "seconds": 0.0}

    catalog = omg_test_plan.inventory(root)
    _, base_commit = omg_test_plan.changed_paths(root, prev_tag)
    swift_plan = omg_test_plan.make_plan(
        catalog,
        paths=changed,
        version_only=PBXPROJ_REL in changed and omg_test_plan.version_only_change(root, base_commit),
    )
    if swift_plan["run_swift"]:
        t0 = time.monotonic()
        proc = subprocess.run(
            ["nu", "macos/build.nu", "--action", "test", "--changed-since", prev_tag],
            cwd=root,
            capture_output=True,
            text=True,
        )
        combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
        if proc.returncode == 0:
            report["swift"] = {
                "status": "passed",
                "scope": swift_plan["scope"],
                "modules": swift_plan["modules"],
                "suite_count": swift_plan["suite_count"],
                "deferred_desktop": swift_plan["deferred_desktop"],
                "isolated_retries": [],
                "seconds": round(time.monotonic() - t0, 2),
            }
        else:
            failed_suites = parse_failed_swift_suites(combined)
            if not failed_suites or len(failed_suites) > max_isolated_retry_suites:
                sys.stderr.write(combined)
                raise RuntimeError(
                    f"Swift test gate failed (exit {proc.returncode}); failed suites={failed_suites}"
                )
            print(
                f"[swift-gate] Broad run reported {len(failed_suites)} failed suite(s): {failed_suites}; "
                "retrying isolated suite(s) with --skip-build...",
                flush=True,
            )
            for suite in failed_suites:
                retry = subprocess.run(
                    ["nu", "macos/build.nu", "--action", "test", "--skip-build", "--only-testing", suite],
                    cwd=root,
                )
                if retry.returncode != 0:
                    raise RuntimeError(f"Isolated --skip-build retry failed for {suite}")
            report["swift"] = {
                "status": "passed_after_isolated_retry",
                "scope": swift_plan["scope"],
                "modules": swift_plan["modules"],
                "suite_count": swift_plan["suite_count"],
                "deferred_desktop": swift_plan["deferred_desktop"],
                "initial_broad_failures": failed_suites,
                "isolated_retries": failed_suites,
                "seconds": round(time.monotonic() - t0, 2),
            }
    else:
        report["swift"] = {"status": "not_selected", "seconds": 0.0}

    ios_ver_only = IOS_SPEC_REL in changed and omg_mobile_test_plan.ios_version_only_change(root, base_commit)
    mobile_plan = omg_mobile_test_plan.make_plan(changed, ios_version_only=ios_ver_only)
    if mobile_plan["run_mobile"]:
        t0 = time.monotonic()
        subprocess.run(["bash", "ios/scripts/test.sh", "--changed-since", prev_tag], cwd=root, check=True)
        subprocess.run(["bash", "ios/scripts/test-vm.sh", "--changed-since", prev_tag], cwd=root, check=True)
        report["mobile"] = {
            "status": "passed",
            "relevant_paths": mobile_plan["relevant_paths"],
            "seconds": round(time.monotonic() - t0, 2),
        }
    else:
        report["mobile"] = {"status": "not_selected", "seconds": 0.0}

    return report


def verify_packaged_artifacts(root: Path, version: str) -> dict[str, object]:
    build_root = root / ".release-build" / version
    artifacts = build_root / "artifacts"
    expected_files = [
        f"OMG-{version}-macos-arm64.dmg",
        f"OMG-{version}-macos-x86_64.dmg",
        f"OMG-{version}-macos-universal.dmg",
        f"OMG-Mobile-{version}-ios-installer.tar.gz",
        f"OMG-Mobile-{version}-ios-unsigned.ipa",
        "SHA256SUMS.txt",
        "appcast.xml",
    ]
    for name in expected_files:
        p = artifacts / name
        if not p.is_file() or p.stat().st_size == 0:
            raise RuntimeError(f"missing or empty release artifact: {p}")

    sums_lines = (artifacts / "SHA256SUMS.txt").read_text().strip().splitlines()
    recorded = {}
    for line in sums_lines:
        digest, filename = line.split(None, 1)
        recorded[filename.strip()] = digest.strip()
    for name in expected_files[:5]:
        actual = hashlib.sha256((artifacts / name).read_bytes()).hexdigest()
        if recorded.get(name) != actual:
            raise RuntimeError(f"SHA256SUMS mismatch for {name}: expected {recorded.get(name)}, got {actual}")

    appcast_root = ET.parse(artifacts / "appcast.xml").getroot()
    item = appcast_root.find("./channel/item")
    if item is None:
        raise RuntimeError("appcast.xml contains no <item>")
    short_ver = next((c.text.strip() for c in item if c.tag.endswith("shortVersionString") and c.text), "")
    bundle_ver = next((c.text.strip() for c in item if c.tag.endswith("}version") and c.text), "")
    if short_ver != version:
        raise RuntimeError(f"appcast shortVersionString is {short_ver!r}, expected {version!r}")

    rt_dir = build_root / "universal/Release/OMG.app/Contents/Resources/session-runtime"
    rt_revision = (rt_dir / "revision").read_text().strip()
    rt_snapshot = (rt_dir / "snapshot-revision").read_text().strip()
    dr = (build_root / "signing-requirement.txt").read_text().strip()
    return {
        "artifacts_dir": str(artifacts),
        "files": expected_files,
        "bundle_version": bundle_ver,
        "designated_requirement": dr,
        "runtime_revision": rt_revision,
        "snapshot_revision": rt_snapshot,
    }


def write_release_summary(
    root: Path,
    version: str,
    prev_tag: str,
    ghostty_base: tuple[str, str],
    timings: dict[str, float],
    gate_info: dict[str, object] | None,
    pkg_info: dict[str, object],
) -> Path:
    summary_path = root / ".release-build" / version / "release-summary.md"
    rosetta_ok = subprocess.run(["arch", "-x86_64", "true"], capture_output=True).returncode == 0
    lines = [
        f"# OMG {version} Pre-Publish Summary",
        "",
        f"- **Target tag**: `v{version}` (previous: `{prev_tag}`)",
        f"- **Bundle version**: `{pkg_info['bundle_version']}`",
        f"- **Ghostty base**: `{ghostty_base[0]}` (`{ghostty_base[1]}`)",
        f"- **Signing**: persistently self-signed; **not notarized** (`{pkg_info['designated_requirement']}`)",
        f"- **x86_64 verification**: {'launched via Rosetta 2' if rosetta_ok else 'Mach-O + signature + .ReleaseFast verified (Rosetta 2 not installed)'}",
        f"- **Session runtime**: revision `{pkg_info['runtime_revision']}`, snapshot `{pkg_info['snapshot_revision']}`",
        f"- **Timings (s)**: `{json.dumps(timings)}`",
    ]
    if gate_info is not None:
        lines.append(f"- **Test gates**: `{json.dumps(gate_info.get('serial_tests', {}))}`")
    lines.extend([
        "",
        "## Next Step (Requires Explicit User Authorization)",
        "",
        "1. Review and finalize `docs/RELEASE_NOTES_" + version + ".md`.",
        f"2. Run `python3 dist/macos/omg_release.py publish {version} --previous-tag {prev_tag}`.",
        "",
    ])
    summary_path.write_text("\n".join(lines))
    return summary_path


def resolve_version_arg(
    root: Path,
    version: str | None,
    bump: str | None,
    prev_tag: str,
) -> str:
    if version:
        return version
    if bump:
        prev_g = ghostty_base_at_ref(root, prev_tag)
        curr_g = ghostty_base_at_ref(root, None)
        return infer_next_version(prev_tag[1:], bump, ghostty_changed=(prev_g != curr_g))
    curr_marketing, _ = read_current_pbxproj_versions((root / PBXPROJ_REL).read_text())
    if parse_semver(curr_marketing) > parse_semver(prev_tag[1:]):
        return curr_marketing
    raise ValueError("specify target VERSION (e.g. 0.20.4) or --bump patch|minor")


def cmd_plan(args: argparse.Namespace) -> int:
    prev_tag = args.previous_tag or latest_published_tag(REPO_ROOT)
    prev_g = ghostty_base_at_ref(REPO_ROOT, prev_tag)
    curr_g = ghostty_base_at_ref(REPO_ROOT, None)
    curr_ver, curr_build = read_current_pbxproj_versions((REPO_ROOT / PBXPROJ_REL).read_text())
    target = (
        resolve_version_arg(REPO_ROOT, args.version, args.bump, prev_tag)
        if (args.version or args.bump)
        else infer_next_version(prev_tag[1:], "minor" if prev_g != curr_g else "patch", ghostty_changed=(prev_g != curr_g))
    )
    changed, base_commit = omg_test_plan.changed_paths(REPO_ROOT, prev_tag)
    catalog = omg_test_plan.inventory(REPO_ROOT)
    swift_plan = omg_test_plan.make_plan(
        catalog,
        paths=changed,
        version_only=PBXPROJ_REL in changed and omg_test_plan.version_only_change(REPO_ROOT, base_commit),
    )
    ios_ver_only = IOS_SPEC_REL in changed and omg_mobile_test_plan.ios_version_only_change(REPO_ROOT, base_commit)
    mobile_plan = omg_mobile_test_plan.make_plan(changed, ios_version_only=ios_ver_only)
    cleanup_preview = clean_release_builds(REPO_ROOT, keep_latest=1, dry_run=True)

    payload = {
        "previous_tag": prev_tag,
        "current_pbxproj": {"version": curr_ver, "build": curr_build},
        "suggested_target_version": target,
        "ghostty_base": {
            "version": curr_g[0],
            "revision": curr_g[1],
            "changed_since_previous": prev_g != curr_g,
        },
        "changed_files_count": len(changed),
        "session_runtime_gate_selected": any(p.startswith(RUNTIME_GATE_PREFIXES) for p in changed),
        "swift_gate": {
            "run_swift": swift_plan["run_swift"],
            "scope": swift_plan["scope"],
            "modules": swift_plan["modules"],
            "suite_count": swift_plan["suite_count"],
        },
        "mobile_gate": mobile_plan,
        "reclaimable_release_build_gb": round(int(cleanup_preview["reclaimed_bytes"]) / (1024**3), 2),
    }
    print(json.dumps(payload, indent=2))
    return 0


def cmd_prepare(args: argparse.Namespace) -> int:
    prev_tag = args.previous_tag or latest_published_tag(REPO_ROOT)
    target = resolve_version_arg(REPO_ROOT, args.version, args.bump, prev_tag)
    prev_g = ghostty_base_at_ref(REPO_ROOT, prev_tag)
    curr_g = ghostty_base_at_ref(REPO_ROOT, None)
    validate_release_version(
        target,
        prev_tag,
        prev_ghostty=prev_g,
        curr_ghostty=curr_g,
        allow_major_milestone=args.allow_major_milestone,
    )

    branch = git_out(REPO_ROOT, "branch", "--show-current").strip()
    if branch != "main" and not args.allow_branch:
        raise RuntimeError(f"must prepare release on 'main' branch (current: {branch!r}; pass --allow-branch to override)")
    if git_out(REPO_ROOT, "tag", "--list", f"v{target}").strip():
        raise RuntimeError(f"tag v{target} already exists locally")

    if not args.skip_signing_preflight:
        env = load_signing_env(args.signing_env)
        mode = run_signing_preflight(REPO_ROOT, env)
        print(f"[preflight] signing_mode={mode}")

    curr_ver, curr_build = read_current_pbxproj_versions((REPO_ROOT / PBXPROJ_REL).read_text())
    prev_pbx = git_out(REPO_ROOT, "show", f"{prev_tag}:{PBXPROJ_REL}")
    _, prev_build = read_current_pbxproj_versions(prev_pbx)
    if args.build_number is not None:
        next_build = args.build_number
    elif curr_ver == target and curr_build > prev_build:
        next_build = curr_build
    else:
        next_build = max(curr_build, prev_build) + 1

    if next_build <= prev_build:
        raise ValueError(f"bundle build number {next_build} must exceed {prev_tag}'s build number ({prev_build})")

    bump_res = apply_version_bump(REPO_ROOT, target, next_build)
    notes_path, created = scaffold_release_notes(
        REPO_ROOT,
        version=target,
        build_number=next_build,
        prev_tag=prev_tag,
        ghostty_version=curr_g[0],
        ghostty_revision=curr_g[1],
        ghostty_changed=(prev_g != curr_g),
    )
    print(json.dumps({
        **bump_res,
        "previous_tag": prev_tag,
        "release_notes": str(notes_path.relative_to(REPO_ROOT)),
        "release_notes_scaffolded": created,
    }, indent=2))
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    prev_tag = args.previous_tag or latest_published_tag(REPO_ROOT)
    changed, _ = omg_test_plan.changed_paths(REPO_ROOT, prev_tag)
    t0 = time.monotonic()
    static_results = run_parallel_static_gates(REPO_ROOT, changed)
    serial_results = (
        {"skipped": True}
        if args.skip_tests
        else run_serial_test_gates(
            REPO_ROOT,
            prev_tag,
            changed,
            max_isolated_retry_suites=args.max_isolated_retry_suites,
        )
    )
    out = {
        "previous_tag": prev_tag,
        "total_seconds": round(time.monotonic() - t0, 2),
        "static_gates": static_results,
        "serial_tests": serial_results,
    }
    print(json.dumps(out, indent=2))
    return 0


def cmd_build(args: argparse.Namespace) -> int:
    env = load_signing_env(args.signing_env)
    cmd = ["/bin/bash", str(REPO_ROOT / ".agents/skills/omg-release/scripts/build-release.sh")]
    if args.clean:
        cmd.append("--clean")
    if args.no_cache:
        cmd.append("--no-cache")
    cmd.append(args.version)
    subprocess.run(cmd, cwd=REPO_ROOT, env=env, check=True)
    return 0


def cmd_package(args: argparse.Namespace) -> int:
    prev_tag = args.previous_tag or latest_published_tag(REPO_ROOT)
    env = load_signing_env(args.signing_env)
    env["PREVIOUS_TAG"] = prev_tag
    subprocess.run(
        ["/bin/bash", str(REPO_ROOT / ".agents/skills/omg-release/scripts/package-release.sh"), args.version],
        cwd=REPO_ROOT,
        env=env,
        check=True,
    )
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    prev_tag = args.previous_tag or latest_published_tag(REPO_ROOT)
    target = resolve_version_arg(REPO_ROOT, args.version, args.bump, prev_tag)
    timings: dict[str, float] = {}

    t0 = time.monotonic()
    prep_ns = argparse.Namespace(
        version=target,
        bump=None,
        previous_tag=prev_tag,
        build_number=args.build_number,
        signing_env=args.signing_env,
        skip_signing_preflight=False,
        allow_branch=args.allow_branch,
        allow_major_milestone=args.allow_major_milestone,
    )
    cmd_prepare(prep_ns)
    timings["prepare"] = round(time.monotonic() - t0, 2)

    notes_path = REPO_ROOT / f"docs/RELEASE_NOTES_{target}.md"
    if not args.allow_draft_notes and release_notes_have_draft_markers(notes_path):
        raise RuntimeError(
            f"{notes_path.relative_to(REPO_ROOT)} still contains draft TODO markers. "
            "Edit the release notes first (or pass --allow-draft-notes to build/package before finalizing notes)."
        )

    t1 = time.monotonic()
    changed, _ = omg_test_plan.changed_paths(REPO_ROOT, prev_tag)
    static_res = run_parallel_static_gates(REPO_ROOT, changed)
    serial_res = (
        {"skipped": True}
        if args.skip_tests
        else run_serial_test_gates(REPO_ROOT, prev_tag, changed, max_isolated_retry_suites=3)
    )
    gate_info = {"static_gates": static_res, "serial_tests": serial_res}
    timings["gate"] = round(time.monotonic() - t1, 2)

    t2 = time.monotonic()
    cmd_build(argparse.Namespace(version=target, clean=args.clean, no_cache=args.no_cache, signing_env=args.signing_env))
    timings["build"] = round(time.monotonic() - t2, 2)

    t3 = time.monotonic()
    cmd_package(argparse.Namespace(version=target, previous_tag=prev_tag, signing_env=args.signing_env))
    timings["package"] = round(time.monotonic() - t3, 2)

    pkg_info = verify_packaged_artifacts(REPO_ROOT, target)
    curr_g = ghostty_base_at_ref(REPO_ROOT, None)
    summary_path = write_release_summary(REPO_ROOT, target, prev_tag, curr_g, timings, gate_info, pkg_info)
    print(f"release_summary={summary_path}")
    return 0


def cmd_publish(args: argparse.Namespace) -> int:
    version = args.version
    parse_semver(version)
    notes_rel = f"docs/RELEASE_NOTES_{version}.md"
    notes_path = REPO_ROOT / notes_rel
    if release_notes_have_draft_markers(notes_path):
        raise RuntimeError(f"refusing to publish: {notes_rel} is missing or still contains draft TODO markers")

    pkg_info = verify_packaged_artifacts(REPO_ROOT, version)
    ghostty_ver, _ = ghostty_base_at_ref(REPO_ROOT, None)
    title = f"OMG {version} · Ghostty {ghostty_ver}"
    tag = f"v{version}"

    branch = git_out(REPO_ROOT, "branch", "--show-current").strip()
    if branch != "main":
        raise RuntimeError(f"refusing to publish from non-main branch: {branch!r}")
    if git_out(REPO_ROOT, "tag", "--list", tag).strip():
        raise RuntimeError(f"tag {tag} already exists locally")
    existing_rel = subprocess.run(
        ["gh", "release", "view", tag, "-R", RELEASE_REPO],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if existing_rel.returncode == 0:
        raise RuntimeError(f"GitHub Release {tag} already exists on {RELEASE_REPO}")

    allowed_dirty = {PBXPROJ_REL, IOS_SPEC_REL, VERSION_TEST_REL, notes_rel}
    status_entries = [
        entry[3:]
        for entry in git_out(REPO_ROOT, "status", "--porcelain", "-z").split("\0")
        if entry
    ]
    unexpected = sorted(set(status_entries) - allowed_dirty)
    if unexpected:
        raise RuntimeError(
            f"refusing to publish with unrelated working tree changes: {unexpected}. "
            "Commit or separate them before publishing."
        )

    artifacts_dir = Path(str(pkg_info["artifacts_dir"]))
    upload_paths = [str(artifacts_dir / name) for name in pkg_info["files"]]

    if args.dry_run:
        print(json.dumps({
            "dry_run": True,
            "tag": tag,
            "title": title,
            "pending_release_files": status_entries,
            "assets": upload_paths,
        }, indent=2))
        return 0

    if status_entries:
        subprocess.run(["git", "add", "--", *sorted(status_entries)], cwd=REPO_ROOT, check=True)
        subprocess.run(
            ["git", "commit", "-m", f"release: prepare OMG {version}"],
            cwd=REPO_ROOT,
            check=True,
        )

    subprocess.run(["git", "push", "origin", "main"], cwd=REPO_ROOT, check=True)
    subprocess.run(["git", "tag", "-a", tag, "-m", title], cwd=REPO_ROOT, check=True)
    subprocess.run(["git", "push", "origin", f"refs/tags/{tag}"], cwd=REPO_ROOT, check=True)
    subprocess.run(
        [
            "gh",
            "release",
            "create",
            tag,
            *upload_paths,
            "--repo",
            RELEASE_REPO,
            "--verify-tag",
            "--title",
            title,
            "--notes-file",
            str(notes_path),
        ],
        cwd=REPO_ROOT,
        check=True,
    )

    clean_res = clean_release_builds(REPO_ROOT, keep_latest=args.keep_latest, dry_run=False)
    commit_sha = git_out(REPO_ROOT, "rev-parse", "HEAD").strip()
    print(json.dumps({
        "published_tag": tag,
        "commit": commit_sha,
        "release_url": f"https://github.com/{RELEASE_REPO}/releases/tag/{tag}",
        "reclaimed_gb": round(int(clean_res["reclaimed_bytes"]) / (1024**3), 2),
    }, indent=2))
    return 0


def cmd_clean(args: argparse.Namespace) -> int:
    res = clean_release_builds(REPO_ROOT, keep_latest=args.keep_latest, dry_run=args.dry_run)
    res["reclaimed_gb"] = round(int(res["reclaimed_bytes"]) / (1024**3), 2)
    print(json.dumps(res, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan", help="Inspect next version, test scope, and reclaimable disk space")
    p_plan.add_argument("version", nargs="?")
    p_plan.add_argument("--bump", choices=["patch", "minor"])
    p_plan.add_argument("--previous-tag")
    p_plan.set_defaults(func=cmd_plan)

    p_prep = sub.add_parser("prepare", help="Preflight signing, bump version in all 3 targets, scaffold release notes")
    p_prep.add_argument("version", nargs="?")
    p_prep.add_argument("--bump", choices=["patch", "minor"])
    p_prep.add_argument("--previous-tag")
    p_prep.add_argument("--build-number", type=int)
    p_prep.add_argument("--signing-env", type=Path)
    p_prep.add_argument("--skip-signing-preflight", action="store_true")
    p_prep.add_argument("--allow-branch", action="store_true")
    p_prep.add_argument("--allow-major-milestone", action="store_true")
    p_prep.set_defaults(func=cmd_prepare)

    p_gate = sub.add_parser("gate", help="Run parallel static checks and change-selected test suites")
    p_gate.add_argument("--previous-tag")
    p_gate.add_argument("--skip-tests", action="store_true")
    p_gate.add_argument("--max-isolated-retry-suites", type=int, default=3)
    p_gate.set_defaults(func=cmd_gate)

    p_build = sub.add_parser("build", help="Build cached GhosttyKit, universal OMG.app, thinned slices, and runtime")
    p_build.add_argument("version")
    p_build.add_argument("--clean", action="store_true")
    p_build.add_argument("--no-cache", action="store_true")
    p_build.add_argument("--signing-env", type=Path)
    p_build.set_defaults(func=cmd_build)

    p_pkg = sub.add_parser("package", help="Sign apps, package DMGs in parallel, build iOS kit, and generate appcast")
    p_pkg.add_argument("version")
    p_pkg.add_argument("--previous-tag")
    p_pkg.add_argument("--signing-env", type=Path)
    p_pkg.set_defaults(func=cmd_package)

    p_run = sub.add_parser("run", help="Execute prepare + gate + build + package end-to-end (stops before git push/publish)")
    p_run.add_argument("version", nargs="?")
    p_run.add_argument("--bump", choices=["patch", "minor"])
    p_run.add_argument("--previous-tag")
    p_run.add_argument("--build-number", type=int)
    p_run.add_argument("--clean", action="store_true")
    p_run.add_argument("--no-cache", action="store_true")
    p_run.add_argument("--skip-tests", action="store_true")
    p_run.add_argument("--allow-draft-notes", action="store_true")
    p_run.add_argument("--allow-branch", action="store_true")
    p_run.add_argument("--allow-major-milestone", action="store_true")
    p_run.add_argument("--signing-env", type=Path)
    p_run.set_defaults(func=cmd_run)

    p_pub = sub.add_parser("publish", help="Commit release prep, push main + tag, publish GitHub Release, and clean intermediates")
    p_pub.add_argument("version")
    p_pub.add_argument("--previous-tag")
    p_pub.add_argument("--keep-latest", type=int, default=1)
    p_pub.add_argument("--dry-run", action="store_true")
    p_pub.set_defaults(func=cmd_publish)

    p_clean = sub.add_parser("clean", help="Reclaim disk space in .release-build while keeping artifacts and latest signed app")
    p_clean.add_argument("--keep-latest", type=int, default=1)
    p_clean.add_argument("--dry-run", action="store_true")
    p_clean.set_defaults(func=cmd_clean)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(f"Release step failed (exit {error.returncode}): {error.cmd[0]}", file=sys.stderr)
        else:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
