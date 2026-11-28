# OMG 0.25.4 · Ghostty 1.4.1-dev

OMG 0.25.4 preserves inline `omg +ssh` scrollback across long disconnects, enables in-pane recreation of lost remote SSH sessions after host reboots or container rebuilds, and automatically renames resumed remote SSH `agy` tabs before the first prompt.

## Highlights

### Inline SSH Scrollback Preservation Across Disconnects (#91)

- **Single-pass history and viewport replay.** Inline `omg +ssh` viewers now format retained remote history and active viewport rows together in a single VT pass (capped at 10,000 rows / ~2 MiB), emitting tabstops before text and restoring terminal modes, scrolling regions, cursor position, and styles afterward so reconnects push deltas into outer scrollback instead of overwriting with `\x1b[H`.
- **Tail-anchor delta tracking & pre-repaint resize sync.** Temporarily expands inline viewer scrollback to 4 MiB during snapshot restore to preserve local prefixes even when cursor visibility is hidden in inline TUIs, defers repaint until writer readiness so pending terminal resizes reflow tracked rows first, and flushes buffered output in 64 KiB chunks.
- **Faster dead-peer stall convergence.** Reaps zero-drain backpressured peers after 2 seconds on the remote daemon and closes stalled downstream host connections after 15 seconds of silence so remote PTYs and inline query replies recover promptly.

### In-Pane Remote SSH Session Recreation (#89)

- **Explicit `session_gone` recovery with one-shot `recreate/1` grant.** Missing or ended remote sessions after host reboots or container rebuilds are now classified as `session_gone` without background auto-creation. A one-shot 60-second `recreate/1` local control grant (`RecreateGrant`) is accepted on both dedicated control sockets and active peer streams across idle relay restarts, checking whether the remote agent resume store still exists so host reboots resume surviving agent conversations while rebuilt containers start a clean shell in the last working directory.
- **Direct `SessionBackend` & inline `omg +ssh` recovery UX.** Exposes `sessionGone` in `SessionBackend` and Swift recovery banners with a localized **Recreate Session** action that preserves split trees, `SurfaceView` instances, and title overrides. Inline `omg +ssh` viewers hold on `session_gone`, reset outer mouse/focus reporting, persist validated `0600` `active.json` state with `OSC 3008` wakeups, accept both GUI control-socket `recreate/1` and terminal `Enter` / `Ctrl+C` (ignoring escape sequences), and keep pre-reboot output in outer scrollback.
- **SSH recovery banner fallback fixes.** Repaired `SSHRecoveryBanner` fallback detection so plain SSH and inline `+ssh` panes reliably surface recovery actions when a session ends.

### Auto-Rename Resumed Remote SSH `agy` Tabs (#90)

- **Immediate remote conversation discovery with multi-pane disambiguation.** Automatically discovers and binds active remote `agy` conversations across inline `omg +ssh`, direct `SessionBackend`, and plain OpenSSH panes as soon as `OSC 7501` or session readiness signals an active agent. Resolves each pane to its exact remote TTY and foreground process group leader, prioritizing live per-conversation presence lock file descriptors, explicit CLI resume flags, and open brain directory handles over workspace summary timestamps so sibling tabs sharing one remote host and directory do not collide.
- **End-to-end remote transcript loading for single-tab & workspace batch auto-rename.** Routes remote history and title-seed reads through `SSHSessionTransport` across active and detached workspace controllers, walking parent conversation hops to the root conversation and decoding opening user prompts from read-only SQLite trajectories or brain transcripts before the first new prompt is sent.

## Version and distribution

- OMG **0.25.4**, bundle version **73**.
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.25.3`).
- Includes the changes since the published `v0.25.3` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.25.4-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.25.4-ios-unsigned.ipa`).

## Validation

- Routine change-selected quality gates (static/contract checks, `session-runtime` Rust and Python suites, 32 selected Zig tests across 2 changed files, 221 Swift suites with 0 isolated retries, and 3 iOS mobile checks including guest OMG Dev + iOS Simulator UI) and packaged artifact checks recorded by
  `dist/macos/omg_release.py` (see `.release-build/0.25.4/release-summary.md`).
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, full TCC or
  Sparkle UI upgrade experiments, Rosetta `x86_64` execution, and live remote
  Linux host containment checks were **not run** unless explicitly noted above.
