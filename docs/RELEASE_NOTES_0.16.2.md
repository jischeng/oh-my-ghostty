# OMG 0.16.2 · Ghostty 1.3.2-dev

OMG 0.16.2 changes release code signing to a persistent self-signed identity,
addressing the changing application identity behind repeated macOS folder
permission requests after updates.

## Highlights

- **Stable release identity** — release signatures bind the OMG application ID
  and a persistent signing certificate instead of each build's code hash.
  Subsequent releases reuse the same certificate. Packaging rejects ad-hoc and
  development signatures rather than silently changing identities.
- **Release integrity checks** — validate the actual signing certificate of
  nested Sparkle components and the Dock plug-in, enforce matching designated
  requirements across release architectures, and recheck identity inside DMGs.
- **Maintainer recovery** — a one-time identity tool creates a private Keychain
  and encrypted certificate/private-key backup without installing system trust;
  existing signing identities are never silently regenerated. Optional one-time
  setup stores the signing-unlock password in the local login Keychain; subsequent
  release signing retrieves it through Security.framework without passwords in
  command arguments, environment variables, files, or logs. Locked/denied access
  fails closed rather than changing the signing identity.

## Version and scope

- OMG version: **0.16.2**; bundle version: **35**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.1.
- This is a release-signing and packaging fix; plugin capabilities and the
  application's user-consent model are unchanged.

## Permission migration

The first upgrade from an older ad-hoc-signed OMG can require folder permissions
again because this release establishes a new persistent identity. Stable signing
targets retention of existing grants in later updates; first-time access, newly
accessed protected resources, and user-revoked permissions still require normal
macOS consent. Future certificate changes can also require authorization again.

**End-to-end folder-permission retention and Sparkle permission-upgrade tests
were NOT RUN.** This release validates code identity and signed-artifact behavior,
not a guarantee of TCC permission retention on every supported macOS version.

## Validation status

- Swift release-delta selection against **v0.16.1** chose all routine modules
  because signing/test infrastructure changed: **926 tests in 113 suites passed**.
- SwiftLint `--strict`: zero violations across **422 Swift files**. Zig formatting,
  settings JSON, plist/XIB, documentation, shell syntax, and whitespace checks
  passed. No Zig core source changes required a core test sweep.
- **17 signing tests**, **12 credential-automation tests**, and **41 test-selector
  contract tests** passed. Native signing tests used disposable certificates and
  verified compatible identities across code changes, rejection of another signer,
  and signed OMG artifact startup. Native credential tests used two disposable
  Keychains for save/update/automatic-unlock verification, not the login Keychain.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.2 / build 35**. All three passed architecture, base/version,
  icon, exact certificate/DR, and nested code-signature checks.
- Arm64 and universal signed apps and read-only mounted DMG apps launched with
  `.ReleaseFast`. Intel slices and ReleaseFast markers passed; **Intel execution
  was NOT RUN** because Rosetta is unavailable.
- All three DMGs passed checksum verification and read-only mount inspection.
  The SHA-256 manifest verified the three images.
- Appcast metadata verified **0.16.2 / build 35**, minimum macOS **13.0**, one
  universal enclosure with the matching file length, and retained older entries.
  Its Sparkle Ed25519 signature independently verified against the embedded
  public key.
- Optional interactive desktop suites, XCUITest, actual TCC permission-upgrade,
  and end-to-end Sparkle installation tests were **NOT RUN**, not passed.

## Signing and distribution

Release apps are **persistently self-signed; not notarized**. This is not
Apple Developer ID distribution. Gatekeeper may block the first launch; users
who trust the download can review and allow it in System Settings > Privacy &
Security. Do not disable Gatekeeper globally. DMGs are not notarized. Sparkle
updates retain their independent EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
