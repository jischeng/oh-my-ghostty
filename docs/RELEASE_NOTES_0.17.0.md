# OMG 0.17.0 · Ghostty 1.3.2-dev

OMG 0.17.0 keeps disconnected SSH sessions recoverable, accepts Agent draft
imports from the foreground Agent, and fixes link handling across wrapped lines.
The upstream Ghostty base is unchanged.

## Highlights

- **Keep disconnected SSH sessions recoverable.** A dropped SSH transport no
  longer erases the pane's connection. OMG retains the validated OpenSSH
  arguments, the last remote directory, and any known Agent conversation, then
  offers an explicit recovery banner instead of silently degrading to a local
  shell. Staying offline — at home, on a hotel network, or after a momentary
  drop — no longer costs the destination or the conversation.
- **Choose where to reconnect.** *Reconnect Here* replaces this pane's terminal
  with a fresh connection using the saved arguments and keeps the tab/split
  layout; output from the interrupted session is discarded. *Reconnect in New
  Tab* preserves the old pane's output and any local processes you started after
  the drop. A close button dismisses the prompt and keeps the pane local.
- **Agent conversations resume only when proven.** When a remote hook recorded
  an exact conversation ID before the disconnect, reconnecting resumes that
  conversation and the banner names the Agent. Without a validated ID — for
  example after the Agent exited back to a remote shell — the pane reconnects to
  the remote shell only. A different destination never inherits another host's
  directory or conversation.
- **Recovery survives relaunches and repeated failures.** A pending recovery
  reopens as a local shell with the banner rather than connecting automatically,
  so an unreachable network does not produce connection attempts or repeated
  authentication prompts. Failed attempts preserve the remote directory and
  conversation for the next try, including when the transport fails before its
  first remote prompt.
- **Localized recovery prompt.** The banner, both reconnect actions, and the
  Agent-resume note follow the existing OMG language setting.
- **Accept Agent draft imports.** Quick Input imports drafts from the detected
  foreground Agent, opening the composer before the import so the draft lands in
  the intended pane.
- **Unify link targets across wrapped lines.** Wrapped links resolve to a single
  target with consistent hit ranges, a painted editor cursor gap is accepted as
  part of the link, and hover refreshes when the target changes.
- **Stabilize the agent composer.** The composer layout is stable while drafts
  import and duplicate imports are ignored.
- **Hide the terminal scrollbar when content fits.** A scrollbar no longer
  appears when the scrollback fits within the viewport.
- **Reduce terminal path validation latency.** Path validation no longer redoes
  redundant work on the hot path.

## Version and scope

- OMG version: **0.17.0**; bundle version: **43**.
- Ghostty base: **1.3.2-dev**, revision
  `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`, unchanged from 0.16.9.
- SSH recovery lifecycle, restoration archives, and Agent resume behavior are
  documented in `docs/PLUGIN_DEVELOPMENT.md` and
  `docs/oh-my-ghostty-architecture.md`.
- SSH reconnection restores the connection and, when proven, the Agent
  conversation. It does not revive remote processes that the remote system
  already terminated; keeping arbitrary remote work alive across a disconnect
  still requires a remote multiplexer such as tmux. No remote daemon, workspace
  UI, credential store, or automatic retry loop is introduced.
- Ordinary interactive `ssh host` panes can offer recovery when exact arguments
  are available, but process observation cannot distinguish an intentional
  logout from a failure, so those panes may show the prompt after a normal exit.
  Typed `omg +ssh` panes offer recovery on OpenSSH status 255, which also covers
  authentication and configuration errors; the prompt is not proof of a network
  fault.

## Validation status

- Strict SwiftLint passed across **459 Swift files** with zero violations. Zig
  formatting, settings JSON, documentation contract, plist, and XIB checks passed.
- Signing contracts: **17 tests, 2 optional smoke skips**; Keychain contracts:
  **15 tests, 1 optional skip**; test-selector contracts: **41 tests**; community
  documentation contracts: **7 tests**.
- The full routine Swift tier ran serially in 11 batches: **111 suites / 967
  tests passed**. One batch reported 9 layout and pasteboard assertions in
  `GitHistoryInteractionTests`, `GitHistoryNavigatorTests`, and
  `GitInspectorLayoutTests`. The same three suites fail identically on the
  unmodified **v0.16.9** tree in this environment, so the failures predate this
  release and are environment-sensitive (window metrics and clipboard state),
  not regressions from these changes.
- Zig core tests: **3478 tests passed** (17 skipped). The `zig build test` wrapper
  also drives an internal concurrent `xcodebuild test`, which reported unrelated
  failures while running in parallel; the same suites pass when run serially
  through `macos/build.nu` (**34 tests**).
- SSH wrapper contracts passed **4 tests**; the released executable passed
  offline local/remote fish shell-integration contracts for repeats, status,
  PS2, empty/cancel, resize, user hooks, and rc preservation.
- Universal ReleaseFast GhosttyKit and **arm64, x86_64, and universal** Release
  apps built successfully. All three report OMG **0.17.0 / build 43**, bundle
  identifier `com.jischeng.omg`, and Ghostty base **1.3.2-dev**; each carries
  exactly its intended Mach-O architecture(s).
- All three apps carry the persistent self-signed identity with a matching
  designated requirement (`com.jischeng.omg`, certificate leaf
  `9b2e176c03e5458e6fdaf73392cd9d79203972c6`).
- arm64 and universal apps launched with `.ReleaseFast`, both in the build
  directory and inside their read-only mounted DMGs. **Rosetta 2 is unavailable**,
  so the x86_64 app and mounted DMG were verified by signature, architecture and
  ReleaseFast marker; Intel execution was **NOT RUN**.
- All three DMGs passed `hdiutil` verification and mounted read-only. SHA-256
  hashes cover all three images.
- Sparkle appcast verifies **0.17.0 / build 43**, minimum macOS **13.0**, the
  universal enclosure URL and its EdDSA signature. The numeric version increases
  from 42 to 43.

Interactive desktop input tests and full Desktop/Documents/Downloads/Sparkle
upgrade permission experiments are **NOT RUN**. The latter are not release
prerequisites; static signature checks do not establish end-to-end TCC behavior.

## Signing and distribution

Release apps reuse the **persistent self-signed identity; not notarized**. This
is not Apple Developer ID distribution. Gatekeeper may block the first launch;
users who trust the download can review and allow it in System Settings >
Privacy & Security. Do not disable Gatekeeper globally. DMGs are not notarized.
Sparkle updates retain their separate EdDSA signature.

Release assets are arm64, x86_64, and universal DMGs, `SHA256SUMS.txt`, and
`appcast.xml`. The universal DMG is the single Sparkle updater enclosure.
