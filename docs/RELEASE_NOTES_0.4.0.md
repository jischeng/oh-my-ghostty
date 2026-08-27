# OMG 0.4.0

OMG 0.4.0 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and refines the native macOS shell, Inspector presentation, and Agent lifecycle.

## Highlights

- Replaces the hand-built Settings navigation sidebar with native macOS list selection, system appearance, keyboard navigation, and accessibility behavior.
- Centralizes native titlebar control metrics and keeps the Inspector toggle in a fixed trailing slot. Files and future Plugin controls use only the remaining titlebar width, enter and leave with the pane transition, and recover correctly after repeated close/reopen cycles.
- Keeps dividers and resize handles in the content shell instead of duplicating them in the titlebar. The Inspector resize handle now refreshes its cursor region after hidden-to-visible frame changes.
- Types Agent hook dialects and shares local/remote JSON hook generation, rejecting unknown manifest values instead of silently choosing another shape.
- Separates PID-backed Plugin liveness from process-group-backed shell hooks. Pi remains `working` while child tools change the foreground process group and reports `error` only when its declared process actually exits.
- Bounds per-Surface Agent context history and records the long-term fork architecture: the complete Ghostty macOS app remains the host while OMG features stay in fork-owned modules behind small adapters.

## Agent integration

The managed Agent hook version advances to 7. New hooks emit `omg_liveness=pid|pgid`; older installed Plugin hooks remain compatible because the host interprets their numeric context suffix as a PID based on the manifest hook kind. Updating the Pi integration through OMG Settings installs the explicit version-7 metadata.

## Verification

- All 363 macOS app-hosted tests pass, including initial-window titlebar controls, Inspector close/reopen screenshots, fixed Plugin/toggle layout, resize cursor registration, and Pi PID/PGID lifecycle regressions.
- Swift/resource, documentation/schema, plist, XIB, architecture, signature, DMG integrity, and SHA-256 validation are required by the release gate.
- Release artifacts target arm64, x86_64, and universal macOS applications. The x86_64 path is validated under Rosetta 2 when Intel hardware is unavailable.
- The universal Sparkle enclosure uses monotonically increasing bundle version `5` and the dedicated OMG EdDSA key.

## Distribution status

The attached arm64/x86_64 manual-download DMGs and universal Sparkle updater DMG are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
