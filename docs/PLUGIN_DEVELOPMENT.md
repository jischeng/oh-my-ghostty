# OMG Plugin Development

> **Public API status:** pre-release / not externally loadable.

This document is the source of truth for OMG's plugin and host-extension
contracts. It intentionally describes only code that exists. OMG currently has
versioned protocol components and working in-process Inspector/status models,
but it does **not** discover, install, launch, or connect third-party plugin
executables in production.

A directory, manifest, or executable copied beside OMG will not be loaded.
The Experimental `PluginInstallationManager` can download a GitHub repository's
`main` archive, validate `manifest.json`, and store it under the OMG Application
Support Plugins directory, but no installed package is launched or connected to
runtime yet. There is no public SDK, socket listener, or hot reload command.

## Documentation maintenance rule

Plugin behavior is a public compatibility boundary even before the public
runtime ships. Any change to plugin APIs, `PluginManifest`, wire messages,
capabilities, lifecycle, loading/discovery, directory/package layout, Inspector
provider behavior, or plugin permissions **must update this document and the
relevant tests in the same commit**.

Contributor checklist:

```text
[ ] Did this change affect a plugin API, manifest, message, capability,
    lifecycle, loading path, directory layout, or security boundary?
[ ] If yes, were docs/PLUGIN_DEVELOPMENT.md and capability tests updated?
[ ] Are Experimental/Internal/Planned labels still accurate?
```

## Status summary

### Stable application behavior

These are connected to the running app and covered by app-hosted tests, but are
not a third-party SDK:

- host-owned `TabActivityStore` and normalized tab activity rendering;
- Core-owned Right Inspector shell, layout, selection, lifecycle delivery, and
  typed content rendering;
- owner validation and cleanup in `InspectorRegistry`;
- built-in `builtin.files` provider using the plugin-shaped Inspector boundary;
- stable terminal tab identity via `OH_MY_GHOSTTY_SESSION`.

### Experimental protocol components

These compile and have unit tests, but no production transport connects them:

- `PluginProtocolContract` v1;
- length-prefixed JSON `PluginWireCodec`;
- `PluginManifest` data model;
- nonce/version/capability intersection in `PluginAuthorizationPolicy`;
- `PluginMessageRouter` for session status set/clear commands;
- validated status ownership, revisions, TTL, icons, ACK, and failures.

### Internal host extension points

These require compiling code into OMG and are not ABI/API-stable:

- `InspectorRegistry.registerCorePane`;
- `InspectorRegistry.registerPluginPane` and `updatePluginContent`;
- `GhosttyTabMetadataProviding`;
- `GhosttyTabIconProviding`;
- `MockAgentStatusAdapter`;
- `BuiltInFilesInspectorProvider`.

### Not yet supported

- plugin discovery or manifest file loading;
- plugin package build/distribution and runtime loading;
- plugin installation is Experimental and currently only supports a GitHub main
  branch archive; update/enable/disable/uninstall are storage operations only;
- executable launch, Unix socket ingress, peer UID/PID checks, supervision,
  restart, heartbeat, or unload/reload;
- external Inspector registration/update/action messages;
- public commands, settings contributions, Sidebar model, QuickInput, terminal
  control, or raw terminal output;
- filesystem, network, shell, clipboard, settings, or storage APIs for plugins;
- SSH workspace/session integration is an in-tree provider boundary, not an
  installable external plugin yet;
- third-party sandbox/signature/permission UI;
- public SDK artifacts or a Marketplace.

## Architecture and terminology

OMG has two different mechanisms that must not be conflated.

### Process plugin contract

`macos/Sources/Features/Plugins/PluginProtocol.swift` and
`PluginHost.swift` define protocol/authorization/status components intended for
future supervised child processes.

```text
future executable
  -> 4-byte big-endian length + JSON frame
  -> authorization and capability intersection
  -> PluginMessageRouter
  -> host-owned stores and presentation
```

The executable, socket, and process supervisor do not exist yet. Today this
path is instantiated only in tests.

### In-process Inspector provider

`InspectorRegistry` is a Core-owned Swift registry. It accepts declarative data
and callbacks from code compiled into OMG:

```text
in-tree provider
  -> InspectorPaneDescriptor
  -> typed InspectorPaneContent
  -> RightInspectorHost (host rendering)
```

`BuiltInFilesInspectorProvider` uses `.plugin("builtin.files")` to dogfood
owner checks and typed content. It is still trusted application code, not an
out-of-process plugin and not proof of public plugin loading.

## Manifest model (Experimental)

`PluginManifest` is `Codable` and currently contains:

