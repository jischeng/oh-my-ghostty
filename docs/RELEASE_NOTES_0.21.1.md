# OMG 0.21.1 · Ghostty 1.3.2-dev

OMG 0.21.1 is a stability, runtime, and mobile patch release on top of `v0.21.0`. It eliminates idle polling and snapshot retry CPU spin loops in `omgd`, adds post-reboot paused local session resurrection across macOS and iOS, unifies agent status fences, hardens editor LSP trust boundaries and SSH SFTP quoting, and automates 1-click iOS companion provisioning.

## Highlights

- **Event-driven `omgd` runtime & zero-idle CPU fixes.** Replaces idle polling with event-driven `poll` loops, eliminates a 0ms `poll` CPU spin loop on VT snapshot persistence failures via exponential backoff, drops global `Mutex<Registry>` locks across holder probes/spawns with per-session inflight guards, and ensures `session-holder` / `host-local` test and lifecycle cleanup leaves zero orphan daemons.
- **Post-reboot local session resurrection & channel isolation.** Preserves interrupted local sessions across reboots (`ended: "lost"`), surfaces and resumes them from macOS (`SessionRuntimeLibrary` / `SessionRuntimeOverview`), CLI, and OMG Mobile, preserves monotonic snapshot revisions, and isolates `~/.omg/run/*` roots per `app_support` channel.
- **Unified agent status engine & login-shell fences.** Unifies agent reporting, hard prompt/process-group fences (`OSC 133` + login-shell child resolution), 8-byte watermarked `ACKNOWLEDGE` frames across `omgd`, `SessionBackend.zig`, and mobile control, and Hermes TTY ownership isolation.
- **macOS Editor, LSP, SSH & Doctor hardening.** Fixes out-of-tree LSP trust inheritance and broad ancestor prefix poisoning, fixes SFTP `glob(7)` quoting for bracketed routes (`[slug]`), prevents hidden workbench reclaim/uncollapse races and `WKWebView` / `O_EVTONLY` leaks, moves `OMGDoctorService` signer/disk probes off `@MainActor`, and fixes Quick Terminal / Doctor `"ended"` status parsing.
- **OMG Mobile & 1-click iOS provisioning.** Adds in-app / 1-click iOS provisioning (`MobileDeviceProvisioner`), paused session resume on iOS, passive-viewer isolation, keyboard/IME redraw stability, deferred `WebSocketLink` backoff, background `CADisplayLink` pausing, and swipe-action reload gating.
- **Terminal resize & reflow.** Eliminates terminal resize freezes and quick-input reflow feedback loops.

## Version and distribution

- OMG **0.21.1**, bundle version **56**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5` (unchanged from `0.21.0`).
- Includes the changes since the published `v0.21.0` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.21.1-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.21.1-ios-unsigned.ipa`).

## Validation

- Routine change-selected quality gates and packaged artifact checks recorded by
  `dist/macos/omg_release.py` (see `.release-build/0.21.1/release-summary.md`).
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, and full TCC
  upgrade experiments were **not run** unless explicitly noted above.
