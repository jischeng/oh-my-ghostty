# OMG 0.25.3 · Ghostty 1.4.1-dev

OMG 0.25.3 returns inherited SSH tabs and splits cleanly to an integrated local shell when SSH exits, hardens Quick Input draft bridges and PTY resize ordering over SSH and inline TUIs, eliminates residual Mission Control thumbnail flicker, and fixes multi-pane AI tab renaming.

## Highlights

### Inherited SSH Sessions & Local Shell Fallback

- **Return to the inherited local directory after exiting SSH.** Opening a new tab (`Cmd+T`) or split (`Cmd+D`) with SSH inheritance now starts an outer local pane in the pre-SSH local directory running managed `+ssh` with a survival prelude instead of a pure remote runtime descriptor, so exiting SSH (`Ctrl+D` / `exit` or `Ctrl+C`) keeps remote scrollback on screen and drops into the local login shell rather than closing the pane or tab.
- **Full Ghostty Shell Integration & directory inheritance fidelity.** Preserves Ghostty shell integration (`zsh`, `bash`, `fish`, `nushell`, `elvish`) and custom default shell commands in the fallback local shell, respects `tab-inherit-working-directory`, `split-inherit-working-directory`, and `defaultDirectory` without leaking remote `pwd` values into local shells or history, and prevents deleted local directories from short-circuiting `+ssh`.
- **Chained local directory sync & OpenSSH option handoff.** Synchronizes `localWorkingDirectory` across `PaneSessionContext`, Inline SSH restoration signals, `+ssh` replay descriptors, workspace archives, and rapid multi-hop splits/tabs before `OSC 3008` arrives, forwards common interactive OpenSSH options (including validated `-o` pairs) through `omgd` handoff, and compacts embedded remote shell integration payloads well below single-argument limits.

### Quick Input over SSH & Inline TUIs

- **Remote draft bridge & shell RC resilience.** Repaired SSH remote draft editor discovery, `bash` `errexit` and fallback RC handling, `-c` / `bash` RC editor hooks, Node-shebang `agy` detection, and `flock` cleanup on exit so Quick Input draft sync works reliably across remote shells.
- **Ordered PTY writes & inline TUI dock resizes.** Preserved strict PTY write-resize ordering, submission settle timing, inline input ordering, dock promotion, and coalesced resize delivery so opening or closing the Quick Input dock never scrambles inline TUI layouts.

### Window Presentation & Tab Naming

- **Mission Control thumbnail stability.** Eliminated residual Mission Control / Exposé thumbnail flicker paths across window presentation transitions.
- **Multi-pane auto-rename & subagent title isolation.** Fixed multi-pane automatic tab renaming and prevented subagent terminal title updates from clobbering user or primary pane tab titles.

## Version and distribution

- OMG **0.25.3**, bundle version **72**.
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.25.2`).
- Includes the changes since the published `v0.25.2` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.25.3-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.25.3-ios-unsigned.ipa`).

## Validation

- Routine change-selected quality gates (12 static/contract checks, `session-runtime` Rust and Python suites, 80 Zig tests across 8 changed files, 220 Swift suites with 0 isolated retries, and 3 iOS mobile checks including guest OMG Dev + iOS Simulator UI) and packaged artifact checks recorded by
  `dist/macos/omg_release.py` (see `.release-build/0.25.3/release-summary.md`).
- Optional `.interactiveDesktop` native drag/focus suites, XCUITest, full TCC or
  Sparkle UI upgrade experiments, Rosetta `x86_64` execution, and live remote
  Linux host containment checks were **not run** unless explicitly noted above.
