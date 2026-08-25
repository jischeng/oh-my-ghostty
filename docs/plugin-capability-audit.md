# Plugin Capability Audit

Audit date: 2026-08-21

Developer-facing status, protocol reference, and maintenance rules live in
[`PLUGIN_DEVELOPMENT.md`](PLUGIN_DEVELOPMENT.md). This matrix and that guide
must change together when implementation status changes.

Status vocabulary:

- **Done**: connected to the running app and covered by behavioral tests.
- **Partial**: useful implementation exists, but at least one production path is absent.
- **Stub**: type/capability name exists without an operational implementation.
- **Design only**: documented contract with no runtime implementation.
- **Missing**: no implementation.

## Capability Matrix

| Capability | Status | Implementation / Gap |
| --- | --- | --- |
| Discover plugins | Missing | No runtime discovery/registry loader; `PluginInstallationManager` only finds a manifest during an explicit GitHub archive install. |
| Load manifest | Partial | `PluginManifest` is Codable and the experimental installer validates `manifest.json`; no runtime loader calls it. |
| Enable/disable | Partial | Experimental installer persists disabled IDs and exposes enable/disable storage operations; no runtime lifecycle action. |
| Persist plugin state | Missing | Status entries are intentionally ephemeral; no plugin state store exists. |
| Plugin settings | Stub | `PluginSettingDescriptor` defines safe data types; no contribution registry or renderer is connected. |
| Tab icon provider | Partial | Host-owned icon provider and validated status icon descriptor render in Vertical Tabs; no discovered plugin can currently connect. |
| Tab metadata | Partial | Host-owned metadata provider and project fallback are connected; no out-of-process metadata command/router exists. |
| Inspector pane | Partial | Core host, tab-scoped typed tree snapshots/actions, persistence, shortcut, recursive `builtin.files`, diagnostics, and pane lifecycle are connected; v1 wire registration/update/action messages are not implemented. |
| Workspace filesystem | Partial | Shared local/SSH provider boundary and system-SFTP SSH provider exist; external plugin registration, remote helper, and file watching are not connected. |
| Status events | Partial | Versioned message, validation, revision/ownership/TTL store, core activity mapping, mock adapter and Vertical UI exist; no production socket/CLI ingress exists. |
| Badge / activity indicator | Partial | Host-owned per-tab activity indicator exists. Dock badge policy is not connected to plugin activity. |
| Notifications | Design only | Host settings exist; no activity-to-UNUserNotificationCenter policy dispatcher exists. |
| Commands | Stub | Capability enum exists; no command descriptor, registry or invocation router. |
| Process lifecycle | Missing | No plugin launch, monitor, restart or termination implementation; installed packages remain inert. |
| Protocol versioning | Partial | v1 handshake negotiation and frame version validation exist. Manifest compatibility is not enforced end-to-end. |
| Host compatibility | Stub | Manifest field exists; no semantic-version evaluator/loader enforcement. |
| Error isolation | Partial | Inputs have frame limits, Codable validation, status limits and failure responses. There is no supervised out-of-process runtime yet. |
| Permissions/security | Partial | Nonce/manifest capability intersection policy exists. No socket, peer UID/PID validation or executable ownership checks exist. |
| Unload/reload | Missing | Router cleanup can clear one plugin's statuses, but no loaded plugin lifecycle exists. |
| Documentation | Done | Architecture baseline, this audit, settings docs/schema, and `PLUGIN_DEVELOPMENT.md` document the current boundary and gaps. |

## What Actually Runs Today

The running app owns the normalized `TabActivity` model and validated `TabActivityStore`. The in-tree Agent Status bridge additionally reduces bounded, process-instance-scoped OSC 3008 events per Surface for Codex, Claude Code, and Pi, including idle identity, working/progress, approval, completion, error, and clear. Vertical Tabs aggregate all split activities into one identity icon slot and host-owned status presentation; Horizontal Tabs remain native Ghostty UI. `MockAgentStatusAdapter` still exercises the future process-plugin store.

No third-party executable can reach that store in a production build yet. `PluginAuthorizationPolicy`, `PluginMessageRouter` and the frame codec are tested components, not a connected daemon. `SSHPlugin` and the Agent hook bridge are trusted in-tree code using generic workspace/activity boundaries, not installable third-party plugins.

## Stable Extension Boundary

Plugins may eventually contribute only data and events:

- tab icon descriptor
- tab metadata descriptor
- normalized tab activity event
- command descriptor
- declarative setting descriptor
- lifecycle messages through a supervised transport

Plugins do not receive `NSView`, `NSWindow`, SwiftUI `View`, `TerminalController`, PTY or renderer objects. The host validates data, owns state reduction and chooses presentation.

## Required Next Runtime Block

1. Create an Application Support runtime directory with restrictive permissions.
2. Start a Unix-domain socket listener and verify peer UID/PID.
3. Discover and validate manifests without executing them.
4. Launch only enabled executables with capability-specific tokens/nonces.
5. Supervise child processes and route bounded frames through `PluginMessageRouter`.
6. Add authenticated public CLI ingress only if external producers need it; the built-in Codex/Claude/Pi adapters already use presentation-only TTY events and do not require a socket.

A plugin crash or invalid event must terminate/disable only that plugin connection. The terminal Surface, PTY and app process remain host-owned and are never passed across the boundary.
