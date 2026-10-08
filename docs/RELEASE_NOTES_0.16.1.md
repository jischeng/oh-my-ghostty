# OMG 0.16.1 · Ghostty 1.3.2-dev

OMG 0.16.1 improves Agent CLI updates, adds Antigravity status hooks, and fixes
large-file Git diffs and Cmd-link hover in terminal panes.

## Highlights

- **Agent CLI updates** — use explicit vendor-native update policies instead of
  guessing support from `--help` output. Expand native updater coverage, including
  Pi's `update --all`, while preserving the original package source for verified
  npm installations of Droid, Grok, and Qwen. Agent CLI updates remain distinct
  from the optional OMG-managed Codex ACP adapter updates released in 0.16.0.
- **Antigravity status hooks** — install, validate, and remove OMG-owned status
  hooks without discarding unrelated vendor hooks; support local and SSH targets.
- **Large-file Git diffs (#30)** — remove the truncated snapshot bottleneck and
  make the diff renderer handle large output consistently.
- **Stable Cmd-link hover (#31)** — retain terminal tracking areas across hover
  and geometry changes, and reapply the current core cursor in AppKit cursor
  updates. Regression coverage includes single-pane and split-pane layouts.

## Version and scope

- OMG version: **0.16.1**; bundle version: **34**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.0.
- Maintainer-approved version-policy exception: this release includes the new
  Antigravity hook capability alongside fixes under the explicitly requested
  patch version 0.16.1. The normal minor-bump rule for new capabilities is not
  changed for future releases.

## Validation status

- Release-delta Swift selection against **v0.16.0** chose the broad routine sweep
  because shared host/mouse code, test infrastructure, and an unmapped Agent
  asset changed: **926 tests in 113 suites passed** in about 110 seconds on the
  final successful rerun. One intervening sweep hit a directory-listing subprocess
  timeout in `InspectorTreeLayoutTests`; its four tests passed on targeted rerun
  (the affected method took 49 ms), followed by the clean full sweep. No product
  code was changed to bypass the failure; its original timeout cause is unconfirmed.
- SwiftLint `--strict`: zero violations across **422 Swift files**.
- Zig formatting, settings JSON, plist/XIB, whitespace, and OMG documentation
  checks passed. Test selector/CLI contract: **41 tests passed**.
- No Zig core source changes since 0.16.0; no core test sweep was required.
- **Optional interactive desktop coverage is not verified.** The explicit
  Cmd-hover test was attempted but failed its foreground prerequisite
  (`NSApp.isActive && window.isKeyWindow`), before hover assertions could run.
  It is not claimed passed. Native drag/visual suites and XCUITest were not run.
  Single/split-pane tracking, current-cursor, and hit-target routine tests passed.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built successfully with OMG **0.16.1 / build 34**. All three apps passed deep
  code-signature, architecture, version/base metadata, and icon checks.
- Arm64 and universal signed apps and their read-only mounted DMG apps passed
  executable launch probes, reporting `.ReleaseFast`.
- Intel apps and mounted DMG contents passed x86_64 slice and ReleaseFast-marker
  checks. **Intel execution was not tested** because Rosetta is unavailable.
- All three DMGs passed checksum verification and read-only mount inspection;
  the published SHA-256 manifest verified all three images.
- Appcast validated with **0.16.1 / build 34**, minimum macOS **13.0**, one
  universal enclosure, matching file length, increasing bundle version, and
  retained prior release entries. The enclosure's Sparkle Ed25519 signature
  independently verified against the embedded public key.

## Signing and distribution

Release apps and DMGs are **ad-hoc signed** and **not notarized**. Gatekeeper may
block the first launch; users who trust the download can review and allow it in
System Settings > Privacy & Security. Sparkle updates use a separate EdDSA
signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
