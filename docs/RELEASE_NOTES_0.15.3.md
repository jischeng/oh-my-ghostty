# OMG 0.15.3 · Ghostty 1.3.2-dev

OMG 0.15.3 adds configurable keyboard shortcuts for switching the
right Inspector panels, following the same interaction model decided
during development: expand-then-switch, same-panel hides, others
switch in place.

## New features

- **Inspector panel shortcuts** — four new keys
  (`keyboard.inspectorPanel1` through `keyboard.inspectorPanel4`,
  default `option+1` … `option+4`) target the four Inspector panels
  in the right sidebar. When the Inspector is hidden, a shortcut
  expands it and selects the target panel. Pressing the shortcut of
  the already-selected panel hides the Inspector; pressing another
  panel's shortcut switches panels while keeping the Inspector open.
  All four shortcuts are configurable in Settings > Keyboard with
  conflict detection and restore-to-defaults, and are documented in
  the settings configuration table and schema.

## Ghostty core

Unchanged since 0.15.1.

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by
Apple — no Developer ID Application identity or notarization profile is
configured on the build machine. macOS Gatekeeper will warn on first
launch; open the app via System Settings → Privacy & Security or
right-click → Open to proceed.

## Validation

- SwiftLint `--strict` over `macos` with zero violations.
- `zig fmt --check`, `docs/settings/schema.json`, `dist/check_omg_docs.py`,
  `plutil -lint`, and `ibtool` on `MainMenu.xib`.
- Patch release: targeted app-hosted tests for the changed suites
  (settings version, keyboard shortcut, and Inspector shortcut tests)
  via `macos/build.nu --action test --only-testing`.
- Intel evidence is limited: Rosetta 2 is **not installed** on the build
  machine, so each `x86_64` binary was verified by its Mach-O slice and
  `.ReleaseFast` marker only. It was **not launched**, on hardware or
  under emulation.

## Installation

Download the DMG for your architecture:

- `OMG-0.15.3-macos-arm64.dmg` — Apple Silicon
- `OMG-0.15.3-macos-x86_64.dmg` — Intel (architecture and `.ReleaseFast`
  verified; **not launched** — Rosetta 2 is unavailable on the build
  machine, so Intel behavior is untested here)
- `OMG-0.15.3-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
