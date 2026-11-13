# OMG 0.21.0 · Ghostty 1.3.2-dev

OMG 0.21.0 overhauls the built-in code editor onto a pooled offline Monaco +
`@pierre/highlights` workbench with LSP and workspace symbol intelligence,
rebuilds Git Diff onto a pooled ThinkRail-style `@pierre/diffs` surface,
replaces the Markdown preview renderer for fluid translucent layout, supports
spaced file path links in the terminal, and hardens session restore geometry and
macOS TCC attribution. The Ghostty base and OMG Mobile are unchanged.

## Highlights

- **Monaco + `@pierre/highlights` + LSP code editor overhaul.** Replaces
  `CodeEditSourceEditor` and `CodeEditTextView` with an offline-bundled, pooled
  single-WebView `MonacoWorkbenchView` over OMG's native vibrancy
  `EditorBackdrop` — lazy-allocated with zero background `WKWebView`s when idle
  and a 5-minute empty reaper. Adds `@pierre/highlights` WASM/SIMD incremental
  syntax highlighting, zero-process `EditorSymbolIndex` (`⌘⇧O` document symbol
  outline, cross-file Go to Definition, and workspace completions), on-demand
  `$PATH` `EditorLSPManager` (5-minute idle reaper and strict SSH remote
  workspace isolation), atomic-rename-safe `EditorFileWatcher` with conflict
  banners, live `EditorGitGutterService` line indicators, recursive fuzzy
  `EditorFilePicker` (`⌘P` / `⌘O`), and inline **Ask Agent** (`⌘⇧L` / `⌘⇧I`)
  wired directly to terminal `QuickInput`.
- **ThinkRail-inspired `@pierre/diffs` Git Diff overhaul.** Unifies workspace
  and commit-history Git diffs onto a pooled single-WebView `GitEditorDiffView`
  with lazy allocation, a 5-minute empty reaper, AppKit visibility-aware surface
  re-attachment, and concurrent `async let` Git file, patch, and source-snapshot
  loading. Supports live zero-flicker `Review` (collapsible unchanged context
  with interactive hunk expansion) and `Full Source` modes, `Side by Side` and
  `Inline` layouts, horizontal scroll clipping at the sticky gutter edge and
  split-pane center dividers over translucent glass, calibrated addition and
  deletion tints, inline **Ask Agent** from diff lines, and column-zero
  metadata-only `isBinaryDiff` detection so text diffs mentioning binary patch
  headers render in the interactive diff surface.
- **Fluid Markdown preview and refined editor chrome.** Replaces the fixed-width
  CodeMirror preview layer with an offline-sanitized `markdown-it` +
  Highlight.js + KaTeX + Mermaid + DOMPurify document renderer that stays
  transparent over the shared `EditorBackdrop` and remains mounted across
  instant Edit/Preview switches to preserve scroll position. Adds responsive
  CJK-safe table wrappers, clickable `file://#L` and Codex `path:line` capsules
  across local and SSH workspaces, `<proposed_plan>` wrapper unwrapping, bare
  LaTeX `\begin{...}...\end{...}` math blocks, code-card copy headers,
  interactive carousel slides, single-character task-list toggles, Material file
  icons, elevated active tab cards, and hover tooltips in the editor bar.
- **Terminal spaced-path links, restored session geometry/cwd, and unified macOS
  TCC attribution.** Supports `⌘`-hover and `⌘`-click on unquoted and
  backtick-wrapped paths containing spaces on macOS while falling back to
  shorter existing path tokens when a spaced candidate does not exist on disk.
  Seeds `Screen.omg_cwd_history` when restoring session snapshots so relative
  file links work after app restarts, applies saved window frames before the
  default `80×24` initialization and gates initial `SessionBackend` resizes so
  restarts do not inject blank rows into restored prompts, and launches
  persistent local `omgd` hosts via `+internal-runtime-host` under unique
  per-spawn `launchd` labels (`<bundle_id>.host.<nonce>`) with
  `AssociatedBundleIdentifiers` so shell children inherit OMG's TCC attribution
  without terminating concurrent cold-boot restores.
- **Narrowed mobile test selector and no iOS reinstall needed.** Narrows
  `dist/omg_mobile_test_plan.py` so desktop-only `SessionBackend` and non-mobile
  `omgd` runtime edits no longer trigger iOS Simulator/VM acceptance runs. OMG
  Mobile did not change in this release; the `OMG-Mobile-0.21.0` installer
  archives are attached for version parity on new installations while existing
  `0.20.3` and `0.20.4` iPhone/iPad installations remain compatible.

## Version and distribution

- OMG **0.21.0**, bundle version **55**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`
  (unchanged from `0.20.4`).
- Includes the changes since the published `v0.20.4` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**
  (preserving designated-requirement continuity with `0.20.4`). macOS Gatekeeper
  may block the first launch, and migrating from older ad-hoc builds can prompt
  once for folder permissions; users who trust the download can review and allow
  it in **System Settings → Privacy & Security**. Do not disable Gatekeeper
  globally. Sparkle updates retain their separate EdDSA signature on the
  universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle
  `Contents/Resources/session-runtime`, containing the universal local `omgd`
  relay, mobile support helper, macOS (`aarch64`, `x86_64`) and Linux (`x86_64`,
  `aarch64`) remote session runtime artifacts, manifests, and `askpass`. Remote
  `omgd` deployments remain version-isolated and preserve live remote daemons
  and pinned sessions; older hosts without `durable-close/1` retain existing
  pending-close compatibility limits.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via
  `OMG-Mobile-0.21.0-ios-installer.tar.gz`, or via a sideloader using
  `OMG-Mobile-0.21.0-ios-unsigned.ipa`).

## Validation

- `omg_release.py gate` passed end-to-end (`543s` total): all 11 parallel static
  gates (SwiftLint with 0 violations, Zig formatting, settings schema, OMG
  documentation contract, plist, Interface Builder, test/mobile/release selector
  contracts, and signing/Keychain contracts), the `session-runtime` gates (`83`
  Rust `cargo` tests plus `35` Python runtime tests with `4`
  environment-dependent SSH/Linux containment skips), and the full routine Swift
  selection (**182 suites**, scope `all`, **0 isolated retries**) in the
  retained macOS test VM. Mobile gates were **not selected** because no mobile
  implementation or shared `libghostty-vt` dependency changed.
- Targeted offline bundle and core checks passed: `dist/code-editor` (`22/22`
  tests), Markdown preview (`dist/tests/markdown_preview.cjs`), and targeted Zig
  tests across `OMG ` path-link and `SessionBackend` restore/resize filters.
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, full TCC
  upgrade experiments, and live remote SSH / disposable Linux cgroup containment
  fault-injection runs were **not run**.
- `omg_release.py build` compiled the universal ReleaseFast `GhosttyKit` core,
  built the `universal` Release app and derived `arm64` and `x86_64` bundles,
  and built the bundled `session-runtime` (`revision` `0bfcbbb3ed9a4d1e9e2b`,
  `snapshot-revision` `59c5cc7b4d1fe408faf5` across `macos-aarch64`,
  `macos-x86_64`, `linux-x86_64`, and `linux-aarch64`).
- `omg_release.py package` verified persistent certificate designated
  requirements (matching `0.20.4`) and post-sign `session-runtime` manifests
  across all three apps and mounted DMGs, launched the `arm64` and `universal`
  apps in `.ReleaseFast` mode from both the app bundle and the mounted DMG, and
  skipped only the `x86_64` launch because Rosetta 2 is not installed on the
  build host (Mach-O architecture, signature, and `.ReleaseFast` markers were
  verified instead).
