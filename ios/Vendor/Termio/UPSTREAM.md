# Termio sources

Source: https://github.com/termio-sh/termio

Pinned revision: `819658751635eb298a467f4d84e793729c5242bc`.
Copyright (c) 2026 Jiwei Yuan. MIT; see `LICENSE.termio`.

- `TermiodStreamTerminal.swift`, `TermiodStreamRenderer.swift`:
  `Shared/Sources/TermioStream/`.
- `StreamTerminalView.swift`, `WebSocketLink.swift`:
  `ios/Sources/`.
- `ReconnectPolicy.swift`: `Shared/Sources/TermioShared/`.
- `SessionStatus.swift`: unchanged `Shared/Sources/TermioShared/SessionStatus.swift`;
  supplies the working animation and completed/attention indicators. OMG adapts
  its existing runtime activity records to these presentation components.
- `TerminalInput.swift`: input values and grid geometry extracted from
  `Shared/Sources/TermioShared/TermiodProtocol.swift`.
- `RepeatingKeyButton.swift`: extracted from `ios/Sources/TerminalAccessoryBar.swift`.

Local adaptations remove package imports, add the OMG input adapter, and use
OMG's matching libghostty-vt build rather than Termio's binary framework.
Clipboard callback signatures, prompt scrolling and synchronized-render mode
handling are adapted to that C API. Clipboard reads/writes from terminal
control sequences are not enabled; explicit user copy/paste uses UIKit.
The WebSocket wrapper additionally releases stopped URLSessions and exposes
stream resynchronization through its existing reconnect policy.
The terminal signal adapter also forwards OMG's existing libghostty
context callback (OSC 3008/7501) for live agent presentation. Strings are copied
inside the callback; the recipient updates presentation data without re-entering
the locked terminal. The native VT parser retains fragmented/snapshot-continuation
handling, including those context signals.
Kitty image placement rendering and animation are disabled because the pinned
Termio fork uses additional C APIs absent from OMG's current VT headers.
The renderer still uses Termio's text, selection, font fallback and cursor paths.
No independent VT parser, glyph renderer, IME engine or reconnection policy is
implemented by OMG.

`GhosttyKeyNames.swift` is generated from OMG's `include/ghostty/vt/key/event.h`.
