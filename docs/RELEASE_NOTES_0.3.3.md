# OMG 0.3.3

OMG 0.3.3 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and repairs the broken 0.3.2 macOS application packages.

## Fixes

- Removes hardened-runtime flags from local ad-hoc release signatures. Hardened runtime library validation treated the independently ad-hoc signed app and embedded Sparkle framework as different teams, causing dyld to abort before OMG reached `main`.
- Signs every nested Sparkle component and the universal updater app through the same release path as the architecture-specific apps.
- Rejects packaging when an ad-hoc app still carries hardened runtime or when OMG and any embedded Sparkle/updater component have different Team IDs.
- Adds a mandatory executable launch probe to the release checklist because `codesign --verify --deep --strict` alone accepted the broken 0.3.2 bundle.

## Upgrading from 0.3.2

Version 0.3.2 cannot remain open long enough to run its in-app updater. Download and install OMG 0.3.3 manually once from this release. The failure occurs during dynamic-library loading and does not indicate corrupted OMG settings or restoration data; terminal child processes running when 0.3.2 restarted may nevertheless have been terminated with the old app session.

## Verification

- The packaging guard rejects the installed broken 0.3.2 universal bundle with the expected hardened-runtime/ad-hoc diagnostic.
- The corrected universal bundle passes deep strict signature verification, DMG verification, and a native executable launch probe.
- All 359 macOS app-hosted tests pass, along with SwiftLint, documentation/schema, plist, XIB, and shell syntax checks.
- arm64 runs natively, x86_64 runs under Rosetta 2, and the universal build runs natively; all three mounted DMGs pass executable launch, architecture, metadata, deep-signature, integrity, and SHA-256 checks.
- The universal Sparkle enclosure carries the dedicated OMG EdDSA signature and publishes strictly increasing bundle version `4`.

## Distribution status

The attached arm64/x86_64 manual-download DMGs and universal Sparkle updater DMG are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
