# OMG 0.5.0

OMG 0.5.0 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and improves SSH session continuity and remote tab presentation.

## Highlights

- Presents ready SSH tabs as a restrained `host › directory` breadcrumb. The remote host and separator remain secondary while the current remote directory basename stays prominent, and local tabs never retain remote title state.
- Preserves the pre-connection local working directory across SSH prompt updates so new local tabs inherit the correct directory instead of a remote path.
- Retains validated SSH replay descriptors across restored panes and application channels, keeping splits and remote Agent sessions attached to the active remote working directory after restoration.
- Returns replay sessions to a local shell after SSH disconnects and closes the pane normally after that shell exits instead of leaving a process-exited hold screen.
- Protects connect, disconnect, reconnect, stale-disconnect, restored-session, split, and remote Agent paths with focused lifecycle tests.

## Verification

- All 378 macOS app-hosted tests pass, including SSH lifecycle, replay restoration, remote breadcrumb, vertical-tab, Inspector, and version metadata coverage.
- Swift/resource, documentation/schema, plist, XIB, architecture, signature, DMG integrity, and SHA-256 checks are applied by the release gate.
- Release artifacts target arm64, x86_64, and universal macOS applications. The x86_64 path is validated under Rosetta 2 when Intel hardware is unavailable.
- The universal Sparkle enclosure advances to bundle version `7` and uses the dedicated OMG EdDSA key.

## Distribution status

The attached arm64/x86_64 manual-download DMGs and universal Sparkle updater DMG are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
