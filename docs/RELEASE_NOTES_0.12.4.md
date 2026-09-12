# OMG 0.12.4 · Ghostty 1.3.2-dev

OMG 0.12.4 is a bug-fix release that keeps inspector content stable
across sidebar transitions and tightens Git history navigation.

## Changes since 0.12.3

- **Inspector content** — inspector state is retained across sidebar
  transitions instead of resetting.
- **Segmented control** — editor and Git segmented controls share
  consistent styling.
- **History files** — history file listing is tightened, and folder
  trees are reused instead of rebuilt.
- **Git navigation** — search and collection navigation are unified.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.12.4-macos-arm64.dmg` — Apple Silicon
- `OMG-0.12.4-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.12.4-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.