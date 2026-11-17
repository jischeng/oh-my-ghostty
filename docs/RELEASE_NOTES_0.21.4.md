# OMG 0.21.4 · Ghostty 1.3.2-dev

OMG 0.21.4 is a Quick Input floating glass UX, capsule stack popover, and terminal/split resize stability patch release on top of `v0.21.3`. It moves Agent Quick Input out of layout flow to eliminate `SIGWINCH` layout jitter, renders frosted in-window glass surfaces with exact theme-matched tinting, converts both Queue and History popups into unified staggered capsule stacks, and stabilizes terminal blank wipes and split surface geometry on resize.

## Highlights

- **Out-of-flow floating Quick Input composer & frosted-glass chrome.** Keeps Agent Quick Input floating above the terminal viewport so opening, closing, pinning, resizing (`keyboard.quickInputHeight` default `148pt`, range `96...480pt`), or queueing never shrinks `contentHost` or emits PTY `SIGWINCH`. Renders the composer and companion controls on live in-window backdrop blur (`NSVisualEffectView` `.withinWindow`) with renderer-quantized terminal theme tinting, single-layer `.evenOdd` cutout outer shadows (`QuickInputOuterShadowView`), point-accurate hit testing, and hover affordances across footer controls.
- **Unified Queue & History staggered capsule stacks.** Shows per-pane compact Queue toggle pills at the bottom-trailing corner of queued splits (`排队 N`) and aligns footer History and Queue switches so both expand upward into unified-width frosted-glass capsule stacks with CJK-aware width sizing (`displayColumnCount`) and smooth width expansion on `AgentQuickInputCollapsedQueuePill`. Unifies fan-out motion (`0ms / 16ms / 40ms / 64ms / 88ms / 112ms` visible-slot stagger with bottom scroll anchoring and unclipped spring travel), traps wheel/trackpad scrolling across `7pt` inter-capsule gaps without leaking to the terminal, snaps scroll stops cleanly (`.viewAligned` with non-elastic bounds and live-scroll hover suppression), preserves `↑`/`↓`/`↩`/`Esc` keyboard navigation, and auto-collapses popups on outside click or composer typing.
- **Post-resize blank-wipe coalescing & split surface geometry stabilization.** Coalesces two-phase primary-screen TUI post-resize `CSI H` + `CSI J` blank wipes in `StreamHandler` and `Termio` within bounded hold (`320ms` idle, `420ms` hard cap) and scroll-restore (`900ms`) windows so rapid split/window resizes preserve scrollback position and avoid blank flashes without freezing rendering. Initializes `SurfaceScrollView` and newly split `SurfaceView` instances directly at their target slot bounds and drops redundant initial `derivedConfig` replays to eliminate `0x0` and `800x600` geometry bounces.

## Version and distribution

- OMG **0.21.4**, bundle version **59**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5` (unchanged from `v0.21.3`).
- Includes the changes since the published `v0.21.3` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  `omgd` relay, mobile support helper, and macOS (`arm64`, `x86_64`) and Linux
  (`x86_64`, `aarch64`) remote session runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.21.4-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.21.4-ios-unsigned.ipa`).

## Validation

- Routine change-selected static/contract checks (`swiftlint`, `zig fmt --check`,
  settings schema & `check_omg_docs.py`, `plutil`, `ibtool`, and `dist/test_omg_*.py`),
  targeted Zig unit tests for changed `src/termio/` (`StreamHandler`, `Termio`,
  `Thread`), all 12 routine app-hosted `GhosttyTests` modules (188 suites in
  retained Tart VM), and post-sign packaged artifact / DR continuity against
  `0.21.3` / `session-runtime` manifest SHA-256 / Sparkle EdDSA appcast /
  AltStore source checks recorded by `dist/macos/omg_release.py` (see
  `.release-build/0.21.4/release-summary.md`).
- **Not run**: Rust/Python `session_runtime` test gate (not selected; no
  `session-runtime/` changes since `v0.21.3`, while bundled runtime binaries
  and post-sign manifests are still verified in packaged `.app`s), iOS
  `mobile_gate` (not selected; no mobile implementation or shared `libghostty-vt`
  dependency changed since `v0.21.3`), optional `.interactiveDesktop` native
  drag/focus suites, XCUITest, host desktop FPS/latency measurements, full
  desktop TCC upgrade experiments, live remote SSH / disposable Linux
  systemd-cgroup fault-injection acceptance (`test_containment_linux.py`), and
  `x86_64` launch execution (Rosetta 2 is absent on the arm64 build host;
  `x86_64` Mach-O slice, code signature, and `.ReleaseFast` marker verified).
