# OMG 0.6.0

OMG 0.6.0 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and adds a native Agent Quick Input workflow with per-pane prompt queues.

## Highlights

- Opens a multiline Agent Quick Input composer with `Command-Shift-E`; the shortcut and remembered composer height are configurable in OMG Settings.
- Sends drafts with `Command-Return`, queues them with `Option-Command-Return`, and dispatches one queued prompt after each normalized Agent `done` transition.
- Keeps drafts and FIFO queues scoped to their owning terminal pane, transfers them during in-process pane moves, and clears them when the pane or app closes.
- Presents queued prompts in a dedicated bottom lane with compact content-aware cards, immediate-send, edit, remove, horizontal overflow, and spring transitions without covering terminal output.
- Uses a native AppKit `NSTextView` composer with IME-aware Escape handling, standard macOS editing and Option-arrow navigation, secure image-to-temporary-path paste support, and real AppKit caret geometry for Placeholder placement.
- Reuses one resizable bottom dock and unified 1pt left, right, and bottom dividers whose 8pt hit targets overlap adjacent content instead of creating transparent gutters.
- Revalidates target Surface identity, Secure Input state, and the 1 MiB message limit immediately before every direct or delayed PTY write.

## Verification

- The complete serialized macOS app-hosted test suite passes, including Quick Input queue lifecycle, native editor, IME, image paste, real-window Placeholder geometry, pane transfer, settings, and divider coverage.
- SwiftLint, Zig formatting, JSON/schema, Plist, XIB, and `python3 dist/check_omg_docs.py` validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `10`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
