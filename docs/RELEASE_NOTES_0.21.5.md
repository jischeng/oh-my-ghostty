# OMG 0.21.5 · Ghostty 1.3.2-dev

OMG 0.21.5 is an SSH terminal rendering, SSH Git Inspector performance, and session-runtime patch release on top of `v0.21.4`. It eliminates multi-second blank-screen flashes and continuous scrolling in inline TUIs over high-latency SSH links, speeds up SSH Git Inspector repository loading by reusing active inline `omgd` relays and collapsing sequential queries, provisions `xterm-ghostty` terminfo and initial terminal geometry/theme environment on remote hosts, and hardens DEC Mode 2026 frame integrity and backpressure in `session-runtime`.

## Highlights

- **Two-phase TUI blank-wipe holding & active DEC 2026 streaming renewal over SSH.** Holds synchronized rendering across non-resize two-phase primary-screen TUI full wipes (`CSI 2J` / `CSI 3J` inside DEC Mode 2026 leaving `<= 3` status rows) in `StreamHandler` (`TuiWipeHoldState`, `2.5s` safety cap) until Phase 2 scrollback content arrives, while immediately releasing ordinary shell `clear`/`Ctrl+L`, `OSC 133` prompts, `RIS`, and alt-screen transitions. Renews `sync_reset` in `250ms` increments (up to a `15s` active-stream cap) while bytes continue arriving inside an open `?2026h` frame so multi-megabyte TUI redraws over WAN SSH swap atomically instead of tearing at `1.0s` into multi-second scrolling, extends post-resize coalescing windows on remote SSH sessions (`1800ms` idle / `2400ms` hard cap / `3200ms` scroll restore), and pins primary-screen scrollback to the bottom on TUI full clears.
- **Fast SSH Git Inspector loading & inline `omgd` relay reuse.** Registers `SessionRuntimeInlineSession` `omgd` relay sockets (`activeInlineRelaySessions`) so terminal `ssh` sessions reuse their already-open `omgd` `exec-local` tunnel instead of dialing cold OpenSSH `ControlMaster` connections, eliminates per-command `remote/omg` Python startup and double `base64` shell wrapping in `SSHSessionTransport` and `SSHGitExecutor`, warms OpenSSH `ControlMaster` sockets with `Compression=yes` ahead of background `SSHHostRegistry` Python probes, and collapses repository detection, working-tree status, ref/decoration loading, and initial history snapshot creation from six sequential round-trips into two to three concurrent round-trips.
- **Remote `xterm-ghostty` terminfo provisioning, initial PTY geometry & SSH compression.** Embeds Ghostty's `xterm-ghostty` terminfo source into `omgd` and automatically compiles it on remote hosts via `tic -x` (refreshing stale entries lacking `Sync` and falling back cleanly to `xterm-256color`), negotiates `init-size/1` and `remote-env/1` on `OpenRequest` so remote PTYs spawn directly at the attached viewport geometry without an initial `80x24` `SIGWINCH` race while propagating `TERM`, `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `AGY_CLI_OSC7501=on`, and explicit surface theme colors (leaving unset themes transparent to viewer queries), and enables `-o Compression=yes` (plus `ServerAliveInterval=15` / `ServerAliveCountMax=3` on runtime transports) when the user has not explicitly configured SSH `Compression`.
- **`session-runtime` DEC 2026 coalescing, VT query responses & activity sync hardening.** Adds `6ms` / `256 KiB` `?2026h..l` frame coalescing and `512 KiB` / `128 KiB` PTY `POLLIN` backpressure hysteresis in `session-runtime` session actors, `12ms` / `256 KiB` stdout batching in `inline` viewers with ground-state `!in_sync` gating so injected `OSC 3008` metadata never splits synchronized frames and no-op resizes or alt-screen repaints never emit spurious scrollback newlines, wires `XTVERSION`, `DA1`/`DA2`, cell/pixel size (`14t`/`16t`/`18t`), and `CSI ?996n` color-scheme responses in `vt.c` with exact OSC query matching, and closes pending `omg-agent-sync` activity transactions cleanly.

## Version and distribution

- OMG **0.21.5**, bundle version **60**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5` (unchanged from `v0.21.4`).
- Includes the changes since the published `v0.21.4` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  `omgd` relay, mobile support helper, and macOS (`arm64`, `x86_64`) and Linux
  (`x86_64`, `aarch64`) remote session runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.21.5-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.21.5-ios-unsigned.ipa`).

## Validation

- Routine change-selected static/contract checks (`swiftlint`, `zig fmt --check`,
  settings schema & `check_omg_docs.py`, `plutil`, `ibtool`, and `dist/test_omg_*.py`),
  targeted Zig unit tests (`StreamHandler`, `Termio`, `Thread`, `cli/ssh`,
  `omg/session`), Rust & Python `session-runtime` gates (`cargo fmt`, `clippy`,
  `cargo test`, `session-runtime/tests`), all 12 routine app-hosted `GhosttyTests`
  modules (188 suites in retained Tart VM), iOS `mobile` gates (`ios/scripts/test.sh`
  and `ios/scripts/test-vm.sh` guest OMG Dev + iOS Simulator flow), packaged
  `omg +ssh` wrapper & `omgd version` probes, and post-sign packaged artifact /
  DR continuity against `0.21.4` / `session-runtime` manifest SHA-256 / Sparkle
  EdDSA appcast / AltStore source checks recorded by `dist/macos/omg_release.py`
  (see `.release-build/0.21.5/release-summary.md`).
- **Not run**: Environment-gated SSH and disposable Linux `systemd`/cgroup v2
  fault-injection tests (`test_containment_linux.py`) skipped by default Python
  discovery, optional `.interactiveDesktop` native drag/focus suites, XCUITest,
  host desktop FPS/latency measurements, full desktop TCC upgrade experiments,
  and `x86_64` launch execution (Rosetta 2 is absent on the arm64 build host;
  `x86_64` Mach-O slice, code signature, and `.ReleaseFast` marker verified).
