# OMG 0.16.3 · Ghostty 1.3.2-dev

OMG 0.16.3 reduces background CPU overhead from working Agent icons and SSH
port-forward process-name discovery without changing the terminal core.

## Highlights

- **Native Agent breathing animation** — replace frame-driven SwiftUI updates
  with a Core Animation opacity animation on an independent AppKit container.
  Static logo content keeps its tint, fixed footprint, and surrounding tab hit
  testing. Animations stop when hidden, occluded, detached, or Reduce Motion is
  enabled; leaving the working state restores full brightness.
- **On-demand port discovery** — query remote listener names only while an Info
  presentation for that server is visible. Hiding Info stops discovery, not the
  forwarding tunnels. Reopening Info refreshes names again, and multiple
  presentations share the same demand.
- **Batched, bounded SSH queries** — query all eligible ports of one SSH alias
  in one connection instead of a connection per port. Visible discovery runs
  approximately every 30 seconds with globally serialized queries, a six-second
  timeout, bounded asynchronous output, and cancellation cleanup. Failures keep
  cached names and back off to 60/120 seconds; successful queries without a
  listener clear the old name. Generation and connection tokens reject stale
  results after hiding, disconnecting, or reconnecting.

## Version and scope

- OMG version: **0.16.3**; bundle version: **36**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.2.
- This is a performance and lifecycle bug-fix release. Plugin capabilities,
  permissions, and the user-consent model are unchanged.
- Old restored plain-SSH sessions that are not recognized as a ready OMG SSH
  session remain a separate investigation; this release does not claim to fix
  that compatibility issue.

## Runtime observations and limits

A visible working Agent in the native-animation OMG Dev build averaged about
**4.2% of one CPU core** across three 15-second intervals, rather than the roughly
40% observed with the unsuccessful SwiftUI repeat-animation implementation.
These are workload-specific observations, not a universal CPU guarantee or a
strictly controlled cross-version benchmark.

With nine forwarding tunnels on one SSH alias, a three-minute visible-Info
observation captured five new SSH queries, each covering all nine ports, spaced
about 31 seconds apart including query execution. A three-minute hidden-Info
observation captured no new discovery queries. Reopening Info resumed batch
queries. Tunnel PIDs and endpoints stayed identical through all three phases.
OMG Dev main-process CPU averaged 4.34% with Info visible and 0.75% hidden; the
entire difference cannot be attributed to SSH alone because UI visibility and
other workload activity also matter.

Process observation used fork/exec notifications and bounded snapshots, not a
complete execution audit; query counts are observed lower bounds. Six remote
listeners passed TCP-only checks before and after hiding Info. Three configured
remote ports had no listener and could not be validated as working services.
No HTTP/database business requests or remote service-start operations were
performed. These runtime checks do not establish application-protocol correctness.

## Validation status

- Release-delta Swift selection against **v0.16.2**: **834 tests in 103 suites
  passed**. The scope covers the changed modules and their direct dependents,
  plus release metadata tests; no unmapped/shared-code fallback was needed.
- SwiftLint `--strict`: zero violations across **422 Swift files**. Zig formatting,
  settings JSON, plist/XIB, documentation, shell syntax, and whitespace checks
  passed. There are no Zig core source changes in this release delta.
- **17 signing tests**, including the actual-app nested-signature/startup smoke;
  **12 credential-automation tests** using disposable Keychains; and **41
  test-selector contract tests** passed. No production credential or identity
  was replaced. Signing used the already-authorized Python runtime explicitly.
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.3 / build 36**. All three passed architecture, version,
  base revision, icon, exact signer/DR, and nested-signature checks. Designated
  requirements match 0.16.2 and satisfy mutual old/new identity compatibility.
- Arm64 and universal signed apps and read-only mounted DMG apps launched with
  `.ReleaseFast`. Intel slices and build markers passed; **Intel execution was
  NOT RUN** because Rosetta is unavailable.
- All three DMGs passed checksum verification and read-only mount inspection;
  the SHA-256 manifest verified every image.
- The actual arm64 release executable passed **four SSH wrapper artifact tests**
  and local/remote bash, zsh, and Fish shell-integration scenarios, including
  preservation of existing integration and user hooks.
- Appcast metadata verified **0.16.3 / build 36**, minimum macOS **13.0**, one
  universal enclosure of the expected length, strictly increased bundle version,
  and retained older entries. OpenSSL independently verified its Sparkle
  Ed25519 signature against the embedded public key.
- The optional native Tab interaction suite was attempted but stopped at its
  foreground/key-window prerequisite; actual mouse/drag assertions were **NOT
  RUN**, not passed. This coverage gap was explicitly accepted for publication.
  Other optional interactive desktop tests, XCUITest, end-to-end TCC migration,
  and end-to-end Sparkle installation were **NOT RUN**.

## Signing and distribution

Release apps reuse the **persistent self-signed identity from 0.16.2; not
notarized**. This is not Apple Developer ID distribution. Gatekeeper may block
the first launch; users who trust the download can review and allow it in System
Settings > Privacy & Security. Do not disable Gatekeeper globally. DMGs are not
notarized. Sparkle updates retain their independent EdDSA signature.

End-to-end TCC permission retention and Sparkle installation/permission-upgrade
experiments are **NOT RUN**, not passed. Static signing continuity checks do not
guarantee permission retention on every supported macOS version.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
