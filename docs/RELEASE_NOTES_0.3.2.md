# OMG 0.3.2

OMG 0.3.2 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and is a focused bug-fix release over 0.3.1.

## Fixes

- Keeps Pi's Agent status on `working` when a new prompt starts immediately after an Esc-aborted turn. A delayed `agent_settled` event from the previous run can no longer overwrite the newer active state.
- Marks normal Pi session teardown complete before ending its OMG context, preventing reloads, resumes, and clean session switches from appearing as unexpected Agent failures.
- Preserves the structured question attention subtype for Pi user-input tools.
- Advances the managed Pi status hook to version 6 so OMG Settings can detect and replace older installed integrations.

## Plugin delivery

The runtime fix lives entirely in Pi's managed `omg-agent-status.ts` extension. Existing local installations can use the updated extension immediately after Pi `/reload`; OMG.app does not need to restart. OMG 0.3.2 packages the version-6 extension source and installer metadata so other users can receive the fix through OMG's Agent integration installer.

This remains a bundled first-party adapter rather than an independently distributed plugin package. A general third-party plugin install/update lifecycle is still a separate capability from the current host-owned status integration.

## Verification

- The generated Pi extension asserts the `ctx.isIdle()` completion guard and ordered `done` → context-end shutdown sequence.
- The installed extension source parses successfully and matches OMG's generated source byte-for-byte.
- The complete `AgentStatusPluginTests` suite passes, including normal completion and unexpected-interruption reducer coverage.
- Release artifacts are checked for arm64, x86_64, and universal architectures, bundle/version metadata, code-signature validity, DMG integrity, SHA-256 checksums, and Sparkle EdDSA enclosure signatures.

## Distribution status

The attached arm64/x86_64 manual-download DMGs and universal Sparkle updater DMG are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
