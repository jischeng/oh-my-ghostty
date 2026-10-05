# OMG 0.16.0 · Ghostty 1.3.2-dev

OMG 0.16.0 brings pane-scoped Shell command history, scrollback restoration,
and more reliable local and SSH session recovery. It also adds an opt-in Codex
ACP update flow and fixes several tab, Inspector, and editor interactions.

## New features

- **Shell command history in Info Inspector** — history belongs to the owning
  terminal pane and connection. Repeated commands remain separate executions.
  Entries jump to tracked terminal anchors and briefly highlight the target row;
  expired or overwritten anchors become read-only instead of falling back to a
  potentially incorrect text search. Shell history remains available on Agent
  panes; Agent conversation navigation stays in Agent History.
- **Shell scrollback restoration** — eligible Shell panes can restore bounded VT
  output and command-history anchors after relaunch. Local and SSH history epochs
  retain their identities across connection changes. This replays saved output;
  it does not revive an old process. Corrupt, oversized, unsupported, and
  alternate-screen/Agent snapshots are conservatively skipped.
- **Three startup modes** — `sessions.startupMode` offers `restoreSessions`
  (default), `restoreTabs`, and `newTerminal`. Restore Tabs opens the saved layout
  in fresh local Shells without restoring old output or foreground processes;
  Restore Sessions uses supported saved session descriptors and output. A remote
  directory is never used as the cwd of a fresh local Shell.
- **Shared local and SSH shell integration** — interactive `omg +ssh` startup
  carries the same Fish/bash/zsh command markers as local terminals. The payload
  uses a base64 bootstrap envelope and does not rewrite remote dotfiles or require
  a remote OMG executable. Fish command metadata is validated so late prompt
  redraws do not contaminate recorded commands.
- **Optional managed Codex ACP updates** — Add Models can check the stable
  `@agentclientprotocol/codex-acp` version. An explicit user action installs a
  private OMG-managed copy and activates it after verification, without modifying
  the global npm installation. Older inactive managed versions are removed;
  other ACP adapters remain user-managed.

## Fixes and refinements

- Restore the selected tab within each native window group on launch and keep
  pending vertical-tab selection stable while AppKit switches tabs.
- Refresh vertical-tab selection consistently and scope Agent-logo tint
  animation to the affected logo.
- Hide inactive AppKit controls in Git history views.
- Reconcile editor viewport layout after multiline paste.
- Refine history row layout, timestamps, copy behavior, and pane ownership.
- Add opt-in, metadata-only diagnostics and bounded sampling tools for OMG Dev.
  These are disabled by default and are not enabled for the release app.

## Ghostty upstream base

The upstream base is unchanged since OMG 0.15.3. OMG-owned terminal history,
scrollback, and SSH integration code has changed and requires a fresh core build.

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`
- OMG bundle version: **33**

## Validation status

Measured validation results:

- SwiftLint `--strict`: zero violations across 421 Swift files.
- Zig formatting, settings JSON, plist/XIB, and OMG documentation checks passed.
- Universal ReleaseFast GhosttyKit rebuilt successfully; arm64, x86_64, and
  universal Release apps built with OMG **0.16.0 / build 33**.
- Focused Zig command-history, scrollback-export, and SSH tests: **96/96 passed**.
- Fake-transport shell integration: **12 scenarios passed**, covering system and
  Homebrew Bash, Zsh, and Fish in local, remote, and already-integrated modes.
- SSH wrapper tests: **4 passed**; Dev diagnostic sampler tests: **4 passed**.
- Test selector/CLI contract: **39 tests passed**, without Xcode/desktop interaction.
- Targeted Swift update module: **43 tests in 4 suites passed**.
- Release-delta routine Swift regression: **918 tests in 112 suites passed**.
  Shared core/host and test-infrastructure changes selected a broad routine sweep.
- **Optional interactive desktop: NOT RUN**. Real native drag/focus tests require
  explicit `--include-desktop-tests` on an unlocked foreground desktop. Routine
  tab integration and drag lifecycle/policy tests remain included.

Swift test selection now follows changed modules and direct dependents for every
release category, with conservative broad fallback for shared/unmapped changes;
see [TESTING.md](TESTING.md). Relevant native tab/drag/focus changes should schedule
the optional desktop regression on an unlocked foreground desktop. It is not
claimed passed, and XCUITest remains a separate excluded workflow.

- All three Release apps passed deep code-signature and architecture verification.
- Arm64 and universal apps passed executable launch probes, reporting `.ReleaseFast`.
- All three DMGs passed checksum verification and read-only mount inspection;
  arm64 and universal mounted apps passed launch probes.
- Intel apps and mounted DMG contents passed x86_64 slice and ReleaseFast-marker
  checks. **Intel execution was not tested** because Rosetta is unavailable.
- DMG SHA-256 checksums verified. The universal enclosure's Sparkle Ed25519
  signature independently verified against the embedded public key.
- Appcast validated with OMG **0.16.0 / build 33**, minimum macOS **13.0**, a single
  universal enclosure, and retained previous release entries.

## Signing, notarization, and publication

Release apps use **ad-hoc signatures** (`OMG_SIGNING_IDENTITY=-`) and are **not
notarized**. macOS Gatekeeper may block the first launch; trusted downloads can be
reviewed in System Settings > Privacy & Security. Sparkle update signing uses
its separate EdDSA key.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.

## Known investigation

Tinycast selection translation can fail for a Pi selection that includes its
bottom status area while manual copy still returns the complete selection.
Raycast clipboard auto-paste can fail for a non-first history entry while a
subsequent manual paste works. Neither root cause is confirmed or claimed fixed
in this release. The exploratory clipboard-interop test from that investigation
is not included in this release preparation.
