# OMG 0.25.1 · Ghostty 1.4.1-dev

OMG 0.25.1 refines the Agent Inbox experience, AI session title generation, and Settings organization, bringing configurable Inbox Continue windows, cleaner SSH row subtitles, manual/forced AI tab renaming, and redesigned task-oriented AI and Tabs settings cards.

## Highlights

### Agent Inbox & Sidebar

- **Configurable Inbox Continue window & urgency/recency ordering.** Added an active Continue window anchored on agent acknowledgment (default 15 minutes, configurable via `tabs.inboxContinueMinutes` with periodic expiry refresh) and independent urgency/recency ordering for Inbox Continue rows.
- **Cleaner single-host SSH rows & header icon sizing.** Omitted redundant SSH host prefixes in single-host Inbox rows, abbreviated SSH home paths, and matched the Inbox header tray icon optical size to sibling sidebar buttons.
- **Preserved `⌘`-hold across tabs & Inbox shortcuts.** Preserved `⌘`-hold shortcut reveal across tab switches and added Inbox shortcut and auto-rename menu actions.

### AI Session Titles & Settings

- **AI-shortened native titles & localized Chinese titles.** Added `agents.sessionTitle.alwaysUseAI` to shorten native titles with AI, localized English agent titles when running in Chinese UI, eliminated baked-in title ellipses, coalesced rename requests, and added renaming progress indicators and forced auto-rename support.
- **Redesigned AI and Tabs settings.** Reorganized **Settings → AI** and **Settings → Tabs** into clear, task-oriented cards, and resolved `projectName` from descriptor/session working directories while preventing multi-owner done follow-up loops.

## Version and distribution

- OMG **0.25.1**, bundle version **70** (`CFBundleVersion`).
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.25.0`).
- Includes all changes since the published `v0.25.0` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**, using the same pinned `OMG Release Signing` certificate (`9b2e176c03e5458e6fdaf73392cd9d79203972c6`) and designated requirement as `v0.25.0`. macOS Gatekeeper may block the first launch; users who trust the download can review and allow it once in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally. Sparkle updates retain their separate EdDSA signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle `Contents/Resources/session-runtime`, including the universal local `omgd` relay, mobile support helper, and macOS (`x86_64`, `aarch64`) plus Linux (`x86_64`, `aarch64`) remote session runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID (a free Personal Team Apple ID works via `OMG-Mobile-0.25.1-ios-installer.tar.gz`, or via a sideloader using `OMG-Mobile-0.25.1-ios-unsigned.ipa`).

## Validation

- Routine change-selected quality gates and packaged artifact checks recorded by `dist/macos/omg_release.py` (see `.release-build/0.25.1/release-summary.md`).
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, and full TCC upgrade experiments were **not run** unless explicitly noted above.
