# OMG 0.14.0 · Ghostty 1.3.2-dev

OMG 0.14.0 is a feature release focused on the Git inspector, adding
full remote sync workflows (pull, push, fetch) and configurable
background auto-fetch. (Closes #18)

## Changes since 0.13.1

- **Git inspector — pull, push, and fetch** — the inspector toolbar
  gains a pull/push popover and a dedicated fetch button. Push without
  an upstream prompts for a remote and destination and sets the
  upstream; pull and push refuse to run in detached HEAD or with
  unsaved editor changes, and serialize against other Git operations in
  the same worktree.
- **Git inspector — background auto-fetch** — repositories with a
  remote are fetched (with prune) automatically on a configurable
  interval while the app is active. The interval is configurable in
  Settings and from the fetch button's context menu (default every 5
  minutes, 0 disables).
- **Git inspector — operation feedback** — fetch, pull, and push show
  a transient success notice ("Fetch complete", "Pull complete",
  "Push complete", or "Already up to date") in the inspector header,
  auto-dismissed after four seconds and clearable manually.
- **Git inspector — upstream tracking display** — the current branch's
  upstream is shown as a compact status with remote-gone detection and
  ahead/behind counts; the pull and push rows in the popover surface
  the same counts as badges.
- **Git inspector — push to** — the branch context-menu item is renamed
  "Push to…" to distinguish explicit remote/destination pushes from
  pushing the current branch to its upstream.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.14.0-macos-arm64.dmg` — Apple Silicon
- `OMG-0.14.0-macos-x86_64.dmg` — Intel (binary architecture verified;
  launch under Rosetta 2 not tested on the build machine)
- `OMG-0.14.0-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
