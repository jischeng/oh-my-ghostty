# OMG 0.16.5 · Ghostty 1.3.2-dev

OMG 0.16.5 makes Command-hover links trustworthy: a candidate is only
underlined, previewed, and opened after the source pane's filesystem confirms
it exists, local or SSH. It also batches those checks, stops stale link
decoration on release, and keeps directory clicks out of agent input, without
changing the upstream Ghostty core version.

## Highlights

- **Existence-checked hover links** — a regex match is only a candidate. The
  core now asks the host whether the candidate resolves in the source pane's
  filesystem (local or SSH) and only verified spans are underlined, previewed,
  and opened, matching VS Code and iTerm2 behavior. Answers are cached per
  Command press, so files created or removed since the last press are picked up.
- **SSH-aware path resolution** — remote relative links resolve against the
  pane's known remote working directory instead of a Mac directory; core OSC 7
  history never supplies a local cwd to a remote filesystem. Hover previews,
  existence checks, and opening share one host resolver, including relative
  OSC 8 targets and Chinese filenames. Historical remote directories are not
  reconstructed; absolute links remain the way to reach earlier remote paths.
- **Batched filesystem probes** — one Command press coalesces candidates
  dispatched in the same run-loop turn into a single batch per scope,
  deduplicates paths, and caches positive and negative answers for three
  seconds. Local checks run off the main actor; remote checks group quoted
  POSIX file and directory tests into bounded commands instead of one round
  trip per filename, and a transport failure is never cached as "missing".
  The core refreshes rendering once per completed group.
- **Link decoration cleanup** — releasing Command with a stationary pointer now
  invalidates GPU rows on both modifier edges, so underlines disappear without
  requiring mouse movement.
- **No `cd` into an agent pane** — with the current-pane directory destination,
  Command-clicking a folder opens a right-hand sibling shell whenever the source
  pane has active agent activity or a resume descriptor, so shell commands can
  never land in the agent chat input. Explicit new tab and split choices are
  unchanged.
- **Candidate precision** — a bare `/` is no longer an implicit link while
  explicit OSC 8 targets keep their author-provided destination; quoted paths
  stop at the opposite quote delimiter (`b='/some/dir'` no longer swallows the
  text that follows); unquoted paths stop at whitespace on macOS; candidates
  terminate at CJK full-width punctuation, method calls such as `.zIndex(1)`
  are rejected, and plain long `ls` listings expose directory and extensionless
  names without icon prefixes while metadata columns stay unlinked.
- **Stable flags routing** — flags-changed events are routed by the key window
  and its first responder instead of `mainWindow`, which is not the focused
  window when a panel or second window is key, avoiding double processing and
  flicker.

## Version and scope

- OMG version: **0.16.5**; bundle version: **38**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.4.
- This is a patch release. Plugin capabilities, permissions, and the
  user-consent model are unchanged; `docs/PLUGIN_DEVELOPMENT.md` records the SSH
  relative-link resolution, existence-check transport, and directory-navigation
  agent fallback in the same commits as the code.

## Validation status

- SwiftLint `--strict`: zero violations across 426 Swift files. Zig formatting,
  settings JSON, documentation contract, plist, XIB, and signing/keychain
  automation contracts all passed (`test_omg_signing.py` 17 tests, 2 smoke
  skips; `test_omg_keychain.py` 15 tests, 1 skip; `test_omg_test_plan.py` 41
  tests).
- Routine Swift tests passed for all commits since **v0.16.4**: 947 tests in
  114 suites, `TEST SUCCEEDED`. Benchmarks are skipped by default and the
  `.interactiveDesktop` native drag/focus tier is **NOT RUN** (default
  exclusion; XCUITest remains excluded).
- Zig tests for the changed surfaces passed: 111/111 tests (`OMG` and `url`
  filters, `-Dversion-string=1.3.2-dev`).
- Universal ReleaseFast GhosttyKit and arm64, x86_64, and universal Release apps
  built with OMG **0.16.5 / build 38**. Each binary carries exactly its named
  architecture (universal: `arm64 x86_64`); bundle ID, OMG version, Ghostty base
  version, and base revision verified on all three apps.
- Signed with the persistent self-signed identity; the designated requirement is
  identical to 0.16.4
  (`identifier "com.jischeng.omg" and certificate leaf = H"9b2e176c…"`), and the
  mutual-compatibility check against the preserved 0.16.4 universal app passed.
- Launch probes: arm64 and universal apps and their read-only mounted DMG apps
  launched with `.ReleaseFast`. **Rosetta 2 is not installed on the build
  machine**, so the x86_64 binary was verified by Mach-O slice inspection and
  the `.ReleaseFast` build marker instead of a launch; its DMG mounted and
  passed signature and designated-requirement identity checks. Intel hardware
  launch was **NOT RUN**.
- All three DMGs passed `hdiutil verify` and read-only mount inspection; the
  SHA-256 manifest covers every image.
- Appcast metadata verified **0.16.5 / build 38**, minimum macOS **13.0**, one
  universal enclosure with a Sparkle EdDSA signature, a strictly larger numeric
  bundle version, and retained 0.16.4 / 0.16.3 entries.
- Full Desktop/Documents/Downloads and Sparkle upgrade permission experiments
  are **NOT RUN**; per maintainer decision they are not a release prerequisite,
  and static signature verification does not establish end-to-end TCC behavior.

## Signing and distribution

Release apps reuse the **persistent self-signed identity from 0.16.4; not
notarized**. This is not Apple Developer ID distribution. Gatekeeper may block
the first launch; users who trust the download can review and allow it in
System Settings > Privacy & Security. Do not disable Gatekeeper globally. DMGs
are not notarized. Sparkle updates retain their independent EdDSA signature.

Release tooling now pins the authorized signing interpreter in a local,
non-secret `signing-python.pin` and preflights credential access before any
build output is deleted or any app is signed, so an ACL failure surfaces as a
clear early error rather than after compiling three app variants.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
