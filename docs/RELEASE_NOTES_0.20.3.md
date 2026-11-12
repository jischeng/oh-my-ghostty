# OMG 0.20.3 · Ghostty 1.3.2-dev

OMG 0.20.3 is a targeted bug-fix release. It fixes terminal grid corruption
after a non-reflowing column shrink — the case that made session snapshots fail
with `InvalidWideCell` when reattaching a session from macOS or OMG Mobile — and
stops the local session relay from looping manual retries on a failing session.
The Ghostty base is unchanged.

## Highlights

- **Split wide cells are cleared on non-reflowing resize.** Shrinking columns
  without reflow (alternate-screen programs or with `DECAWM` disabled) cleared
  cells starting at the new column count without checking whether the new
  rightmost column held the left half of a wide character. That left an orphaned
  wide cell with no spacer tail, so snapshot grid encoding failed with
  `InvalidWideCell` and the session could not be reattached from macOS or
  OMG Mobile. The right-edge split wide cell is now cleared during
  non-reflowing resize.
- **Wide-cell pair invariants are enforced across the grid.** Partial row
  clones, blank insertions, and multi-codepoint wide writes now preserve wide
  pair integrity, and `Page.verifyIntegrity` checks the wide-cell pair
  invariants directly instead of letting corruption reach snapshot encoding.
- **No retry loop on a failing local session.** The local session relay now
  resets `retry_requested` and clears launch payloads when an inner session
  error or stream close arrives, so manually retrying a session that keeps
  failing no longer loops indefinitely.
- **Existing sessions stay attachable.** The snapshot compatibility map gained
  the new grid snapshot revision, so sessions already running under `0.20.2`
  continue to reattach with their revision mapped to the current snapshot
  format.

## Version and distribution

- OMG **0.20.3**, bundle version **53**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`
  (unchanged from `0.20.2`).
- Includes the changes since the published `v0.20.2` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.20.3-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.20.3-ios-unsigned.ipa`). The mobile
  app itself did not change in this release; the terminal snapshot fix matters
  to any phone or Mac that reattaches to an affected session.

## Validation

- Change-selected Swift suites for all commits since `v0.20.2` passed: **1532
  tests in 181 suites**. The first broad run reported one failure in
  `VerticalTabsIntegrationTests.terminalTitlesDoNotInvalidateWholeController`
  (a title-publication timing check, with `io_thread: OpenptyFailed` in the app
  log); the isolated retry passed **9/9**, and a full re-run of the same
  selection passed **1532/1532**. Optional `.interactiveDesktop` native
  drag/focus suites, XCUITest, and full TCC upgrade experiments were **not run**.
- Targeted Zig tests for the changed terminal paths passed: `wide` (149),
  `reflowing` (74), and `resize` (253) filters, including the new
  `encode_alloc succeeds after shrinking non-reflowing columns across wide
  cells` regression.
- `session-runtime` gates passed because `client.rs` changed: `cargo fmt
  --check`, `cargo clippy --all-targets -D warnings`, `cargo test` (82 tests),
  `cargo build`, and the Python runtime suite (35 tests, 4 environment-dependent
  SSH/Linux containment skips).
- OMG Mobile gates passed for the shared terminal snapshot dependency: iOS
  native core Swift checks and the Simulator UI flow through the retained VM
  harness (3 UITests, all execution receipts true: mobile executed, Mac GUI
  reclaimed, mobile reconnected, same PID/generation, create/close, file edit).
- Static gates passed: SwiftLint (0 violations in 603 files), Zig formatting,
  settings schema, OMG documentation contract, plist, Interface Builder, test
  selector (46 tests), and signing/Keychain contracts (17 + 15 tests).
- Signed `arm64` and `universal` release apps launched cleanly in `.ReleaseFast`
  mode and satisfied their designated requirement; their DMGs mounted and
  launched from the mounted volume. The `x86_64` app and DMG were verified for
  Mach-O architecture, signature, and `.ReleaseFast` markers without launching
  because Rosetta 2 is not installed on the build host.
- Post-sign runtime verification passed for all three apps: `omgd`
  `omg-session-runtime/2` / `snapshot/1` manifests with matching revisions, the
  universal `omgd` relay launching `omgd version`, and both Linux `x86_64` and
  `aarch64` ELF artifacts present.
