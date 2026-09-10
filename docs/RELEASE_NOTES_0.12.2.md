# OMG 0.12.2 · Ghostty 1.3.2-dev

OMG 0.12.2 is a bug-fix release that preserves terminal input after
tab drags, event monitor expiry, and inactive terminal redraws.

## Changes since 0.12.1

- **Terminal input** — mouse and keyboard input is preserved after tab
  drags and when event monitor owners expire.
- **Tab clicks** — clicks resolve correctly through live native windows.
- **Inspector state** — memory usage is bounded for hidden inspector
  panes and redraws.
- **Renderer** — spare frames are released for inactive terminals,
  reducing GPU memory pressure.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.12.2-macos-arm64.dmg` — Apple Silicon
- `OMG-0.12.2-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.12.2-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.