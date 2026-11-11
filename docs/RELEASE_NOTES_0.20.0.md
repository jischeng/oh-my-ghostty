# OMG 0.20.0 · Ghostty 1.3.2-dev

OMG 0.20.0 introduces **OMG Mobile** for iPhone and iPad alongside desktop
Mobile Access pairing, configurable new-tab and split session inheritance, a
Files Inspector action toolbar, structured Git History filters with match
highlighting, zero-flicker Quick Input / BubbleTea v2 resize handling, and
unified translucent glass and split-mask rendering. The Ghostty base is
unchanged.

## Highlights

- **OMG Mobile for iOS/iPadOS and desktop Mobile Access (`#37`).** Pair an iPhone
  or iPad with `omgd` over LAN, Tailscale, or an explicit `wss://` ingress via
  **Settings → Mobile Devices** or `omg +mobile`. Mobile and desktop share the
  same live PTYs, Ghostty VT snapshots, Agent activity / Needs You states,
  workspace tree cards, and remote SSH jump-host or standalone SSH server
  sessions, with seamless writer transfer and a background Session Library
  popover in the tab sidebar.
- **Prebuilt iOS release installers with one-shot Agent installation.** Each
  release now ships `OMG-Mobile-0.20.0-ios-installer.tar.gz` (prebuilt
  `libghostty-vt.a` + Xcode project + `install-to-iphone.sh`, requiring no Zig,
  Rust, or XcodeGen) and `OMG-Mobile-0.20.0-ios-unsigned.ipa` for sideloaders,
  plus a copy-paste Agent prompt in `README.md` / `README.zh-CN.md`.
- **Separate inheritance policies for new tabs and splits (`#42`).** Configure
  whether new tabs and splits start in the default directory, inherit the
  current working directory, reconnect to the current SSH host, or launch/resume
  an Agent independently.
- **Files Inspector toolbar (`#60`).** Quickly reveal the active editor or Git
  diff file in the workspace tree, create new files or folders inline, and
  collapse or expand directories.
- **Git History filters and match highlighting (`#61`).** Filter commit history
  by author, email, changed file path, commit message, or commit hash, with
  matched terms highlighted directly in History rows.
- **Zero-flicker Quick Input and TUI resize coalescing (`#64`).** Open Quick
  Input in place for `agy` without scrollback jumps, coalesce BubbleTea v2
  full-screen resize wipes, prevent translucent background snapshot flashes on
  `codex`, unify the remote draft bridge cover, and preserve CJK IME marked text
  attributes.
- **Translucent chrome, Liquid Glass, and split masks.** Unify sidebar and
  inspector glass compositing, quantize transparent titlebars to match Metal
  terminal colors, keep unfocused split borders crisp at 1px, and balance
  vertical tab row insets.
- **Session runtime upgrade continuity.** Preserve unconfirmed local session
  creation state across detaches and discover compatible sibling runtime
  revisions across app upgrades without snapshot mismatches.

## Version and distribution

- OMG **0.20.0**, bundle version **50**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`.
- Includes the changes since the published `v0.19.3` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.20.0-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.20.0-ios-unsigned.ipa`).

## Validation

- All **181 routine Swift suites** passed in the retained macOS test VM. Native
  `.interactiveDesktop` suites remained optional and were **not run**.
- Session runtime Rust checks passed **78 tests** (`cargo fmt --check`,
  `cargo clippy --all-targets -- -D warnings`, and `cargo test`).
- iOS native Swift checks passed **10 tests**, and unsigned `Release`
  `OMGMobile.app` (`arm64` `iphoneos`) compiled cleanly against ReleaseFast
  `libghostty-vt.a`.
- Targeted Zig checks for local session creation confirmation and BubbleTea v2
  resize coalescing passed. SwiftLint (603 files, 0 violations), Zig formatting,
  settings schema, documentation (`check_omg_docs.py`), plist, Interface
  Builder, test-selector (`51` tests), and signing/Keychain (`32` tests with `3`
  optional smoke skips) gates passed.
