# OMG 0.21.2 · Ghostty 1.3.2-dev

OMG 0.21.2 is a stability, session-persistence, and QuickInput UX patch release on top of `v0.21.1`. It adds a one-time release-upgrade session cutover with stable local runtime namespaces, eliminates mid-session heartbeat timeout drops while auto-respawning exited relays, makes the `QuickInput` dock always in-flow without occluding terminal bottom lines, and hardens iOS companion provisioning and VM fixture alignment.

## Highlights

- **Release upgrade session cutover & stable local runtime identity.** Adds a one-time Epoch-2 upgrade cutover (`SessionRuntimeUpgradeCutover`) that cleans legacy `~/.omg/run/*` local daemons during upgrades while preserving window, tab, and split layouts, working directories, titles, colors, and Agent/SSH descriptors via `recreate-if-gone/1`. Stabilizes the per-channel local state directory (`omg-local-v2`) across macOS, Rust `omgd`, and mobile tooling, and scopes the `snapshot-revision` digest strictly to `src/terminal/snapshot/` wire-format files.
- **Mid-session local & SSH connection stability.** Refreshes relay heartbeat liveness (`last_pong`) on every incoming remote frame to prevent false `45s` `HEARTBEAT_TIMEOUT` drops during heavy streaming output, extends idle relay retention to `1 hour` while the parent GUI process remains alive, auto-respawns exited relays on attachment resume and retryable reconnects, and reports transient auto-reconnects as `0.4s`-debounced `reconnecting` state instead of flashing immediate failure banners. Adds `bootstrap.lock` single-flight daemon startup, expands relay/host stream capacity (`512` streams, `64 MiB` queue, stream backpressure, host frame heartbeat refresh), and relaxes SSH keepalive defaults to `ConnectTimeout=15`, `ServerAliveInterval=15`, `ServerAliveCountMax=3` (`45s` tolerance).
- **Always-in-flow `QuickInput` dock & terminal bottom visibility.** Removes the unpinned floating overlay path in `AgentQuickInputDockContainer` so `QuickInput` always docks below the terminal scroll view without occluding bottom status bars or trailing output lines; restores pinning strictly to keep-open-after-send retention; sets a compact `148pt` default height (`min 96pt`) synced bidirectionally with Settings; clamps `SurfaceScrollView` padding non-negatively after core surface geometry sync; and improves IME marked-text handling, undo grouping across history navigation, cross-pane queue editing, and `$EDITOR` / single-line send responsiveness.
- **Mobile provisioning & VM fixture alignment.** Drops the incompatible `-derivedDataPath` flag on `StubApp` target builds (using `SYMROOT` and `OBJROOT`) in `ios/scripts/install-to-iphone.sh` and `MobileDeviceProvisioner`, and aligns `ios/scripts/vm-fixture.py` local runtime namespaces with `omg-local-v2`.

## Version and distribution

- OMG **0.21.2**, bundle version **57**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5` (unchanged from `0.21.1`).
- Includes the changes since the published `v0.21.1` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  `omgd` relay, mobile support helper, and macOS (`arm64`, `x86_64`) and Linux
  (`x86_64`, `aarch64`) remote session runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.21.2-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.21.2-ios-unsigned.ipa`).

## Validation

- Routine change-selected static checks, Rust `session-runtime` tests/clippy/Python
  discovery suite, app-hosted `GhosttyTests` (retained Tart VM), iOS
  (`native-core` and `vm-simulator-ui`), and post-sign packaged artifact / DR
  continuity / manifest hash checks recorded by `dist/macos/omg_release.py`
  (see `.release-build/0.21.2/release-summary.md`).
- **Not run**: optional `.interactiveDesktop` native drag/focus suites, XCUITest,
  full desktop TCC upgrade experiments, live remote SSH / disposable Linux
  systemd-cgroup fault-injection acceptance (`test_containment_linux.py`), and
  `x86_64` launch execution (Rosetta 2 is absent on the arm64 build host;
  `x86_64` Mach-O slice, code signature, and `.ReleaseFast` marker verified).
