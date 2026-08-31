# OMG 0.7.0

OMG 0.7.0 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and adds pixel-smooth host scrollback plus a lower-cost Agent Quick Input transition.

## Highlights

- Scrolls primary-screen host history at sub-cell pixel precision instead of waiting for every full terminal row, with native trackpad deltas and macOS momentum preserved.
- Gives discrete mouse wheels a bounded inertial coast while keeping alternate screens, mouse-reporting applications, and live PTY output on their existing discrete paths.
- Renders one overscan row and applies the same fractional offset to text, cell backgrounds, and inline images in both Metal and OpenGL, keeping content aligned across row boundaries.
- Runs scroll animation work only while motion is active and pauses it during synchronized output, avoiding idle or frozen-frame 120 Hz renderer work.
- Keeps hit testing, selection, scrollbar jumps, history trimming, and scroll-to-bottom behavior synchronized with the continuous visual position.
- Opens, closes, and updates Agent Quick Input by reserving the final terminal layout once, then animating only overlay position and opacity instead of resizing the PTY and grid on every spring frame.
- Adds `smooth-scroll` configuration controls for `mouse`, `key`, and `jump`; the default enables mouse/trackpad smoothing while leaving key and programmatic jumps unchanged.

## Verification

- Scroll physics tests, the complete Ghostty core build, and the complete serialized macOS app-hosted test suite pass.
- SwiftLint, Zig formatting, JSON/schema, Plist, XIB, and `python3 dist/check_omg_docs.py` validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `11`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
