# Workspace deletion and closed-window switching — 2026-10-30

Baseline e465af792. User requests current workspace cannot be deleted, Personal
can be deleted, and reports close restored Personal window → switch to Personal
from another window → hang, then fullscreen appears to crash.

Changes:
- Picker disables trash for the invoking window's current workspace, not Personal.
- beginDelete, confirmDelete and coordinator execution all validate current
  identity. The coordinator accepts an explicit source controller so popover
  focus changes cannot change the protected workspace.
- Personal/default can be deleted; the invoking current workspace is the explicit
  migration destination. The state/store reject removing the last workspace.
- Park native singleton windows with orderOut without removeWindow. Removing the
  final member can leave an empty NSWindowStackController, which is unsafe to
  reuse on later fullscreen entry. Multi-member groups still detach outgoing tabs.

Verification:
- 55 tests in 4 workspace suites passed (`deletion-current.log`).
- New tests assert current deletion is a no-op at execution, inactive Personal
  deletion preserves the active terminal and valid ownership, and closing an
  independent Personal window then switching from another host creates a distinct
  live controller without claiming the closed host's records.
- A new desktop test persists/restores two windows, closes Personal, switches
  the other host to Personal and sends actual Control-Command-F. It was blocked
  before fullscreen at active/key preconditions; CGSession confirmed screen locked.
  This is NOT a successful fullscreen/crash verification.
- No OMG crash report was found in ~/Library/Logs/DiagnosticReports during the
  bounded lookup. The user's exact crash cause remains unproven; the native stack
  change addresses a concrete unsafe lifecycle operation, not a verified crash stack.

Logs: /tmp/omg-workspace-management-4vqzF4/deletion-current.log and
close-personal-fullscreen.log. No user workspace data changed. Not installed or
committed. Re-run TerminalWorkspaceManagementDesktopTests/
closePersonalWindowThenSwitchAndEnterFullscreen() with --include-desktop-tests
on an unlocked foreground desktop.
