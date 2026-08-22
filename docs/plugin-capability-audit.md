# Plugin Capability Audit

Audit date: 2026-08-21

Status vocabulary:

- **Done**: connected to the running app and covered by behavioral tests.
- **Partial**: useful implementation exists, but at least one production path is absent.
- **Stub**: type/capability name exists without an operational implementation.
- **Design only**: documented contract with no runtime implementation.
- **Missing**: no implementation.

## Capability Matrix

| Capability | Status | Implementation / Gap |
| --- | --- | --- |
| Discover plugins | Missing | No plugin directory scan or registry loader. |
| Load manifest | Partial | `PluginManifest` is Codable and carries identity, version, capabilities, minimum host version and declarative settings, but no filesystem loader calls it. |
| Enable/disable | Missing | No persisted enabled set or lifecycle action. |
| Persist plugin state | Missing | Status entries are intentionally ephemeral; no plugin state store exists. |
| Plugin settings | Stub | `PluginSettingDescriptor` defines safe data types; no contribution registry or renderer is connected. |
| Tab icon provider | Partial | Host-owned icon provider and validated status icon descriptor render in Vertical Tabs; no discovered plugin can currently connect. |
| Tab metadata | Partial | Host-owned metadata provider and project fallback are connected; no out-of-process metadata command/router exists. |
| Inspector pane | Partial | Core host, owner-scoped typed registry, persistence, shortcut, and `builtin.files` provider are connected; v1 wire registration/update messages are not implemented. |
| Status events | Partial | Versioned message, validation, revision/ownership/TTL store, core activity mapping, mock adapter and Vertical UI exist; no production socket/CLI ingress exists. |
| Badge / activity indicator | Partial | Host-owned per-tab activity indicator exists. Dock badge policy is not connected to plugin activity. |
| Notifications | Design only | Host settings exist; no activity-to-UNUserNotificationCenter policy dispatcher exists. |
| Commands | Stub | Capability enum exists; no command descriptor, registry or invocation router. |
| Process lifecycle | Missing | No plugin launch, monitor, restart or termination implementation. |
| Protocol versioning | Partial | v1 handshake negotiation and frame version validation exist. Manifest compatibility is not enforced end-to-end. |
| Host compatibility | Stub | Manifest field exists; no semantic-version evaluator/loader enforcement. |
| Error isolation | Partial | Inputs have frame limits, Codable validation, status limits and failure responses. There is no supervised out-of-process runtime yet. |
| Permissions/security | Partial | Nonce/manifest capability intersection policy exists. No socket, peer UID/PID validation or executable ownership checks exist. |
| Unload/reload | Missing | Router cleanup can clear one plugin's statuses, but no loaded plugin lifecycle exists. |
| Documentation | Done | Architecture baseline, this audit, settings docs and schema document the current boundary and gaps. |

## What Actually Runs Today

The running app owns one core `TabActivityStore`. Vertical Tabs and window titles read normalized activity by stable tab session UUID. `MockAgentStatusAdapter` exercises working, done, needs-attention, idle and plugin-provided icon data through the same validated store.

No third-party executable can reach that store in a production build yet. `PluginAuthorizationPolicy`, `PluginMessageRouter` and the frame codec are tested components, not a connected daemon.

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
6. Add a small CLI that reads `OH_MY_GHOSTTY_SESSION` and sends normalized status events.
7. Implement one Agent adapter at a time: Codex hook, Claude hook, then Pi extension.

A plugin crash or invalid event must terminate/disable only that plugin connection. The terminal Surface, PTY and app process remain host-owned and are never passed across the boundary.
