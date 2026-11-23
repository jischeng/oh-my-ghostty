# OMG 0.23.1 · Ghostty 1.4.1-dev

OMG 0.23.1 is a patch release fixing AI commit message generation on large staged diffs and repositories, terminal scrollback restore spacing, and wrapped wide-grapheme handling.

## Highlights

### Git Commit AI

- **No more hard failure on large staged diffs or large repositories.** Replaced full-index listing (`git ls-files --stage`) with a staged-only fingerprint (`git diff --cached --raw`), eliminating false "200 KB patch limit" errors on large repositories.
- **Layered diff budgeting and graceful fallback.** Commit generation now always includes a global `--stat` overview, excludes lockfiles and generated/minified noise from inline hunks, applies per-file and total byte budgets, and degrades cleanly to sampled hunks or `--stat` summaries instead of aborting.
- **Tolerant decoding and cleaner prompts.** Non-UTF-8 staged files no longer block generation, and the prompt now uses structured XML sections with branch name, diff stat, and recent commit subjects instead of an escaped JSON string.

### Terminal & Session Runtime

- **Cleaner scrollback restores.** Trailing blank rows are omitted from scrollback exports so restored panes no longer show an empty gap above the prompt.
- **Wrapped wide-grapheme integrity.** Wide graphemes wrapping at the right margin now attach after writing the spacer tail, fixing page-integrity violations in Debug builds.
- **Release gate coverage.** Zig tests for changed terminal files and bundled session-runtime checks now run automatically as part of the release gate.

## Version and distribution

- OMG **0.23.1**, bundle version **66**.
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.23.0`).
- Includes the changes since the published `v0.23.0` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts. The session runtime revision is `8e8d42c58b3ddd438eb3`
  (`055999ff4b9b33266b48` in `0.23.0`); the snapshot revision
  `7abe5365444c63ee8df6` is unchanged. A remote daemon that owns live sessions
  is never replaced in place, so existing sessions stay on the revision they
  started with.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.23.1-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.23.1-ios-unsigned.ipa`).

## Validation

- **Static and contract checks**: passed (`swiftlint --strict`, `zig fmt --check`,
  settings schema, documentation contract, `plutil`, `ibtool`, signing, keychain,
  release, test-plan, and mobile-plan contracts).
- **Zig**: passed (512/512 tests selected for changed terminal files:
  `src/terminal/Terminal.zig`, `src/terminal/omg_scrollback_export.zig`).
- **Session runtime**: passed (`cargo fmt --check`, `cargo clippy -D warnings`,
  Rust and Python suites; environment-dependent SSH/Linux containment tests
  skipped as expected without a configured remote host).
- **Swift**: all 13 routine modules (204 suites) passed in the retained Tart VM.
  `EditorWorkspaceLifetimeTests` failed in the initial broad run and passed on
  isolated retry; all other 203 suites passed in the broad run.
- **iOS**: `native-core` checks passed.
- **Packaging**: all three macOS builds (`arm64`, `x86_64`, `universal`) signed
  with the pinned persistent certificate (`9b2e176c03e5458e6fdaf73392cd9d79203972c6`),
  post-sign `session-runtime` manifests verified, `arm64` and `universal` launch
  probes passed, `x86_64` Mach-O slice and signature verified (launch skipped as
  Rosetta 2 is not installed), and Sparkle EdDSA `appcast.xml` verified.
- **Not run**: optional `.interactiveDesktop` native drag/focus suites (15
  deferred), XCUITest, full desktop TCC and Sparkle upgrade experiments, live
  remote SSH deployment/Linux containment gates, and host frame-rate/latency
  measurements.
