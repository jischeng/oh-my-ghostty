# OMG 0.12.0 · Ghostty 1.3.2-dev

OMG 0.12.0 ships a built-in Git inspector with full read/write workflow
support: staged/unstaged diffs in the editor, branch management, and commit
operations — all without leaving the terminal.

## What's new

### Git inspector

- **Editor diff view** — commit, staged, and unstaged diffs open directly in
  the editor pane, with Side by Side and Inline modes, syntax highlighting,
  added/deleted line tints, and bidirectional linked scrolling that maps source
  line positions through Git's hunks.
- **Changes pane** — lists staged and unstaged/untracked paths separately.
  Checking an unstaged row stages the whole file; unchecking a staged row
  unstages it without deleting the working file. Commit Staged submits the
  index via a commit message, preserving the draft on failure.
- **Branches pane** — expandable Local/Remotes folder tree with stable ref IDs.
  Context menus offer switching, creating a branch from a ref, pushing a local
  branch, and setting its upstream. Remote refs can create local tracking
  branches.
- **Worktrees pane** — lists worktrees alongside branches in the inspector.
- **History graph** — first-parent lane is pinned; rows are sized to their
  graph extent; commit expansion is preserved across refreshes; graph is
  decoupled from content column alignment; navigation is compact and responsive.
- **SSH connection reuse** — SSH connections are reused across Git operations
  within the same session.
- **Upstream tracking status** — the inspector header shows ahead/behind, up to
  date, or gone against locally cached refs; routine refresh never fetches.
- Mutations are serialised per worktree and separate from cancellable polling
  tasks. Git refusals, non-fast-forward rejection, signing, and authentication
  errors appear in a dismissible banner. No forced checkout/push, stash, reset,
  hook bypass, or terminal injection is performed.

### Other

- Git execution and refresh lifecycles have been unified and simplified.
- The legacy native diff detail window remains available internally.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

A Developer ID–signed and notarized build will be published in a future release
once the signing certificate is available.

## Installation

Download the DMG for your architecture:

- `OMG-0.12.0-macos-arm64.dmg` — Apple Silicon
- `OMG-0.12.0-macos-x86_64.dmg` — Intel (tested under Rosetta 2)
- `OMG-0.12.0-macos-universal.dmg` — universal (used by the built-in updater)

Verify checksums with `SHA256SUMS.txt` before installing.
