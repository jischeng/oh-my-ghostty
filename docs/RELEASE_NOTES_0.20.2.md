# OMG 0.20.2 · Ghostty 1.3.2-dev

OMG 0.20.2 is a cross-platform patch release for the desktop app and **OMG
Mobile**. It syncs Agent turn acknowledgements and live SSH sessions between
desktop and iPhone/iPad, isolates the mobile gateway port per app channel and
reaps orphaned gateways, restores link hover and Command-click after split
zoom, opens terminal `file:line`/range links at the requested target, adds a
macOS alert tone picker for Agent notifications, and keeps Git branch
favorites across upgrades and SSH working-directory changes. The Ghostty base
is unchanged.

## Highlights

- **Agent acknowledgements now sync to mobile.** A completed Agent turn that is
  acknowledged on the desktop or on the phone is recorded in `omgd`'s retained
  activity state instead of being replayed as "done" after an OMG restart or a
  new OMG Mobile connection. Adds an explicit activity acknowledgement frame
  across `omgd`, inline SSH clients, `SessionBackend`, macOS
  `SurfaceView`/`TerminalController`, and OMG Mobile's
  `CompanionControl`/`RuntimeConnection` paths, buffers pre-observer context
  signals on restored macOS surfaces, and preserves PID-scoped hook records and
  reducer acknowledgements across local foreground polling.
- **Live desktop SSH sessions on the phone.** Active desktop SSH sessions —
  both inline SSH tabs and direct `omgd connect` relay sockets — are projected
  into OMG Mobile folder projects with live remote host and working-directory
  metadata, so they appear directly in the app and can be attached from the
  iPhone/iPad. Inline SSH relays whose holder predates the activity control
  query, or wrote hook configs larger than 64 KB, no longer fall back to local
  shell metadata; the relay config limit is now 512 KB.
- **Channel-isolated mobile gateway.** Release OMG, OMG Dev, Dev Workspace, and
  Dev PTY no longer contend for port `8791`. Each channel gets its own default
  port (`8791`/`8792`/`8793`/`8794`), `omgd` is launched with `mobile serve` so
  `mobile-gateway.lock` tracks live ownership, orphaned gateways are stopped
  before a new child starts, and immediate startup failures hold briefly so the
  Settings toggle no longer flashes and snaps back mid-click.
- **Link hover and Command-click after split zoom.** Toggling split zoom
  remounted the active `SurfaceScrollView` and lost `firstResponder`,
  `mouseOverSurface`, and the AppKit click hint, which swallowed the first
  Command-click as a focus-only click. Responder ownership, tracking areas, and
  live pointer coordinates are resynchronized after remounts, and pure
  Command-clicks on hovered links are forwarded instead of swallowed.
- **Terminal line and range links open at their target.** OMG path detection
  now recognizes `:start-end`, `:start:col-end:col`, and `#Lstart-Lend`
  suffixes, and the native editor parses line/column/range locations across
  path and `file://` forms, switches Markdown documents to source mode, and
  selects and scrolls the target line or clamped range into view.
- **Agent notification tone picker.** New `notifications.soundTone` setting
  backed by `AgentNotificationSoundTone` (default plus macOS
  `/System/Library/Sounds/*.aiff` tones), a localized Sound Tone popup with live
  preview under Agent settings and search, and custom tones played via
  `NSSound` on the main actor when notification audio is permitted.
- **Git branch favorites survive upgrades and SSH cwds.** Legacy favorites
  written with NUL separators are migrated again, SSH repository keys normalize
  to destination plus SSH options instead of the full `GitSSHConnection`
  identity, and legacy/v2 entries pointing at the same remote repository are
  coalesced.
- **iOS cloud badges and project order.** Remote SSH sessions and SSH projects
  on iOS now render cloud symbols instead of local terminal/folder icons, and
  saved workspace order is preserved ahead of remote-only SSH session
  containers.

## Version and distribution

- OMG **0.20.2**, bundle version **52**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`
  (unchanged from `0.20.1`).
- Includes the changes since the published `v0.20.1` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.20.2-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.20.2-ios-unsigned.ipa`). **OMG Mobile
  changed in this release** (Agent acknowledgement sync, mobile gateway ports,
  inline SSH relays, cloud icons), so `0.20.1` iPhone/iPad installations should
  update to `0.20.2`.

## Validation

- Change-selected Swift suites for all commits since `v0.20.1` passed: **1532
  tests in 181 suites** (shared host/core, terminal, settings, editor, git,
  plugins, agents, and ssh paths selected the conservative full routine sweep).
  Optional `.interactiveDesktop` native drag/focus suites, XCUITest, and full
  TCC upgrade experiments were **not run**.
- `session-runtime` gates passed: `cargo fmt --check`, `cargo clippy
  --all-targets -D warnings`, `cargo test` (81 tests), `cargo build`, and the
  Python runtime suite (35 tests, 4 environment-dependent SSH/Linux containment
  skips).
- Targeted Zig tests for the affected `omg_link_check`, `omg_path`,
  `SessionBackend`, and `termio/backend` paths passed (109 tests).
- OMG Mobile gates passed: iOS native core Swift checks and the Simulator UI
  flow through the retained VM harness (3 UITests, all execution receipts true:
  mobile executed, Mac GUI reclaimed, mobile reconnected, same PID/generation,
  create/close, file edit).
- Static gates passed: SwiftLint (0 violations in 603 files), Zig formatting,
  settings schema, OMG documentation contract, plist, Interface Builder, test
  selector (46 tests), and signing/Keychain contracts (17 + 15 tests).
- Signed `arm64` and `universal` release apps launched cleanly in `.ReleaseFast`
  mode, satisfied their designated requirement (self-signed, pinned
  certificate), and their DMGs mounted and launched from the mounted volume. The
  `x86_64` app and DMG were verified for Mach-O architecture, signature, and
  `.ReleaseFast` markers without launching because Rosetta 2 is not installed on
  the build host.
- Post-sign runtime verification passed for all three apps: `omgd`
  `omg-session-runtime/2` / `snapshot/1` manifests with matching revisions,
  universal `omgd` relay launching `omgd version`, and both Linux `x86_64` and
  `aarch64` ELF artifacts present.
