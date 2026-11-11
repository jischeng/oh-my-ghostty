# Reused mobile application sources

Source: https://github.com/termio-sh/termio

Pinned revision: `819658751635eb298a467f4d84e793729c5242bc`.
Copyright (c) 2026 Jiwei Yuan. MIT; see `LICENSE.termio`.

## Source map

- `../TermioApp/`: original `ios/Sources/` application controllers, SwiftUI
  rows, navigation, keyboard, voice and resources. The original StreamTerminalView
  and WebSocketLink live in this directory instead; OMG keeps its own app icon.
- `../TermioShared/`: original `Shared/Sources/TermioShared/` models, wire v2,
  session status, icons, syntax highlighting and resources. Its package manifest
  uses local dependencies and omits the original stream-package cycle.
- `../TermioStream/`: original terminal renderer and native VT wrapper from
  `Shared/Sources/TermioStream/`, adapted to OMG's matching VT C API.
  `GhosttyKeyNames.swift` is generated from OMG's key/event header.
- `StreamTerminalView.swift`: original complete UIKit terminal view, including
  horizontal drawer/back gestures, selection, IME and accessibility.
- `WebSocketLink.swift`: original reconnect wrapper, adapted to release stopped
  URLSessions and expose OMG resynchronization.

The full UI replaces the earlier custom connection/session/activity-card shell.
There is one app navigation implementation. Original non-OMG backend sources
remain with the copied app, while paired omgd devices select `OMGSession`.

## Local adaptation seams

OMG-owned `Sources/OMGAppAdapter.swift` installs the original app in a UIWindowScene,
handles authenticated pairing/Keychain, migration and test setup. The original
AppDelegate body is retained behind `install(in:)`. Models/backends gain an
`omgd` endpoint and `StreamDeviceSession` port; terminal concrete casts use that
port. CompanionClient sends `omg.<token>` authentication and talks to `/control`
with the original Termio wire-v2 messages. Session IDs remain opaque to UI.

Small UI changes provide OMG branding, open-source notices, meaningful unknown
Git counts, rendering lifecycle notifications and accessibility identifiers.
The existing parent drawer/back gesture priority also covers StreamTerminalView,
so its scrolling recognizer cannot swallow horizontal navigation.
Visible product copy and diagnostics say OMG rather than the upstream brand;
source comments, license notices and internal compatibility type names retain
Termio where they identify the reused contract.
The original layout, project/Chats/Terminals/Needs You flows, Files/Diff/editor,
settings, accessory keyboard and input handling are retained. Root URL pairing
is verified before secrets are persisted, and tokens are stripped from defaults.

OMG's native VT builds are used for active omgd sessions. Clipboard callbacks,
prompt scrolling and synchronized rendering match OMG's headers. Control-sequence
clipboard access and unavailable Kitty image APIs are disabled; explicit UIKit
copy/paste, text, cursor, font fallback and selection remain. Context signals are
copied under the VT lock and delivered after it releases. Automatic reports are
host-owned. No additional VT parser, glyph renderer, OSC status parser, IME engine
or reconnection policy is introduced.

## Source dependencies and notices

All source dependencies are vendored for reproducible builds:

| Directory | Revision | License |
| --- | --- | --- |
| `../libghostty-swift` | `9cf32037ad8b8aec3c0de07aeb949f6872a858df` (1.2.2) | MIT |
| `../Highlightr` | `05e7fcc63b33925cd0c1faaa205cdd5681e7bbef` (2.3.0) | MIT |
| `../MSDisplayLink` | `87eb0af130744c8cbe2e31b6e1a5bcd659f1c220` (2.2.0) | MIT |

libghostty-swift's manifest omits its unrelated GhosttyVt binary product to avoid
mixing VT ABIs. Original GhosttyKit/ShellCraftKit/GhosttyTheme dependencies remain
for the donor's local fallback, including its checksum-pinned GhosttyKit binary
download. libghostty-swift uses the vendored MSDisplayLink path.
Non-build examples, repository metadata and nested agent instructions are omitted.

`ios/Licenses/` bundles these licenses, GhosttyTheme and highlight.js notices.
The repository's Ghostty and Termio MIT notices are also bundled. Remux, Orca,
Paseo and Happy are research references only; none of their code is vendored.
