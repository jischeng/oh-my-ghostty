# OMG 0.16.9 · Ghostty 1.3.2-dev

OMG 0.16.9 fixes Hermes recognition in local and SSH panes, prevents unrelated
sessions from sharing status or restoration identity, and makes Agent integration
maintenance adopt newly discovered CLIs. The upstream Ghostty base is unchanged.

## Highlights

- **Recognize the actual Hermes terminal client.** Hermes can launch through a
  Python wrapper and run its lifecycle hooks in a shared gateway without a TTY.
  OMG now detects the foreground terminal client independently of the gateway.
  A live client can display an idle identity before its first model request.
- **Match status to the correct pane.** Gateway hooks record bounded state in
  separate files per session. OMG resolves the pane's exact TTY breadcrumb and
  consumes only that session's event. Background or exited clients, old
  breadcrumbs from a reused TTY, and synthetic `hooks test` sessions do not
  supply restoration identity. This fixes the earlier host-wide status file
  that could mix multiple sessions or save `test-session` as a resume target.
- **Read Hermes status over SSH.** Updated `omg +ssh` startup metadata reports
  the remote TTY. OMG uses its existing SSH connection to run the same bounded
  metadata probe on that host. Existing SSH panes need to reconnect once after
  upgrading to receive the new TTY metadata; plain SSH panes without this
  metadata do not guess ownership from a working directory.
- **Repair Hermes integration installation.** The YAML installer emits one
  `hooks:` mapping and invokes an executable helper rather than treating shell
  syntax as a program name. The manifest declares session identity and
  `--resume <id>`, and SSH invocation supports Hermes resume arguments.
  Turn completion is distinct from final client/session teardown.
- **Adopt newly installed Agent CLIs.** Automatic Hook maintenance discovers
  missing integrations as well as updating existing ones. Automatic maintenance
  is enabled by default, with a one-time migration enabling the setting for
  existing policies; later user opt-outs remain effective. CLI binary updates
  retain their separate controls. Detector markers are reconciled per Agent,
  with explicit removal records for subsequent opt-outs.
- **Consistent Agent icons in Settings and Inspector.** Reasonix, Crush, Droid,
  and Hermes now use the monochrome template assets already used in tabs, so
  their marks follow the system appearance alongside the other Agents.

## Version and scope

- OMG version: **0.16.9**; bundle version: **42**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.8.
- Hermes integration, session metadata routing, SSH prompt metadata, Agent
  maintenance, and icon behavior are documented in `docs/PLUGIN_DEVELOPMENT.md`.
- The maintainer confirmed that Hermes recognition works after installing the
  corrected Dev build. A complete quit/relaunch test restoring the exact Hermes
  conversation on both local and SSH clients has **NOT RUN** as a release
  acceptance experiment; resume argument and identity behavior have automated
  coverage. Display recognition does not by itself prove full restoration.

## Validation status

- Strict SwiftLint passed across **455 Swift files** with zero violations. Zig
  formatting, settings JSON, documentation contract, plist, and XIB checks passed.
- Signing contracts: **17 tests, 2 optional smoke skips**; Keychain contracts:
  **15 tests, 1 optional skip**; test-selector contracts: **41 tests**; executable
  Hermes reporter/probe contracts: **7 tests**. No credentials or model calls are
  required by the Hermes metadata tests.
- Routine Swift selection since **v0.16.8** expands to all routine suites because
  TerminalController and SSH core code changed: **1026 tests in 121 suites**
  passed. Benchmarks, XCUITest, and the optional interactive desktop tier were
  excluded by the standard wrapper policy.
- Universal ReleaseFast GhosttyKit and **arm64, x86_64, and universal** Release
  apps built successfully. All three report OMG **0.16.9 / build 42**, bundle
  identifier `com.jischeng.omg`, and the expected Ghostty base; each carries
  exactly its intended Mach-O architecture(s).
- All nested components use the persistent self-signed identity. Designated
  requirements match across the three variants and pass mutual compatibility
  against the preserved 0.16.8 universal app.
- arm64 and universal binaries launched with `.ReleaseFast`, both in the build
  directory and inside their read-only mounted DMGs. **Rosetta 2 is unavailable**,
  so the x86_64 app and mounted DMG were verified by signature, architecture and
  ReleaseFast marker; Intel execution was **NOT RUN**.
- All three DMGs passed `hdiutil` verification, mounted read-only, and retained
  the signed app identity. SHA-256 hashes cover all three images.
- The actual signed arm64 release executable passed offline local/remote
  bash, Homebrew bash, zsh and fish startup tests; SSH wrapper contracts passed
  **4 tests**, and the targeted Zig `remoteShellCommand` tests passed.
- Sparkle appcast verifies **0.16.9 / build 42**, minimum macOS **13.0**, the
  universal enclosure URL and exact byte length. The enclosure's EdDSA signature
  was cryptographically verified with Sparkle `sign_update --verify`. The numeric
  version increases from 41 to 42; the feed retains 0.16.8 and 0.16.7 entries.

Interactive desktop input tests and full Desktop/Documents/Downloads/Sparkle
upgrade permission experiments are **NOT RUN**. The latter are not release
prerequisites; static signature checks do not establish end-to-end TCC behavior.

## Signing and distribution

Release apps reuse the **persistent self-signed identity; not notarized**. This
is not Apple Developer ID distribution. Gatekeeper may block the first launch;
users who trust the download can review and allow it in System Settings >
Privacy & Security. Do not disable Gatekeeper globally. DMGs are not notarized.
Sparkle updates retain their separate EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
