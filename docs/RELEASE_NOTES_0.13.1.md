# OMG 0.13.1 · Ghostty 1.3.2-dev

OMG 0.13.1 is a bug-fix release focused on the Git history graph,
editor rendering, and terminal colour accuracy in fullscreen.

## Changes since 0.13.0

- **Git history graph — lazygit lane engine** — replaced the previous
  lane assignment algorithm with a port of lazygit's graph engine,
  producing cleaner layouts for complex branch topologies and keeping
  stable branch colours across page loads.
- **Git history graph — visual polish** — lane lines now connect
  continuously at cell boundaries without gaps; lane colours no longer
  collide on repositories with many simultaneous branches; trunk lane
  zero retains a stable colour and remote-only commits are labelled
  until they merge into local history; scope selection and column
  widths persist across sessions.
- **Editor visibility** — the editor overlay now uses native
  `NSView.isHidden` instead of opacity-only hiding. This keeps undo
  stacks, scroll positions, and the markdown WebView mounted while the
  editor is hidden, and stops WebKit from holding foreground assertions
  that caused terminal scrolling to stutter.
- **Fullscreen chrome colour** — the shell chrome background matches
  the terminal's rendered background colour in fullscreen, and chrome
  and window colours are quantized to the renderer's Display P3 output
  space to prevent rounding mismatches at the pixel boundary.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.13.1-macos-arm64.dmg` — Apple Silicon
- `OMG-0.13.1-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.13.1-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
