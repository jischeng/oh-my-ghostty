# OMG 0.25.0 · Ghostty 1.4.1-dev

OMG 0.25.0 introduces a dedicated AppKit Agent Inbox with Otty-aligned row geometry and ⌘-hold shortcut reveal, scopes conversation-based session naming cleanly to the Inbox while restoring compact single-line tabs in the Tabs view, and unifies AI model configuration into a single **AI Providers** settings page shared across tab title generation and Git Commit AI.

## Highlights

### Dedicated AppKit Agent Inbox & Sidebar Polish

- **Dedicated AppKit Inbox view with Otty-aligned proportions.** Replaced the inline Inbox list with a dedicated AppKit `NativeInboxViewController` (`NativeInboxRowView`, `NativeInboxSectionHeaderView`, `TabInboxHeaderButton`), aligning row height, enlarged centered icons, title weight, borderless selection pills, trailing close discs, right-aligned section chevrons, and row move animations with Otty.
- **Unified sidebar trailing slot & ⌘-hold shortcut reveal.** Added `NativeCommandRevealMonitor` so holding `⌘` reveals tab shortcut indices in the unified trailing slot across both **Tabs** and **Inbox** views, with shortcut order following the visible Inbox display order while Inbox is active.
- **Single-line Tabs & Inbox-scoped session naming.** Restored compact single-line rows in the **Tabs** view and scoped conversation-based session naming to **Inbox** rows. Manual tab renames now seed only explicit user overrides (never automatic paths or AI titles) and update tab presentation via `.ghosttyTabPresentationDidChange` without invalidating the SwiftUI terminal shell.
- **Recently Used recency driven by real interaction.** Aligned **Recently Used** ordering with real user input (`keyDown`, `insertText`, paste, Quick Input submission) and meaningful Agent activity transitions, persisting `tabLastInteractionAt` with workspace/session checkpoints without forcing extra session writes or disturbing terminal focus.

### Unified AI Providers Settings & Tab Titles

- **Unified AI Providers settings (`Settings → AI`).** Consolidated AI endpoint, API key, and model configuration into a shared **AI Providers** settings page (`NativeAISettings`, `AIProvider`, `AIModelListController`, `AIProviderModelPicker`) used by both Agent conversation title generation and Git Commit AI, with provider model discovery and a curated agent model catalog.
- **Short, localized generated tab titles.** Updated `AITitleService` and `AgentConversationTitleCoordinator` to keep generated conversation titles concise and in the app's configured language, preserving `agentPathTitle` on resume and avoiding repeated prompt reads after a conversation settles.

## Version and distribution

- OMG **0.25.0**, bundle version **69** (`CFBundleVersion`).
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.24.0`).
- Includes all changes since the published `v0.24.0` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**, using the same pinned `OMG Release Signing` certificate (`9b2e176c03e5458e6fdaf73392cd9d79203972c6`) and designated requirement as `v0.24.0`. macOS Gatekeeper may block the first launch; users who trust the download can review and allow it once in **System Settings → Privacy & Security**, and can optionally install Admin CodeSigning trust via **OMG → Settings → Plugins → OMG Doctor** so Sparkle updates preserve macOS TCC grants seamlessly (migration from older ad-hoc builds may require one-time authorization). Do not disable Gatekeeper globally. Sparkle updates retain their separate EdDSA signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle `Contents/Resources/session-runtime`, including the universal local `omgd` relay, mobile support helper, and macOS (`x86_64`, `aarch64`) plus Linux (`x86_64`, `aarch64`) remote session runtime artifacts. The session runtime revision `bfc43814f2b8931317ba` and snapshot revision `7abe5365444c63ee8df6` are unchanged from `0.24.0`. A remote daemon that owns live sessions is never replaced in place, so existing remote sessions stay on the revision they started with; older remote hosts without `durable-close/1` cannot acknowledge durable Close requests, and macOS plus Linux hosts without supported systemd/lingering user cgroup v2 retain process-group-only cleanup.
- iOS physical device installation requires signing with the user's own Apple ID (a free Personal Team Apple ID works via `OMG-Mobile-0.25.0-ios-installer.tar.gz`, or via a sideloader / AltStore / SideStore using `OMG-Mobile-0.25.0-ios-unsigned.ipa` and `altstore-source.json`).

## Validation

- **Static and contract checks**: passed (`swiftlint --strict`, settings schema, documentation contract, `plutil`, `ibtool`, signing, keychain, release, test-plan, mobile-plan, and zig-tests contracts; `zig fmt --check` skipped with no `.zig` files changed).
- **Session runtime & Zig**: not selected (no runtime or Zig source inputs changed since `v0.24.0`).
- **Swift**: all 14 routine modules (220 suites) passed on the initial broad run in the retained Tart VM (`0` isolated retries).
- **iOS**: `native-core`, `simulator-build`, and `vm-simulator-ui` checks passed.
- **Packaging**: all three macOS builds (`arm64`, `x86_64`, `universal`) signed with the pinned persistent certificate (`9b2e176c03e5458e6fdaf73392cd9d79203972c6`), mutual designated-requirement continuity verified against `0.24.0`, post-sign `session-runtime` manifests and universal `omgd` verified (`omgd version` → `omg-session-runtime/2 snapshot/1`), `arm64` and `universal` launch probes passed (`.fast`), `x86_64` Mach-O slice, ReleaseFast `_ghostty_info` mode, and signature verified (launch skipped as Rosetta 2 is not installed on the Apple Silicon build host), iOS installer kit, unsigned IPA, and `altstore-source.json` validated, and Sparkle EdDSA `appcast.xml` verified.
- **Not run**: optional `.interactiveDesktop` native drag/focus suites (15 deferred), XCUITest, full end-to-end desktop TCC and live Sparkle upgrade experiments, live remote SSH deployment / password-auth / Linux systemd cgroup v2 containment / live Agent conversation recovery acceptance gates, and host desktop frame-rate, multi-display, and input-to-photon latency measurements.