| Field | Type | Purpose | Enforced today |
| --- | --- | --- | --- |
| `id` | `String` | identity matched against hello | only when policy is manually invoked |
| `version` | `String` | plugin version matched against hello | yes in policy tests |
| `executable` | `String` | intended executable path | no loader resolves it |
| `capabilities` | `[PluginCapability]` | maximum capability allowlist | yes in policy tests |
| `minimumHostVersion` | `String?` | intended OMG compatibility floor | not evaluated |
| `settings` | `[PluginSettingDescriptor]?` | declarative setting metadata | not rendered/stored |

The default Swift `Codable` keys are camelCase. This JSON demonstrates the data
shape only; no filename or directory makes it installable:

```json
{
  "id": "dev.example.status",
  "version": "0.1.0",
  "executable": "bin/status-plugin",
  "capabilities": ["sessionStatus", "tabIcon"],
  "minimumHostVersion": "0.1.0",
  "settings": null
}
```

`PluginSettingDescriptor.ValueType` declares `boolean`, `string`,
`enumeration`, `number`, `path`, and `secret`. There is no settings renderer,
secret store, or permission behavior behind these values.

## API and protocol versioning

The wire API version is:

```swift
PluginProtocolContract.currentVersion == 1
```

A plugin hello carries:

- `pluginID`;
- `pluginVersion`;
- `supportedProtocolVersions`;
- `requestedCapabilities`;
- one-time `nonce`.

The host policy verifies manifest identity/version and nonce, requires protocol
v1 support, and grants the intersection of manifest and requested capabilities.
`PluginWelcome` returns selected protocol version, granted capabilities, and
host version.

There is no separate manifest `apiVersion`; protocol compatibility is already
negotiated through `supportedProtocolVersions`. `minimumHostVersion` exists but
is not enforced because no loader exists. Treat all process protocol types as
Experimental until an end-to-end runtime and compatibility policy ship.

Compatibility rules for future changes:

- additive optional payload fields may remain in the current protocol only when
  old decoders remain valid;
- new required semantics or message kinds require an explicit compatibility
  decision and tests;
- never reinterpret an existing capability as broader access;
- manifest and protocol changes update this guide in the same commit.

## Wire format (Experimental)

`PluginWireCodec` uses:

```text
4-byte unsigned big-endian payload length
UTF-8 JSON payload
```

Maximum payload size is 1,048,576 bytes. Empty and oversized frames fail before
JSON routing. The envelope fields are:

| Field | Type |
| --- | --- |
| `version` | UInt16 |
| `sequence` | UInt64 |
| `correlation_id` | optional UInt64 |
| `type` | message discriminator |
| `payload` | typed payload |

Message bodies implemented by the codec:

- `hello`, `welcome`;
- `subscribe`, `sessionEvent`;
- `setSessionStatus`, `clearSessionStatus`;
- `acknowledgement`, `failure`.

Encoding support does not mean every message is routed in production.
`PluginMessageRouter.handle` currently accepts only status set/clear as plugin
commands. Other bodies return `invalidMessage`.

## Capabilities

| Capability | Current behavior | Stability |
| --- | --- | --- |
| `sessionStatus` | router can set/clear validated status | Experimental component |
| `tabIcon` | permits validated icon in a status command | Experimental component |
| `terminalEvents` | event/subscription data types only | Stub |
| `tabMetadata` | enum plus separate in-process provider model | Stub for process plugin |
| `inspectorPane` | in-process typed registry works; no wire messages | Internal / process stub |
| `settingsContribution` | manifest descriptors only | Stub |
| `commands` | capability name only | Stub |
| `sidebarModel` | capability name only | Stub |
| `quickInput` | capability name only | Stub |
| `terminalControl` | capability name only | Planned, high risk |
| `rawTerminalOutput` | capability name only | Planned, high risk, default deny |

### Session status API

`setSessionStatus` arguments:

- stable terminal session UUID;
- monotonically increasing per-plugin/session revision;
- agent, state, and optional title/message/detail/progress/icon;
- optional TTL in milliseconds.

Wire states map to host activity:

| Wire | Host activity |
| --- | --- |
| `running` | `working` |
| `waiting` | `needsAttention` |
| `completed` | `done` |
| `failed` | `error` |

Validation includes session existence, owner, increasing revision, progress
`0...1`, bounded strings, bounded TTL (maximum 24 hours), and safe icon names.
A status is removed on explicit clear, TTL expiry, session deletion, or router
disconnect. Successful commands return an acknowledgement correlated to the
request sequence; failures return a typed `PluginProtocolFailure`.

### Terminal events

The following data kinds exist but no running event bridge publishes them:

- opened/closed;
- title changed;
- progress changed;
- foreground process changed;
- focus changed.

`AgentProgressStatusReducer` translates progress events in unit tests. The
planned status CLI and `OH_MY_GHOSTTY_SESSION` correlation are not implemented.

