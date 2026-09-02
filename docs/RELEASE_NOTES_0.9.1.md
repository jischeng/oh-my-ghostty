# OMG 0.9.1

OMG 0.9.1 improves the Agent Quick Input workflow on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`).

## Highlights

- Treats the expanded Agent Quick Input composer as part of macOS `Option-Command` directional focus navigation.
- Moves from the lowest terminal split into Quick Input with `Option-Command-Down`, returns to the terminal with `Option-Command-Up`, and supports moving from the composer into an adjacent split with left/right.
- Preserves normal split navigation when another terminal split exists in the requested direction.
- Adds an opt-in Settings > Keyboard preference to expand Quick Input when the focused Pane first enters an Agent activity context.
- Keeps the new automatic presentation preference disabled by default and never steals terminal keyboard focus.

## Verification

- Agent Quick Input focus resolution, Agent-start presentation policy, settings defaults, persistence, schema registration, and localization tests pass.
- The complete serialized macOS app-hosted suite, SwiftLint, Zig formatting, JSON/schema, Plist, XIB, and OMG documentation validation are required before packaging.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `16`.

## Distribution status

The locally generated arm64, x86_64, and universal DMGs are ad-hoc signed and are not Apple-notarized. They are local test artifacts and are not published as a GitHub Release. Sparkle enclosure integrity, if generated, does not replace Apple Developer ID signing or notarization.
