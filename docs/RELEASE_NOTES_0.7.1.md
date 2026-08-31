# OMG 0.7.1

OMG 0.7.1 is a focused rendering fix on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`).

## Highlights

- Makes terminal content reflow during Sidebar, Inspector, split-divider, and Agent Quick Input resizing configurable in Settings > Terminal.
- Defaults to reflowing once when the resize interaction ends, avoiding repeated terminal-grid work while preserving the final PTY dimensions and normal scrollback behavior.
- Offers an optional During Drag mode that continuously reflows the terminal model and renderer on the IO thread while publishing child PTY sizes separately, preventing intermediate SIGWINCH redraw storms.
- Preserves OSC 133 prompts during visual-only live resize so Starship and powerline prompts no longer disappear or flicker while waiting for the shell to receive a committed size.
- Coalesces live visual resize work independently from ordinary terminal resizes and commits the final child PTY geometry without repeating terminal reflow.

## Verification

- Resize, prompt-redraw, and settings migration tests pass together with the complete Ghostty core build and serialized macOS app-hosted test suite.
- SwiftLint, Zig formatting, JSON/schema, Plist, XIB, and `python3 dist/check_omg_docs.py` validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `12`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