## Workspace and SSH provider (Experimental)

`WorkspaceDescriptor` and `WorkspaceFilesystem` are generic boundaries for
local and remote workspace providers. `LocalWorkspaceFilesystem` is the local
implementation used by the Files provider. `SSHPlugin` reads non-wildcard
aliases from the user's `~/.ssh/config` without owning private keys, passwords,
known_hosts, ProxyJump, or ssh-agent state. `SSHWorkspaceFilesystem` uses the
system `/usr/bin/sftp` client and the user's OpenSSH configuration for bounded
remote directory operations and file/folder creation.

The provider can resolve a workspace from an explicit `OMG_SSH_ALIAS` or from a
terminal title matching an SSH alias/hostname. The shared Files tree consumes
the provider boundary rather than branching its UI for Local versus SSH. An
SSH context is represented by an alias (`ssh:cloud`) and preserves the alias in
presentation; it never replaces it with a jump host or private IP.

This first provider does not install a remote service and does not manage
credentials. It depends on the system SSH/SFTP client and configured
`ssh-agent`/known_hosts. For a simple interactive Fish destination, OMG's
existing `+ssh` action starts a transient login-shell hook that emits standard
OSC 7 on each prompt; the focused Surface cwd therefore follows remote `cd`
without polling or a persistent helper. Other remote shells currently fall back
to the last reported cwd and remain Experimental. Remote `sftp ls -la` parsing
is intentionally bounded and is not yet a general remote file protocol.

## Inspector API (Internal)

### Descriptor

`InspectorPaneDescriptor` contains:

- stable `id` (1...128 safe characters);
- title and SF Symbol name;
- owner source (`coreFeature` or `plugin`);
- preferred/minimum width, constrained to 176...640 points.

Duplicate IDs, invalid identifiers, invalid width, and owner mismatches fail.

### Content

Host-rendered `InspectorPaneContent` supports:

- empty title/message;
- label/value fields;
- lists with optional subtitle/system image;
- recursive typed file trees.

A provider supplies data only. It cannot inject a SwiftUI `View`, `NSView`,
window, controller, material, or arbitrary icon path.

### Context, actions, and lifecycle

`InspectorPaneContext` contains tab/session presentation identity, title, and
optional working directory. Supported action values are disclosure toggle,
refresh, collapse all, create file, and create folder; whether they make sense
is provider-specific.

Actual in-process lifecycle:

```text
registerCorePane / registerPluginPane
  -> host selects and calls presentationDidChange
  -> lifecycle appeared(context)
  -> host requests typed content
  -> provider updates content / receives typed actions
  -> selection hides pane: disappeared
  -> unregister or disconnectPlugin: cleanup and disappeared
```

The Core owns Inspector visibility, width, chrome, focus, persistence, and
rendering. Hiding the Inspector does not unload a provider; it receives the
presentation lifecycle change. `disconnectPlugin` removes every pane owned by
that plugin ID and clears typed content/actions.

## Minimal working example (in-tree only)

There is no runnable third-party package example because no external loader
exists. The smallest **working** example is an app-hosted test of the internal
registry. Place this in the test target (or use the existing equivalent in
`InspectorRegistryTests`) and run the command below:

```swift
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct HelloInspectorProviderTests {
    @Test func helloPane() throws {
        let registry = InspectorRegistry()
        let pluginID = "dev.example.hello"
        let paneID = "dev.example.hello.pane"

        try registry.registerPluginPane(.init(
            id: paneID,
            title: "Hello",
            systemImage: "hand.wave",
            source: .plugin(pluginID),
            preferredWidth: 320,
            minimumWidth: 176
        ))

        try registry.updatePluginContent(
            paneID: paneID,
            pluginID: pluginID,
            content: .fields([
                .init(id: "message", label: "Message", value: "Hello from OMG")
            ])
        )

        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: nil,
            title: "Terminal",
            workingDirectory: nil
        )
        #expect(registry.content(for: paneID, context: context) != nil)

        registry.disconnectPlugin(pluginID)
        #expect(registry.isEmpty)
    }
}
```

Run:

```bash
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  "SYMROOT=$PWD/macos/build" \
  -parallel-testing-enabled NO \
  -only-testing:GhosttyTests/HelloInspectorProviderTests \
  test
```

This verifies registration, owner-scoped content, and cleanup. It does not
create an installable plugin.

### Current contributor workflow

The only end-to-end pane workflow today is an in-tree Core contribution:

```text
macos/Sources/Features/Inspector/HelloInspectorProvider.swift
macos/Tests/Inspector/HelloInspectorProviderTests.swift
```

