# OMG 0.3.1

OMG 0.3.1 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and is a bug-fix release over 0.3.0.

## Fixes

- Restores local Pi, Codex, Claude, and other allowlisted Agent sessions through the user's login+interactive shell so Homebrew, nvm, mise, npm, and other shell-managed PATH entries are available. The pane returns to a login shell when the Agent exits.
- Prevents `NSWindowStackController` `expected no items` crashes during rapid Tab switching by deferring and coalescing Recently Used canonical reordering until after AppKit's selected-window transition finishes.
- Removes per-frame filesystem work from remote Vertical Tab rendering. Remote folder labels now use pure string handling instead of `URL(fileURLWithPath:)`/`lstat`, and SSH config is resolved only when the Files provider is actually created rather than from every Tab body evaluation.
- Preserves normal Agent completion and unexpected-interruption indicators until mouse click or keyboard input in the owning focused terminal, while keeping Tab selection/focus and scrolling non-destructive.
- Keeps full Vertical Tab rows hoverable/selectable while preserving the independent close button.

## Version policy

OMG remains pre-1.0. Bug-fix-only releases with an unchanged Ghostty base bump PATCH; any user-visible feature or Ghostty base/revision update bumps MINOR. Version 1.0 is never automatic and requires an explicit stable product/API milestone decision.

## Updater key migration

OMG 0.3.1 introduces an OMG-owned Sparkle EdDSA public key and a signed GitHub Release `appcast.xml`. Version 0.3.0 inherited Ghostty's upstream public key, whose private key is not owned by OMG, so 0.3.0 cannot securely install the OMG-signed 0.3.1 enclosure. Install 0.3.1 manually once; subsequent releases can be discovered and verified through Check for Updates. Automatic periodic checks remain disabled.

## Verification

- Local Agent restoration is executed in a test shell whose outer PATH intentionally cannot find Pi; the resume succeeds only after login-shell PATH initialization.
- Recently Used mode is stress-tested with rapid repeated Tab selection without mutating `NSWindowTabGroup` from AppKit's selection callback stack.
- Local, SSH-ready, and remote-Pi scroll-dispatch benchmarks run against the same 30,000-line Surface; the remote presentation path performs no filesystem/config parsing per frame.
- The complete macOS app-hosted suite, SwiftLint, documentation/schema checks, Zig formatting/tests, universal architecture validation, native arm64 launch, Rosetta x86_64 launch, mounted-DMG launch, code-signature verification, SHA-256 verification, and Sparkle appcast signature generation are release gates.

## Distribution status

The attached arm64/x86_64 manual-download DMGs and universal Sparkle updater DMG are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
