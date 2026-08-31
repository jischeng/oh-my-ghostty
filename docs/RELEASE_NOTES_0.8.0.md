# OMG 0.8.0

OMG 0.8.0 adds automatic lifecycle handling for ordinary interactive SSH sessions on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`).

## Highlights

- Recognizes ordinary interactive `ssh host` foreground processes as SSH panes without requiring an `omg +ssh` alias or manual reconnection.
- Excludes forwarding, control, no-command, and explicit remote-command SSH invocations from pane classification to avoid false remote workspaces.
- Uses validated remote Agent working-directory metadata to complete inferred SSH workspace presentation while keeping typed `omg +ssh` lifecycles authoritative.
- Automatically returns inferred SSH panes to local presentation when the foreground process group returns to the local shell after a normal or network-driven disconnect.
- Clears orphaned remote Agent icons, activity, and resume state on both inferred and typed SSH disconnects, while process-group and connection identities prevent stale events from clearing newer sessions.
- Reconciles existing stale remote Agent presentation on the first foreground observation, so affected panes self-heal without user input.

## Verification

- Foreground SSH classification, inferred lifecycle, stale disconnect, remote Agent cleanup, and existing SSH replay tests pass with the complete serialized macOS app-hosted suite.
- SwiftLint, Zig formatting, JSON/schema, Plist, XIB, and OMG documentation validation pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `14`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
