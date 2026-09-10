# OMG 0.12.1 · Ghostty 1.3.2-dev

OMG 0.12.1 is a bug-fix release that stabilizes the Git inspector layout,
improves diff rendering, and refines sidebar interactions.

## Changes since 0.12.0

- **Inspector layout** — pane switching is more reliable; the history table and
  scroll position are preserved across tab switches.
- **Diff highlights** — line-level diff highlights refresh correctly after the
  editor mounts.
- **Sidebar trees** — branch, worktree, and changes trees are compacted;
  batch staging and unstaging are available alongside per-file operations.
- **Index state** — collections and index synchronization are unified, and
  picker navigation is preserved during ref refreshes.
- **Working directory** — the terminal seeds the initial working directory
  from launch configuration before shell reports arrive, so inspector
  providers consume shared context immediately.
- **Scope menu** — the history scope menu is stable across view transitions.
- **Virtualised changes** — the changes list lazily renders visible rows,
  improving performance with large working trees.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.12.1-macos-arm64.dmg` — Apple Silicon
- `OMG-0.12.1-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.12.1-macos-universal.dmg` — universal (used by the built-in updater)

Verify checksums with `SHA256SUMS.txt` before installing.