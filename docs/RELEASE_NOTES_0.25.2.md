# OMG 0.25.2 · Ghostty 1.4.1-dev

OMG 0.25.2 hardens AI tab renaming, unifies AI title and Git commit model routing with warm ACP pool queueing, and streamlines native Settings into modal sheets with repaired titlebar and sheet alerts.

## Highlights

### AI Tab Renaming & Model Routing

- **Unified title & Git commit model picker.** Unified `ai.routes.title` with `GitCommitAIRoute.Target` so tab naming shares `AIUnifiedModelPickerController` and warm pooled `GitACPService` sessions alongside HTTP API services while preserving legacy `{provider, model}` JSON compatibility.
- **Bounded ACP pool queueing & background rename queue.** Added a bounded cancellable pool slot queue in `GitACPService` with idle eviction and full waiter draining on shutdown, plus a bounded background rename queue in `AITitleService` with priority ordering for forced manual renames.
- **Hardened breaker, redaction & mid-flight switches.** Fixed the circuit-breaker wait gate, API key change detection after `401`/`403` pauses, secret redaction on prompt fallbacks, custom-title provenance preservation, and configuration-epoch tracking so mid-flight model, language, or `alwaysUseAI` switches re-evaluate cleanly (including Chinese localization on native titles).

### Native Settings & UI Polish

- **Task-owned settings & modal sheets.** Moved feature settings to their owning pages, separated API Services from Local CLI Models on the AI page, replaced multi-level push subpages and inline cancel rows with buffered native modal sheets, merged Plugins into Advanced, moved `terminalResizeRendering` to Appearance, and removed unused SwiftUI views.
- **Sheet collapse, titlebar insets & modal alerts.** Repaired modal sheet collapse, full-size titlebar insets, and light/dark theme contrast, and routed Settings error/confirmation/detail/hook-export alerts onto the topmost attached modal sheet window with live maintenance switch synchronization.

## Version and distribution

- OMG **0.25.2**, bundle version **71**.
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.25.1`).
- Includes the changes since the published `v0.25.1` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.25.2-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.25.2-ios-unsigned.ipa`).

## Validation

- Routine change-selected quality gates (11 static/contract checks and 220 Swift suites) and packaged artifact checks recorded by
  `dist/macos/omg_release.py` (see `.release-build/0.25.2/release-summary.md`). `GhosttyTests/TerminalWorkspaceManagementTests` failed in the initial broad run and passed on isolated retry (`macos/build.nu --action test --skip-build --only-testing GhosttyTests/TerminalWorkspaceManagementTests`).
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, and full TCC
  upgrade experiments were **not run** unless explicitly noted above.
