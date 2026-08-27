# OMG 0.4.1

OMG 0.4.1 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and fixes drag-and-drop behavior in the vertical tabs sidebar.

## Highlights

- Accepts dragged split panes on any vertical tab row or the trailing drop zone. Dropping on the upper or lower half of a row creates a tab before or after that row, while the trailing target appends it to the end.
- Restores vertical tab reordering with a unified row drop destination for pane and tab payloads, avoiding competing SwiftUI drop targets that prevented tab drags from receiving insertion updates.
- Aligns the tab drop lifecycle with pane drops: insertion indicators, drag state, and hover chrome are cleared before the native tab order changes, so the real row and its hover background settle together without a delayed second animation.
- Preserves pane session, SSH, Agent, sidebar layout, selection, and native tab-group state across pane-to-tab moves, failure rollback, undo, and redo. Stable tab and surface identifiers resolve recreated controllers instead of retaining stale AppKit objects.
- Keeps pane drops into split targets and pane drags outside all application windows working as before.

## Verification

- All 372 macOS app-hosted tests pass, including focused vertical-tab drop routing, lifecycle, transaction, and version metadata coverage.
- Swift/resource, documentation/schema, plist, XIB, architecture, signature, DMG integrity, and SHA-256 checks are applied by the release gate.
- Release artifacts target arm64, x86_64, and universal macOS applications. The x86_64 path is validated under Rosetta 2 when Intel hardware is unavailable.
- The universal Sparkle enclosure advances to bundle version `6` and uses the dedicated OMG EdDSA key.

## Distribution status

The attached arm64/x86_64 manual-download DMGs and universal Sparkle updater DMG are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
