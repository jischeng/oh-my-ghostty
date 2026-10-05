# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Test (Swift modules)**: `macos/build.nu --action test --test-modules git,editor`
- **Test (Swift changes)**: `macos/build.nu --action test --changed-since <base-ref>`
  - Inspect with `--test-plan-only`; releases use the previous published OMG tag.
  - Shared host/core, build/test infrastructure, or unmapped changes fall back to
    all routine Swift suites. Release size alone does not require a full sweep.
- **Test (Swift routine full)**: `macos/build.nu --action test --test-modules all`
  - Interactive-desktop tests are optional and excluded by default, not passed.
  - After native tab/drag/focus changes, run relevant desktop tests explicitly on
    an unlocked foreground desktop with `--include-desktop-tests`.
  - Swift selection does not replace affected Zig/Python/shell/artifact checks.
- **Test selector contract**: `python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'`
  - Test tiers and mappings: `docs/TESTING.md`. Build and test strictly serially.
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`
- **OMG documentation contract:** `python3 dist/check_omg_docs.py`
- **OMG release signing:** Use `OMG_SIGNING_IDENTITY=-` (ad-hoc). Apps and DMGs are
  not notarized. Developer ID certificates and notarization credentials are not
  release prerequisites. Keep code-signature, launch, DMG, and Sparkle EdDSA
  checks; see `docs/RELEASING.md`.

Any change to plugin APIs, manifests, wire messages, capabilities, lifecycle,
loading/discovery, package layout, Inspector provider behavior, or permissions
must update `docs/PLUGIN_DEVELOPMENT.md` and relevant tests in the same commit.

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## OMG Architecture Principles

- Keep the complete Ghostty macOS app as the host; do not rewrite OMG around
  `libghostty-internal` or `libghostty-vt` without a separately approved
  migration to a stable, public, full embedder API.
- Put OMG features and business logic in fork-owned files.
- Limit edits to upstream-owned files to small adapters, registration points,
  or the minimum missing lower-level capability.
- Gradually compress OMG changes to `TerminalController`, `AppDelegate`, and
  `TerminalView` into protocols, extensions, or centralized adapters.
- Sync `upstream` frequently and resolve conflicts in small batches.

See `docs/oh-my-ghostty-architecture.md` for the detailed architecture baseline.

