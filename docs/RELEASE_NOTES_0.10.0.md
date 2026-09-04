# OMG 0.10.0

OMG 0.10.0 introduces built-in Agent History inspection with remote SSH support, SSH image uploads on paste, quit confirmation settings, accessibility text insertion, and hardened undo safety on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`).

## Highlights

- **Agent History Inspector:** Adds a built-in Inspector provider for browsing, searching, resuming, and forking local and remote AI agent conversations (supporting Pi, Claude Code, Codex, and OpenCode).
- **Remote Agent History for SSH:** Discovers and searches agent session transcripts on remote SSH hosts using batched discovery and per-host caches without taxing local disk I/O.
- **SSH Image Paste:** Pasting an image into an SSH terminal automatically uploads the image to the remote host and inserts the remote path into the terminal or Quick Input composer.
- **Hardened Undo & Quick Input Safety:** Isolates the Agent Quick Input text composer with a dedicated local UndoManager to eliminate range mismatch crashes on `Command-Z`. Prevents terminated split panes from registering zombie undo restorations, and wraps undo/redo dispatches in Objective-C exception guards to ensure unhandled AppKit exceptions never terminate the app.
- **Quit Confirmation Preference:** Adds an opt-in `window.confirmQuit` configuration setting to prompt before closing the application when multiple windows or running processes are open.
- **Accessibility Text Insertion:** Allows accessibility-driven clipboard managers and input utilities to commit eventless text insertions smoothly.

## Verification

- The complete serialized macOS app-hosted test suite, SwiftLint, Zig formatting, JSON/schema, Plist, XIB, and OMG documentation validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `17`.

## Distribution status

The locally generated arm64, x86_64, and universal DMGs are ad-hoc signed and are not Apple-notarized. They are published alongside the release tag with SHA256 checksums and Sparkle appcast metadata.
