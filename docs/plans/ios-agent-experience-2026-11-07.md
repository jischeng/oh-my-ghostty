# OMG iOS agent experience

Scope: Codex, Claude Code, Pi and Antigravity (`agy`). Keep the existing omgd
session, generation and process as the identity when moving between Mac and
phone. This document separates implemented status presentation from proposed
chat/control features.

## Source inspection

Inspected on 2026-11-07, using pinned GitHub source trees:

| Project | Revision | License inspected | Useful pieces |
| --- | --- | --- | --- |
| [Termio](https://github.com/termio-sh/termio) | `819658751635eb298a467f4d84e793729c5242bc` | MIT | UIKit navigation, SwiftUI session rows/indicators, device roster and Needs You grouping; matches our existing terminal components |
| [Orca](https://github.com/stablyai/orca) | `de4cacd3a69669387cc7573e01f66e026ac358d9` | MIT | React Native/Expo mobile chat, structured permission identity/revision, Pi RPC and Antigravity ACP presentation |
| [Paseo](https://github.com/getpaseo/paseo) | `751dc82e6c4d113b357a80593089b935113aa65c` | Apache-2.0, with third-party exceptions | Provider capabilities, shared timeline, Pi CLI RPC adapter and Antigravity provider plugin |
| [Happy](https://github.com/slopus/happy) | `3c8877cae9444649d35e9110c503ba31ff9d5208` | MIT | Native Swift/UIKit chat, composer, history paging and permission button models; candidate for a later native chat port |

Termio already supports agents on iPhone. We previously copied the terminal
surface, renderer, key handling and transport, not its roster/status screens.
Its README's optional TUI-to-GUI mobile rendering is still listed as a roadmap
item; existing agent support should not be mistaken for a complete structured
chat interface.

Orca/Paseo UI components are TypeScript/React Native, so whole-screen copies
would introduce a second UI stack and their backend contracts. Happy now has
a native client, but its README requires iOS 26/Swift 6.2 and its lists depend
on UltraView. OMG currently targets iOS 17. Assess individual components and
their dependencies before importing; do not silently raise OMG's deployment
target or transplant an entire application.

Only Termio code is newly vendored in this step. Orca, Paseo and Happy remain
source/design references; their code has not been copied into OMG.

One concrete AGY difference matters before transplanting a driver: Orca has an
ACP dialect that preserves offered question/permission options, while Paseo's
inspected Antigravity driver launches `stream-json` and includes
`--dangerously-skip-permissions` in its default arguments. Reuse appropriate
framing/presentation code, not another application's launch/approval defaults.
OMG's existing Antigravity hook manifest reports working/done through
PreInvocation/PostToolUse/Stop; it does not establish complete permission
question coverage. Validate that separately with the installed AGY version.

### Concrete source entry points

- Termio: `Shared/Sources/TermioShared/SessionStatus.swift`,
  `ios/Sources/SessionListUI.swift`, `ios/Sources/RosterStore.swift`,
  `ios/Sources/ProjectListViewController.swift`.
- Orca: `mobile/src/session/native-chat/input/mobile-native-chat-permission.ts`,
  `mobile-native-chat-permission-send.ts` in the same directory,
  `src/main/acp/acp-dialects/antigravity-dialect.ts`,
  `src/main/pi/rpc-launch.ts`.
- Paseo: `docs/providers.md`,
  `packages/server/src/server/agent/providers/pi/cli-runtime.ts`,
  `plugins/antigravity-provider/server/internal/process.ts`.
- Happy: `packages/happy-ios/README.md`,
  `Sources/HappyCore/Chat/ChatContracts.swift`,
  `Sources/HappyCore/ChatDisplay/ChatPermissionButtons.swift` under that package.

## Superseded first slice and current implementation

The initial custom terminal activity card was superseded on 2026-11-07 following
the user's correction: copy the complete Termio iOS application, including UI,
and adapt its backend. That custom card and phone-side activity reducer have
been removed. The current source reuses projects, agent session rows, Needs You,
Chats/Terminals, drawer, Files/Diff/editor and Settings from the pinned donor.

`omgd mobile /control` serves the original wire-v2 roster and actions. A bounded,
capability-gated holder activity mirror supplies live status without attaching a
VT viewer for every list row. OMGSession adapts the original terminal screen to
the existing generation-bound byte transport and writer contract. This full port
**does change session-runtime** for the control API and lightweight presentation
capability; existing processes are not upgraded. Details and acceptance scope
are maintained in [ios/README.md](../../ios/README.md).

The remaining sections record possible future structured-chat work, not a plan
to replace the copied UI with a custom application.

## Product direction

The phone's first question is "what needs my attention?". Make that the entry
point, followed by the existing sessions grouped by project/device. Each row
should expose agent, state, project and a short preview without requiring a
terminal visit.

Within a session, retain one identity and three views:

```text
Needs You / Sessions
    |
    +-- same session UUID + generation
          |
          +-- Conversation: readable messages, tool cards, multiline composer
          +-- Terminal: existing full TUI, same writer transfer
          +-- Changes: files/diff preview relevant to this session
```

Connection state and agent state are separate. "Disconnected" must not become
"agent finished". Opening a view observes; entering an interactive operation
uses the runtime's existing writer contract. A completed turn is calm; a
permission/question is actionable. Touch targets and text input should fit
a phone rather than reproducing desktop window chrome.

## Next slices and dependencies

1. **Live Needs You roster (implemented by full Termio port).** The host sends
   bounded UUID/generation-bound summaries from holder mirrors; the original
   donor UI performs grouping. No full terminal snapshot is opened per row.
2. **Readable conversation history (initial implementation).** The mobile
   Agent page reuses OMG's `AgentHistoryStore` through the packaged host helper,
   resolves the live session's exact UUID/generation/resume descriptor, and
   renders normalized messages in a phone conversation. The composer writes
   through the same PTY writer grant; Terminal remains available for approvals.
   Paging/background refresh and richer tool-call cards remain follow-up work,
   and the phone still carries no provider log parser.
3. **Structured input/questions/permissions.** Use explicit provider capabilities
   and the exact pending request ID/revision/options. Orca's permission identity
   and Paseo's provider contracts are useful references; Happy separates
   button presentation from replies. A permission response must remain bound
   to the current agent session/request and acknowledged by its host. Never
   infer an approval command by searching terminal text or blindly typing `y`.
4. **Background notifications and attachments.** Build on confirmed host state
   and durable request identity after the foreground workflow works. These
   are separate from local terminal reconnection and need their own transport,
   privacy and device acceptance work.

### The existing-TUI constraint

Paseo's Pi runtime launches an RPC process; Orca also has a Pi RPC launch path
and an Antigravity ACP dialect. Such adapters do not establish that an
arbitrary, already-running interactive CLI can switch to structured mode in
place. The same caution applies to importing a conversation into another
provider-owned runtime.

For an existing omgd TUI, keep terminal interaction and expose capabilities
honestly. Enable a structured control only when a validated bridge can control
that same live agent. Starting/resuming a separate provider process is a new
operation, not transparent attachment to the original PID.

## Acceptance

The full-app suite drives the original project/session/Needs You and drawer UI,
with explicit synthetic Codex working, Claude permission, Pi done and Antigravity
working reports. Mac GUI reclaim and phone relaunch retain the actual session
UUID, generation and PIDs. It also exercises editing/diff and terminal creation /
closure. See the current test runner and `ios/README.md` for measured results.
This verifies the presentation/protocol path; real-provider inference and all
four CLIs' hook coverage require an authenticated test host.

Mobile tests remain change-selected. Reuse the retained `omg-test` VM; the user
explicitly chose this work as the primary line and rejected a separate clone.
