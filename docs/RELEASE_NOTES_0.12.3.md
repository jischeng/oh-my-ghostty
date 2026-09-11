# OMG 0.12.3 · Ghostty 1.3.2-dev

OMG 0.12.3 improves the Git diff review toolbar with stabilized
navigation, visible hover states, and streamlined file actions.

## Changes since 0.12.2

- **Diff toolbar** — navigation is stabilized across view contexts;
  hover states are properly visible; toolbar states are refined for
  consistent behavior.
- **Git file actions** — diff tabs are retained when switching files;
  per-file Git actions (stage, unstage, discard) are accessible from
  the diff view; linked scrolling is clarified in the interface.
- **Localization** — Git actions are localised where applicable.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.12.3-macos-arm64.dmg` — Apple Silicon
- `OMG-0.12.3-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.12.3-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.