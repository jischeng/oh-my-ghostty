# OMG 0.17.1 · Ghostty 1.3.2-dev

OMG 0.17.1 improves Git review and commit workflows, vertical tabs, and Agent draft import. The Ghostty base is unchanged.

## Highlights

- **Review and commit Git changes in the Inspector.** Open changed files in the native diff review, choose repository/change scope, inspect before and after content, and compose commits from the built-in interface. Repository change monitoring refreshes the review when files change, and commit actions communicate their current state more clearly.
- **Keep vertical tabs responsive and in sync.** Native tabs share one live sidebar list. Rapid tab creation, close, selection, and window resizing preserve the latest selection and prepare the incoming terminal frame before AppKit reveals it.
- **Import drafts from local and SSH Agents.** Quick Input detects foreground Agents, including those launched through remote aliases or shell functions, and imports their unsent text. Sending an imported draft avoids resending the copy still held by the Agent. During the external-editor handoff, a temporary pane image covers the intermediate terminal screen transition; PTY processing continues.
- **Improve sidebar controls.** `⌘B` toggles the left sidebar and `⌘⇧B` toggles the right sidebar.

## Version and scope

- OMG version: **0.17.1**; bundle version: **44**.
- Ghostty base: **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.17.0.

## Validation status

* Strict SwiftLint passed across **466 Swift files**; Zig formatting, settings JSON, documentation contract, plist, and MainMenu XIB checks passed.
* Signing contracts: **17 tests passed, 2 optional smoke tests skipped**. Keychain contracts: **15 tests passed, 1 optional test skipped**. Test-selector contracts: **41 tests passed**. Community documentation contracts: **7 tests passed**.
* The full routine Swift selection ran twice, each covering **1064 tests in 124 suites**. Both runs had intermittent timing failures: SSH Git executor and terminal-title observation in the first run; Git collection virtualization, link batcher timing, and terminal-title observation in the second. Each distinct failed test passed when rerun alone. The full selection did not pass cleanly in this environment.
* SSH Agent wrapper contracts: **6 tests passed**; remote OMG command contracts: **8 tests passed**. The Release executable passed local/remote shell integration checks for bash, zsh, and fish, including the pre-existing shell integrations.
* Vertical tab framebuffer preparation passed its targeted integration test. The optional `VerticalTabMouseTests` could not establish `NSApp.isActive` and a foreground key window; native mouse interaction is **NOT RUN** because its unlocked foreground desktop prerequisite was unavailable.
* GhosttyKit built as ReleaseFast with both `arm64` and `x86_64` slices. The **arm64**, **x86_64**, and **universal** Release apps report OMG **0.17.1 / build 44**, bundle identifier `com.jischeng.omg`, and Ghostty base **1.3.2-dev**. Each app contains the expected architecture(s).
* All three apps use the persistent self-signed identity with designated requirement `com.jischeng.omg` and certificate leaf `9b2e176c03e5458e6fdaf73392cd9d79203972c6`. arm64 and universal apps launched with `.ReleaseFast`; x86_64 execution was **NOT RUN** because Rosetta 2 is unavailable.
* All three DMGs passed `hdiutil` verification and mounted read-only. arm64 and universal apps launched from their mounted DMGs with `.ReleaseFast`; x86_64 launch was **NOT RUN** because Rosetta 2 is unavailable. SHA-256 hashes are included in `SHA256SUMS.txt`.
* Sparkle appcast verifies **0.17.1 / build 44**, minimum macOS **13.0**, the universal enclosure URL, and its EdDSA signature. The appcast contains one new update; the numeric bundle version advances from 43 to 44.

Full Desktop/Documents/Downloads and Sparkle upgrade permission experiments are **NOT RUN**. They are not release prerequisites; static signature verification and launch probes do not establish end-to-end TCC behavior.

## Signing and distribution

Release apps reuse the **persistent self-signed identity; not notarized**. This is not Apple Developer ID distribution. Gatekeeper may block the first launch; users who trust the download can review and allow it in System Settings > Privacy & Security. Do not disable Gatekeeper globally. DMGs are not notarized. Sparkle updates retain their separate EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and `appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
