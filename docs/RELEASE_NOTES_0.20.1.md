# OMG 0.20.1 · Ghostty 1.3.2-dev

OMG 0.20.1 is a desktop stability and Agent status patch release. It eliminates
scrollback jumps and full-screen reprints during large-session `agy` (BubbleTea
v2) splits, Quick Input toggles, and inspector resizes, restores local macOS
`agy` sidebar status badges, and preserves cleared Agent completion badges
across app restarts. The Ghostty base, `session-runtime` (`omgd`), and
**OMG Mobile** for iOS/iPadOS are unchanged.

## Highlights

- **Steady viewport and coalesced resize reprints for large `agy` sessions.**
  Extend primary-screen BubbleTea v2 resize wipe coalescing across multi-second
  reprints and rapid back-to-back layout changes (splits, Quick Input open/close,
  and sidebar/inspector drags), suppress premature viewport auto-scroll while a
  coalesced resize frame is still streaming, and cleanly recover from truncated
  `ESC [ ? 2026 h` synchronized-output frames without jumping to the bottom of
  scrollback.
- **Reliable local macOS `agy` status detection.** Resolve a real local Python 3
  interpreter instead of Apple's `/usr/bin/python3` CLT stub when running local
  Antigravity hooks, strip inherited `SDKROOT` overrides, answer `CSI > 0 q`
  (`XTVERSION`) queries directly on `omgd`-backed local sessions, and inspect
  the descendant process tree of local `omgd` shells so `agy` is recognized
  immediately in the tab sidebar.
- **Persist cleared Agent completion badges across restarts.** Record
  acknowledged `completed` / `idle` Agent timestamps in workspace session state
  so reopening OMG (including reconnecting to remote SSH sessions) does not
  re-badge already-cleared tabs as unread completions, while genuinely new
  completions still surface normally.
- **No iOS reinstall needed for `0.20.0` OMG Mobile users.** `OMG-Mobile-0.20.1`
  installer archives are attached for version parity on new installations, but
  existing `0.20.0` iPhone/iPad installations remain 100% compatible with OMG
  `0.20.1` and do not need to be updated.

## Version and distribution

- OMG **0.20.1**, bundle version **51**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`.
- Includes the changes since the published `v0.20.0` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.20.1-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.20.1-ios-unsigned.ipa`). Users already
  running OMG Mobile `0.20.0` do not need to reinstall.

## Validation

- Targeted Swift regression suites covering all modified areas (`118` tests across
  `AgentLocalPythonInterpreterTests`, `AgentIntegrationManagerTests`,
  `AgentProgramStatusTests`, `AgentStatusPluginTests`,
  `SessionRuntimeInlineSessionTests`, `SessionRuntimeQuitTests`, and
  `TerminalRestorableTests`) passed in the retained macOS test VM. The full
  routine Swift sweep, optional `.interactiveDesktop` suites, and manual TCC
  upgrade experiments were **not run**.
- Targeted Zig `stream_handler` resize coalescing tests (`78` tests) and
  `GhosttyKit.xcframework` ReleaseFast builds passed.
- iOS native Swift core checks (`ios/scripts/test.sh`, `12` tests across
  `OMGTerminalTests` and `OMGMobileCoreTests`) passed, and unsigned `Release`
  `OMGMobile.app` (`arm64` `iphoneos`) packaged cleanly.
- Signed `arm64` and `universal` release apps launched cleanly in `.ReleaseFast`
  mode and matched the pinned certificate / designated requirement of `v0.20.0`;
  the `x86_64` build was verified for Mach-O architecture, signature, and
  `.ReleaseFast` markers without launching (Rosetta 2 is not installed on the
  build host).
- SwiftLint (0 violations), Zig formatting, settings schema, documentation
  (`check_omg_docs.py`), plist, Interface Builder, test-selector (`46` tests),
  and signing/Keychain (`32` tests with `3` optional smoke skips) gates passed.
