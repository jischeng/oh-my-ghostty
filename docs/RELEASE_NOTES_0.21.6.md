# OMG 0.21.6 · Ghostty 1.3.2-dev

OMG 0.21.6 is a macOS window compositing, Quick Input customization, and Workspace UI polish patch release on top of `v0.21.5`. It replaces private SkyLight window blur with a CoreAnimation behind-window blur backdrop to eliminate Mission Control multi-Space flashing and gray-out, adds adjustable frosted-glass opacity and tuned default sizing for Quick Input, and refines the Delete Workspace confirmation card and destructive native action button styling.

## Highlights

- **CoreAnimation behind-window blur eliminating Mission Control flashing & gray-out (`ghostty#9542`).** Replaces private SkyLight `CGSSetWindowBackgroundBlurRadius` across standard Terminal windows, Quick Terminal, and native surface containers with `TerminalBackdropBlurView` (`NSVisualEffectView` `.behindWindow`, `.hudWindow` dark / `.headerView` light, `state = .active`) while clearing any residual CGS blur radius to `0`, preventing macOS WindowServer multi-Space Mission Control compositing from washing translucent windows out to light gray or flickering when other fullscreen Spaces are open.
- **Adjustable Quick Input frosted-glass opacity (`70%` default) & `165pt` default composer height.** Adds `keyboard.quickInputOpacity` (`0.05`–`1.0`, default `0.7` / `70%`) with a `5%–100%` slider and **Default** reset action under **Settings → Input & Controls → Quick Input**, updates `keyboard.quickInputHeight` default from `148pt` to `165pt`, lightens the frosted-glass recipe (`.hudWindow` dark / `.selection` light) so terminal lines remain legible underneath, and applies opacity changes live across the floating composer, collapsed queue pill, queued message capsules, and history browser capsules.
- **Compact Delete Workspace confirmation card & destructive native action styling.** Resizes the Workspace Picker delete confirmation popover dynamically to fit its content instead of keeping a `500pt` blank panel, adds a header divider, rounded warning trash badge, and theme-synchronized secondary description, and introduces `NativeActionStyle.destructive` so **Delete Workspace** renders with high-contrast red fill, border, and label alongside a trailing-aligned **Cancel** button.
- **Local Git Inspector FSEvents flush deadlock fix.** Schedules `GitRepositoryChangeMonitor`'s `FSEventStream` on a dedicated serial background queue with generation-gated event suppression instead of `DispatchQueue.main`, preventing `FSEventStreamFlushSync` inside `acknowledgeRefresh()` from deadlocking the main thread during rapid index staging/unstaging in large local worktrees.

## Version and distribution

- OMG **0.21.6**, bundle version **61**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5` (unchanged from `v0.21.5`).
- Includes the changes since the published `v0.21.5` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  `omgd` relay, mobile support helper, and macOS (`arm64`, `x86_64`) and Linux
  (`x86_64`, `aarch64`) remote session runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.21.6-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.21.6-ios-unsigned.ipa`).

## Validation

- Routine change-selected static/contract checks (`swiftlint`, `zig fmt --check`,
  settings schema & `check_omg_docs.py`, `plutil`, `ibtool`, and `dist/test_omg_*.py`),
  all 12 routine app-hosted `GhosttyTests` modules (188 suites in retained Tart VM,
  0 isolated retries), iOS `mobile` gates (`ios/scripts/test.sh` and
  `ios/scripts/test-vm.sh` guest OMG Dev + iOS Simulator flow), `omgd version`
  local relay launch probe, and post-sign packaged artifact / DR continuity against
  `0.21.5` / `session-runtime` manifest SHA-256 / Sparkle EdDSA appcast / AltStore
  source checks recorded by `dist/macos/omg_release.py` (see
  `.release-build/0.21.6/release-summary.md`).
- **Not run**: Unchanged `session-runtime` Rust/SSH/Linux `systemd`/cgroup v2
  fault-injection suites (`test_containment_linux.py`, zero `session-runtime`
  changes since `v0.21.5`), optional `.interactiveDesktop` native drag/focus
  suites, XCUITest, host desktop FPS/latency measurements, full desktop TCC
  upgrade experiments, and `x86_64` launch execution (Rosetta 2 is absent on the
  arm64 build host; `x86_64` Mach-O slice, code signature, and `.ReleaseFast`
  marker verified).
