# OMG 0.15.0 · Ghostty 1.3.2-dev

OMG 0.15.0 is a feature release focused on Agent status presentation:
split-tab agent logos, remote agent identity wrappers, and clearer
extension lifecycle handling in settings.

## Changes since 0.14.0

- **Agent status — split pane logos** — the tab icon composes the real
  split structure instead of a single logo. Panes keep a minimum
  recognizable size and further splits fold into a bounded stacked
  layout; each pane keeps its own activity state while the tab reports
  combined work in one shared indicator.
- **Agent status — logo tint replaces the activity ring** — working,
  attention, and completion states are expressed through the logo tint
  with scheme-aware animation, and pane focus is tinted only while the
  tab is selected.
- **Remote agent wrappers** — remote `omg +ssh` sessions install
  identity-only shell wrappers for `agy` and `codex` when the names
  are free, so normal command-name invocations report a remote idle
  identity. Native hooks keep authority over task progress and
  completion, no remote dotfiles are changed, and returning to the
  shell clears remote agent contexts.
- **Completion handling** — an `end` after normal completion clears
  the agent identity and restores the underlying shell icon instead of
  leaving a stale completion badge; the Pi adapter arms a single
  completion per turn so repeated empty background snapshots cannot
  re-emit an acknowledged badge. Completion badges can be cleared by
  mouse click, scroll, or keyboard input on any visible surface of
  the owning terminal, without clearing other panes.
- **Screen detection tightened** — arbitrary redraws and quiet periods
  no longer imply task start or completion; only agent-specific status
  markers drive activity for agents without a separate status Hook.
- **Agent integration settings** — OMG status-extension (Hook) actions
  are separated from CLI version/update controls, installed extensions
  always expose a reinstall action, extension changes show a restart /
  Pi `/reload` notice, and an OMG upgrade inspects installed status
  extensions immediately regardless of the check interval without
  advancing the CLI deadline. Hook terminology is now "status
  extension" in both English and Chinese.
- **Editor** — fixed blank content while scrolling.
- **Menus and search** — restored standard Edit menu shortcuts and
  search field clipboard/editing shortcuts.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.15.0-macos-arm64.dmg` — Apple Silicon
- `OMG-0.15.0-macos-x86_64.dmg` — Intel (binary architecture verified;
  launch under Rosetta 2 not tested on the build machine)
- `OMG-0.15.0-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
