# Restored fullscreen keyboard switching — 2026-10-30

Baseline: `9452e3a7a`; installed OMG Dev reports matching development version.
User reports restart → fullscreen → keyboard workspace switch leaves the previous
picture until exiting fullscreen. Also requests inline edit/delete icons.

## Investigation and changes

- Added a desktop test that creates a multi-tab destination, writes a temporary
  checkpoint, destroys controllers, restores the checkpoint, enters/restores
  native and non-native fullscreen, sends actual Control-Command digit events,
  and checks selection, visible/key window, sidebar host and repeated switches.
- Plain restore followed by manual fullscreen passed. Automatic fullscreen restore
  showed intermittent key-window failures before changes; later diagnostic runs
  also passed. **The persistent frozen-picture symptom has not been reliably
  reproduced. These observations do not establish its complete root cause.**
- Found an unversioned delayed restoration `toggleFullscreen`: it checked only
  native styleMask, so an intervening user-entered non-native fullscreen could
  be toggled out, or obsolete restore work could act after a workspace command.
  It now checks presentation generation, committed current workspace and both
  native/non-native fullscreen state before entering the saved mode.
- Native didEnter/didExit notification handlers no longer synchronously execute
  pending workspace commands while AppKit is unwinding its fullscreen stack.
  They drain on the next main-queue turn after verifying transitions have ended.
- A deferred workspace switch resolves the committed selected tab, instead of
  choosing an arbitrary controller from a registry dictionary.
- Replaced row … menu with separate pencil/trash buttons next to shortcut hints.
  Both have bounded hit targets, hover background and help/accessibility text;
  trash turns red on hover and is disabled for the default workspace. Delete
  confirmation and explicit row target remain unchanged.

## Verification

- `restored-final.log`: native and nonNative restored-fullscreen keyboard paths
  both passed, including eight repeated switches with a multi-tab destination.
- Added routine assertion that fullscreen completion callbacks do not reenter
  synchronous native notification delivery.
- `restored-routine-final.log`: 59 tests / 5 suites, one borderless exit regroup assertion failed in the combined run; the same test passed in isolation (`restored-borderless-check.log`). This timing-sensitive failure remains recorded, not waived.
- `restore-guard-tests.log`: 11 management tests passed, including user-entered non-native fullscreen winning over a queued restoration task, and asynchronous native transition completion.
- SwiftLint strict, documentation contract and whitespace checks passed.
- Logs: `/tmp/omg-workspace-management-4vqzF4/`.

User clarified fullscreen is entered with Control-Command-F. Source confirms this
is Ghostty's default alternate `toggle_fullscreen` binding (Command-Return is
also bound), defaulting to native fullscreen. No shortcut configuration was
changed. `actual-fullscreen-shortcut.log` passed the restored multi-tab test with
real Control-Command-F followed by Control-Command digit events (both mode cases,
10.694 seconds). This still does not reproduce the persistent old-picture stall.

## Personal header fallback and row controls follow-up

The workspace header previously called `store.workspace(id)`, which substitutes
Personal for unknown IDs. Incoming windows for atomic creation exist before the
catalog commit. The header now resolves the coordinator's current transaction
and uses a neutral label for an invalid ID. Incoming controller layout is bound
before showing. A proposed early native-group association/snapshot update was
removed after a combined desktop run hit AppKit NSWindowStackController assertions;
the original commit boundary for native associations is retained. That run was
interrupted and is not a successful visual verification.

New is now a compact rounded button with explicit hover/pressed states. Inline
pencil/trash controls are present in the rendered screenshot at
`/tmp/omg-workspace-management-switcher.png`. Installed Dev remains 9452e3a7 and
does not include these uncommitted controls. `personal-handoff.log` had 53 passing
targeted tests before removing the early association change; final targeted
verification is recorded in `personal-final-routine.log`.

Not installed or committed. The user-reported persistent visual stall remains
an evidence gap; do not describe the above hardening as proof that every occurrence
is fixed. No user sessions/catalogs were modified during tests.
