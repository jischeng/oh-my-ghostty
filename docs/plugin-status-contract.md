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

The UUID is stored in TerminalRestorable v8 and is independent of cwd, title and process name. Two agents in the same repository therefore remain distinguishable.

A future status CLI reads this variable automatically:

```text
oh-my-ghostty status working --message "Running tests"
```

The CLI and Unix socket listener are not implemented yet. Until they are, `MockAgentStatusAdapter` exercises the same validated core store in app-hosted tests.

## Core State

`TabActivityState` is agent-neutral:

| State | Meaning |
| --- | --- |
| `idle` | No visible activity state. |
| `working` | The agent is actively processing or using a tool. |
| `done` | Work finished without requiring urgent action. |
| `needsAttention` | The agent is blocked on the user or permission. |
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

The host renders spinners, success, attention and error indicators with theme-aware colors. Notification and Dock badge behavior are separate consumers controlled by host settings.

## Adapter Responsibilities

A Codex, Claude or Pi adapter owns only dialect translation:

- detect the agent-specific lifecycle event
- map it to one core state
- invoke the common status command with the inherited session UUID

It does not parse or mutate the Sidebar. Adding a new agent should not require changes to `VerticalTabBarView`.

## Invalid Producers

Frame size, protocol version, capability, session existence, revision, owner, TTL, strings, progress and icon names are validated before state mutation. Invalid messages receive a bounded protocol failure and do not reach terminal state. Once process supervision exists, a crashing producer will lose only its connection and owned ephemeral statuses.