1. Implement a provider that owns only typed data/actions.
2. Register it with the Core-owned `InspectorRegistry`.
3. Add a lazy provider property and launch-time `register()` call in
   `AppDelegate`, following `BuiltInFilesInspectorProvider`.
4. Add owner, lifecycle, content, action, disconnect, and invalid-data tests.
5. Build/relaunch OMG; there is no hot reload.

This changes and rebuilds the application. There is no manifest packaging,
installation, or enable command for an external developer yet.

## Development and debugging

Protocol component tests:

```bash
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  "SYMROOT=$PWD/macos/build" \
  -parallel-testing-enabled NO \
  -only-testing:GhosttyTests/PluginProtocolTests \
  -only-testing:GhosttyTests/PluginHostTests \
  -only-testing:GhosttyTests/InspectorRegistryTests \
  test
```

Relevant sources:

- `macos/Sources/Features/Plugins/PluginProtocol.swift`;
- `macos/Sources/Features/Plugins/PluginHost.swift`;
- `macos/Sources/Features/Plugins/AgentStatusPlugin.swift`;
- `macos/Sources/Features/Inspector/InspectorRegistry.swift`;
- `macos/Sources/Features/Inspector/BuiltInFilesInspectorProvider.swift`;
- `macos/Sources/Features/Inspector/RightInspectorHost.swift`.

Files-specific diagnostics are available in Debug builds:

```bash
log stream --level debug --predicate 'category == "files-inspector"'
```

There is no plugin hot reload. Rebuild/relaunch OMG after changing in-tree
providers. Protocol unit tests are the only supported way to exercise process
messages today.

## Permissions and security

No public plugin sandbox exists because no external runtime exists.

| Resource | Public plugin API today |
| --- | --- |
| filesystem | none |
| terminal Surface / PTY / scrollback | none |
| shell/process execution | none |
| raw terminal output | none |
| network | none |
| clipboard | none |
| OMG/Ghostty settings | none |
| persistent plugin storage | none |
| arbitrary AppKit/SwiftUI UI | prohibited by Inspector boundary |

The manifest capability intersection restricts future host IPC only. It would
not sandbox an ordinary child process from macOS filesystem or network access.
Before third-party executables ship, OMG still needs restrictive discovery,
ownership/signature validation, peer UID/PID validation, process supervision,
installation/update policy, and user-facing permissions.

`builtin.files` can access the filesystem because it is trusted in-process app
code. Its asynchronous, bounded, cancellable IO is not a permission granted to
third-party plugins.

## Failure handling

Implemented component behavior:

- empty/oversized frames fail;
- unsupported protocol versions fail;
- identity, nonce, and manifest-version mismatch fail;
- ungranted capability, missing session, stale revision, foreign ownership, and
  invalid data return typed failures;
- router disconnect removes owned ephemeral statuses;
- Inspector owner disconnect removes owned panes and lifecycle state.

Not implemented:

- child process crash detection/isolation;
- handshake timeout/heartbeat;
- bounded socket send queues;
- restart/backoff/disable policy;
- persistent diagnostics for external plugins.

Do not claim process isolation until those runtime pieces exist.

## Packaging and installation (Experimental storage only)

The first storage contract is:

```text
~/Library/Application Support/OMG/
├── Plugins/<plugin-id>/manifest.json + plugin code
└── PluginData/<plugin-id>/              user data/config boundary
```

`PluginInstallationManager` provides `install(from:)`, `update(_:from:)`,
`disable(_:)`, `enable(_:)`, `uninstall(_:removeData:)`, and `dataURL(for:)`.
The source currently must be an HTTPS GitHub repository URL. Installation
fetches the repository's `main.tar.gz`, finds `manifest.json`, validates the
plugin ID/version/relative executable path, copies code to `Plugins/<id>`, and
creates a separate data directory. Disabled state is stored in
`Plugins/disabled.json`.

Settings → Plugins exposes the official catalog and an Install from GitHub
URL field backed by this manager. The SSH official entry installs the in-tree
provider marker and enables the generic workspace provider; it does not
download private keys or a remote helper. External installed packages remain
inert. There is no signature/ownership verification, semver host compatibility
enforcement, executable launch, process supervision, or automatic update
service. Do not distribute executable plugins until those security/runtime
pieces are implemented.

When runtime loading changes, this document must add a copyable directory
layout, manifest, build/package/install commands, compatibility checks,
uninstall/data migration behavior, and end-to-end tests in the same commit.

## Planned design notes (not API)

The next runtime block described by the architecture is a private Application
Support runtime directory, per-plugin Unix socket, peer UID/PID checks, manifest
loader, enabled-plugin persistence, supervised process, bounded queues, and
status CLI. Terminal control and raw output remain high-risk and default-deny.

These notes are planning context only. They must not be used by plugins until
implementation, tests, and a stability designation land.
