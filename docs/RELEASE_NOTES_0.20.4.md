# OMG 0.20.4 · Ghostty 1.3.2-dev

OMG 0.20.4 is a small desktop bug-fix release. It stops the Git branch and
worktree browser from crashing on a duplicate-key fatal error when favorites are
shown above the regular sections, and refreshes the internal release tooling.
The Ghostty base and OMG Mobile are unchanged.

## Highlights

- **Favorites no longer crash the Git ref browser.** Starred branches and
  worktrees rendered in the Favorites section above the regular Branches, Remote
  Branches, and Worktrees sections while both copies still shared the raw
  `GitCollectionRow` id (for example `refs/heads/main`). Any later incremental
  table diff — opening the history branch picker, refreshing content, or typing
  in its search field — trapped in `Dictionary(uniqueKeysWithValues:)` on the
  duplicate key and aborted the app. Row ids are now scoped per section, so the
  same ref can appear in Favorites and its own section safely.
- **Internal release tooling.** `dist/macos/omg_release.py` now drives plan,
  prepare, gate, build, package, run, publish, and clean with SemVer and Ghostty
  base policy checks, atomic three-target version updates, parallel static gates,
  isolated `--skip-build` retries for flaky suites, and content-addressed
  GhosttyKit / `session-runtime` / iOS VT caches. It also builds one universal
  Release app and derives the single-architecture bundles with `lipo -thin`,
  compresses macOS DMGs concurrently, and narrows version-bump test selection so
  metadata-only edits no longer pull in the full foundation/mobile gates. This
  change is invisible to users but makes releases shorter and less repetitive.
- **No iOS reinstall needed.** OMG Mobile did not change in this release; the
  `OMG-Mobile-0.20.4` installer archives are attached for version parity on new
  installations only. Existing `0.20.3` iPhone/iPad installations stay fully
  compatible.

## Version and distribution

- OMG **0.20.4**, bundle version **54**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`
  (unchanged from `0.20.3`).
- Includes the changes since the published `v0.20.3` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.20.4-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.20.4-ios-unsigned.ipa`).

## Validation

- `omg_release.py gate` passed end-to-end on the release commit (703s total):
  parallel static gates (SwiftLint, settings schema, OMG documentation contract,
  plist, Interface Builder, test/mobile/release selector contracts, signing and
  Keychain contracts), the `session-runtime` cargo gates, the full routine Swift
  selection (**181 suites**, scope `all`, no isolated retries), and the mobile VM
  gate (3 UITests, all execution receipts true). Optional `.interactiveDesktop`
  native drag/focus suites, XCUITest, and full TCC upgrade experiments were
  **not run**.
- `omg_release.py build` produced the `arm64`, `x86_64`, and `universal` apps
  from one cached universal Release build and rebuilt the session runtime
  (`macos-aarch64`, `macos-x86_64`, `linux-x86_64`, `linux-aarch64`).
- `omg_release.py package` verified each signed app's signature and runtime
  bundle, launched the `arm64` and `universal` apps in `.ReleaseFast` mode from
  both the app and the mounted DMG, and skipped only the `x86_64` launch because
  Rosetta 2 is not installed on the build host (Mach-O architecture and
  signature were verified instead).
- Three defects in the new release orchestrator were found and fixed while
  running this release: the version-assertion rewrite aborting `prepare` on
  fixed sample versions, a macOS-only runtime bundle failing validation, and GNU
  `ar` from a login-shell PATH corrupting `libomg_vt.a` for ld64.
