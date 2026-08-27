# Tab Activity And Agent Status Contract

## Boundary

Agent-specific hooks produce normalized activity data. The app core owns correlation, state reduction, icon validation, badges, notifications and UI.

```text
Agent hook / adapter
  -> normalized status message
  -> validated plugin router
  -> TabActivityStore
  -> TabActivity
  -> host-owned tab indicator / notification policy
```

No producer receives a SwiftUI/AppKit, terminal Surface, PTY or renderer object.

## Stable Identity

Every `TerminalController` owns a persistent UUID. New terminal child processes receive:

```text
OH_MY_GHOSTTY_SESSION=<uuid>
```

The UUID is stored in TerminalRestorable v9 and is independent of cwd, title and process name. Two agents in the same repository therefore remain distinguishable. Version 9 additionally stores an optional typed Agent resume descriptor on each Surface.

The built-in first-party adapters do not require a status socket. Manifest-selected JSON hooks, plugins/extensions, TOML blocks, scripts, title signals, and bounded screen rules emit or derive process-instance-scoped OSC 3008 presentation events on the owning TTY/Surface. Reports declare `omg_liveness=pid` for in-process Plugin adapters or `omg_liveness=pgid` for shell/config hooks and foreground synthesis. The numeric context suffix is an instance identity, not universally a process-group ID. Local validation checks the declared PID or PGID; a live Plugin PID remains valid while child tools change foreground process groups. Reports may also carry a validated `omg_conversation` identity extracted from hook stdin or Pi's session manager. Because correlation is the terminal Surface that receives the sequence, the same transport works through SSH without forwarding `OH_MY_GHOSTTY_SESSION` or installing an OMG executable remotely. Hooks must be installed in the account where the agent runs; Settings can merge local hooks without replacing other integrations and can export an auditable Python 3 installer for explicit remote use.

A future public `omg status` CLI may expose the same normalized contract over authenticated app IPC. It is not required by the built-in adapters and must not become an unauthenticated terminal-control channel.

The host persists conversation identity only in a typed `AgentResumeDescriptor` attached to the owning Surface. The descriptor contains no arbitrary command or prompt content. Terminal restoration builds resume argv from the bundled allowlist; ambiguous store discovery produces no ID, and the host never substitutes a directory-wide `--last`/`--continue` guess. Agent end clears the descriptor so explicit `/quit` is respected.

Each Surface reducer keeps one ordered collection of at most 32 active Agent contexts. Updating an existing context moves it to the current position; a producer that exceeds the bound evicts the oldest context, and a later end signal for that evicted identity is ignored. This bounds terminal-controlled presentation state without allowing stale contexts to replace the newest activity.

## Core State

`TabActivityState` is agent-neutral:

| State | Meaning |
| --- | --- |
| `idle` | No visible activity state. |
| `working` | The agent is actively processing or using a tool. |
| `done` | Work finished without requiring urgent action. |
| `needsAttention` | The agent is blocked on the user; optional subtype is `question` or `permission`. |
| `error` | The agent or task failed. |

`TabActivity` carries:

- source/plugin id
- state
- optional label
- optional message and detail
- optional normalized progress (`0...1`)
- optional validated icon descriptor

The current v1 wire status names map as follows:

| Wire | Core |
| --- | --- |
| `running` | `working` |
| `waiting` | `needsAttention` |
| `completed` | `done` |
| `failed` | `error` |

## Icon And Presentation

A plugin may request a system symbol or a host-bundled asset by name. Names are bounded and validated; arbitrary paths, executable code and arbitrary views are rejected. Icon priority is:

1. validated activity/plugin icon
2. host metadata provider icon
3. terminal fallback

The host keeps the existing left icon slot. When an Agent context is active, its validated bundled brand glyph replaces terminal/cloud. Identity, title and ring follow only the focused pane; non-focused panes may contribute a trailing attention/error/done indicator but never replace focused identity. Idle has no ring; indeterminate working uses a rotating quarter-circle indicator and determinate progress uses the normalized ring fraction. Waiting, completed and failed states additionally use the existing trailing status slot. Questions use `questionmark.bubble.fill`, permission approvals use `lock.shield.fill`, and an untyped attention event keeps the generic exclamation symbol. Normal completion reports `done` even when its Tab is already focused. Tab selection and pane focus alone never acknowledge terminal states; only mouse click or keyboard input delivered to the owning focused terminal clears `done`/`error`. Confirmed loss of the declared PID or process group while `working` or `needsAttention` becomes `error` instead of disappearing; foreground-PGID changes alone never fail a live PID-backed Plugin context. Clearing the Agent context after acknowledgement restores the canonical SSH cloud or terminal icon. Notification and Dock badge behavior are separate consumers controlled by host settings.

## Adapter Responsibilities

A Codex, Claude or Pi adapter owns only dialect translation:

- detect the agent-specific lifecycle event; for local startup only, the host may
  synthesize `idle` when a changed foreground process group resolves to the
  explicit `codex`, `claude`, or `pi` executable;
- map it to `idle`, `working`, `needsAttention`, `done` or `error`;
- emit one bounded typed context event to its controlling TTY.

Current mappings are:

| Agent event | Core state |
| --- | --- |
| SessionStart | `idle` |
| UserPromptSubmit / agent_start | `working` |
| PreToolUse / PostToolUse | `working` |
| PermissionRequest / permission prompt / question tool | `needsAttention` |
| Stop / agent_settled | `done` |
| SessionEnd / session_shutdown | clear agent identity |

It does not parse terminal text or mutate the Sidebar. The host converts normalized activity into the shared tab presentation; adding a new hook adapter should not require another status renderer.

## Invalid Producers

Frame size, protocol version, capability, session existence, revision, owner, TTL, strings, progress and icon names are validated before state mutation. Invalid messages receive a bounded protocol failure and do not reach terminal state. Once process supervision exists, a crashing producer will lose only its connection and owned ephemeral statuses.
