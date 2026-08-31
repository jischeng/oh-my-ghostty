# OMG 0.7.2

OMG 0.7.2 is a focused stability release on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`).

## Highlights

- Preserves each terminal tab's scrollback position when switching tabs with Command-number shortcuts and returning to a session.
- Keeps a history viewport stable when copying or cutting selected terminal text with Command-C or Command-X.
- Prevents synthesized key-release events and macOS Command shortcuts from being treated as ordinary typing that should jump to the live prompt.
- Repairs stale smooth-scroll bottom-pin state before render-only wakes from selection, copying, or focus changes can override the terminal's current history viewport.
- Distinguishes idle Pi background work from active foreground work in tab activity state while keeping user-attention signals visible until acknowledged.

## Verification

- Targeted viewport-typing, stale-bottom-pin, and complete ScrollPhysics tests pass.
- SwiftLint, Zig formatting, JSON/schema, Plist, XIB, OMG documentation, complete Ghostty core, and serialized macOS app-hosted validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `13`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
