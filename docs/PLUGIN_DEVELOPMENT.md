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
- stable terminal tab identity via `OH_MY_GHOSTTY_SESSION`;
- manifest-driven built-in Agent adapters using bounded OSC 3008 presentation
  events on the owning Surface.

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
- `AgentContextSignalReducer` and `AgentHookInstaller`;
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
commands. Other bodies return `invalidMessage`. The built-in agent adapters do
not pretend this future process transport exists: they normalize agent-native
hooks into a separate bounded, presentation-only OSC path owned by Core.

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
| `quickInput` | built-in host composer and per-Surface queue work; no process-plugin wire messages | Internal / process stub |
| `terminalControl` | built-in user-confirmed QuickInput writes work; no process-plugin wire messages | Planned, high risk |
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

The in-tree OSC adapter can additionally retain an `idle` `TabActivity` so the
agent identity icon remains visible while its TUI is connected but not running a
turn. A `working` activity may carry the internal `background` phase when Pi's
foreground loop is idle but package-owned asynchronous work remains. Neither is
a new v1 process-plugin wire state.

Validation includes session existence, owner, increasing revision, progress
`0...1`, bounded strings, bounded TTL (maximum 24 hours), and safe icon names.
A status is removed on explicit clear, TTL expiry, session deletion, or router
disconnect. Successful commands return an acknowledgement correlated to the
request sequence; failures return a typed `PluginProtocolFailure`.

### Built-in agent hook bridge (Internal)

`AgentHookInstaller` installs only the closed mechanism selected by each bundled
manifest: nested JSON, Cursor/Copilot/Reasonix flat JSON, Pi-compatible or
OpenCode/Amp plugins, marker-delimited Kimi TOML, and event-named Cline scripts.
It never removes unrelated JSON/TOML entries, never overwrites a non-OMG Cline
script, rejects malformed config rather than replacing it, uses atomic
mode-preserving writes (0600 for new files), and keeps a one-time `.omg-backup`
beside each existing file. Removal deletes only OMG-owned commands or blocks.

Antigravity, Crush, and Hermes do not expose a supported vendor hook path. Their
Install action therefore creates a Host-owned, versioned detector marker under
`~/.config/oh-my-ghostty/agent-detectors/<agent>.json`; the directory is mode
0700 and each exact allowlisted marker is mode 0600. The host enables process and
bounded screen detection for these agents only while the current marker exists.
Remove deletes only a regular marker whose owner/agent fields match OMG, and
Update replaces stale marker content. A one-time global sentinel migrates the
three previously implicit detectors to Installed; after that, a user removal is
never auto-installed again. Conflicting or non-file content fails closed. These
markers are local Host policy and are intentionally excluded from
the exported remote hook installer; OMG does not claim to install a vendor hook
that does not exist.

Adapters emit OSC 3008 contexts with IDs
`omg-agent-<allowlisted-agent>-<numeric-instance-id>`, `type=app`, a bounded
`omg_state`, `omg_scope=local|remote`, `omg_liveness=pid|pgid`, optional
validated `omg_conversation`, optional validated `omg_cwd` (the session's
own project directory, used for directory-scoped resume), optional
`omg_attention=question|permission`, and optional `omg_phase=background` for a
`working` Pi context whose foreground loop is idle while an owned
`pi-subagents` run or `pi-background-tasks` task remains active. Pi-compatible
and other in-process Plugin
adapters use their process PID as the instance/liveness identity; shell/config
hooks and host foreground synthesis use the process-group ID. The host verifies
that ID and metadata name the same built-in agent, then associates the event
with the Surface that parsed it. During migration, missing `omg_liveness`
retains the historical meaning based on the manifest hook kind. Because some
agent versions defer or omit `SessionStart`, the macOS host samples Ghostty's
foreground process-group PID once per second; only when that PID changes does a
utility-queue `ps` lookup apply manifest process markers and synthesize `idle`
for an enabled integration. Local startup then gets a four-second foreground
handoff grace, after which validation keeps the identity while its declared PID
or process group exists and clears it when that identity exits. A Plugin PID is
not compared directly with the foreground process-group ID, so wrappers and
child tool execution cannot create a false `error` while the Agent is alive. In SSH, no
local process-name fallback is attempted; the next authenticated remote
Fish/bash/zsh prompt clears orphaned remote agent state.
Unique instance IDs prevent an old `end` from clearing a newer same-agent
session. Each Surface keeps one ordered, 32-context reducer; exceeding the bound
evicts the oldest identity while preserving the newest presentation, and later
signals for an evicted identity are ignored. An `end` or failed local liveness
check while the current state is
`working`/`needsAttention` becomes a terminal `error` rather than silently
clearing; normal completion remains `done`. Pi `session_shutdown` first returns
the context to `idle` and then ends it, so Ctrl-D and session replacement clear
identity instead of leaving a false completion badge. Tab selection and pane focus do not
acknowledge either state. Only mouse click or keyboard input delivered to the
owning focused terminal clears `done`/`error`. These events can change
only host-owned tab presentation; they do not authorize terminal input,
filesystem, network, or plugin execution. A process can spoof its own tab badge,
but cannot use this channel to gain capabilities.

Agents that declare `titleStatus` patterns also derive activity from the
terminal title while no typed hook event owns the context. When the title no
longer matches a working pattern the host downgrades that title-derived
`working` state to `idle`, so the ring clears once the agent settles instead of
spinning forever. Agents without `titleStatus` (including the screen-detected
Antigravity/Crush/Hermes) are unaffected by this title path.

Because the event is written to the owning TTY, the same hook works through
OpenSSH. Shell hooks resolve the target TTY from the parent process with
`ps -o tty=` and keep the process-group ID for the instance context; when that
lookup yields no usable TTY they fall back to `/dev/tty` rather than silently
exiting, which is what Pi-compatible extensions already use. Hooks must be
installed in the account where the agent executable runs.
Settings can export an auditable Python 3 installer for explicit transfer and
execution on that account; OMG does not log in or silently modify remote dotfiles.

Agent glyphs use MIT-licensed assets from LobeHub `lobe-icons` 1.94.0,
Termio, OMP/oh-my-pi, and Reasonix. Product names and marks remain trademarks
of their respective owners; the assets do not imply vendor endorsement.

### Built-in agent manifests and restoration (Internal)

Bundled `Agent*Manifest.dataset` JSON files are the single data source for each
allowlisted agent's command, icon, optical scale, process markers, hook
kind/dialect/path/events/identity fields, status rules, resume argv, and on-disk
store/discovery mechanism. The roster covers Codex, Claude Code, Pi, Qoder CLI,
Reasonix, OMP, OpenCode, Amp, Antigravity, Cline, Copilot, Crush, Cursor Agent,
Droid, Grok, Hermes, Kimi, and Qwen Code. Manifests can select only closed host
mechanisms; they cannot inject Swift, shell, or arbitrary remote commands. Hook
`dialect` is a closed, decoded enum (`amp`, `cline`, `copilot`, `cursor`, `flat`,
`kimi`, `nested`, `opencode`, or `pi`); unknown values reject the bundled
manifest instead of silently falling through to another hook shape. Local hook
installation and the exported remote installer derive JSON hook entries from
the same typed builder.

`AgentResumeDescriptor` persists only a version, allowlisted agent, bounded ASCII
conversation ID, local/remote scope, cwd, and validated `SSHReplayDescriptor`.
Terminal restoration v9 stores this descriptor on its owning Surface. Local
restore builds only allowlisted resume argv such as `codex resume <id>`,
`claude --resume <id>`, or `pi --session-id <id>`. Ghostty's outer `/bin/sh`
does not inherit shell-managed PATH entries, so the argv is executed by the
user's login+interactive shell; this resolves Homebrew/mise/npm-installed Agent
binaries without storing arbitrary PATH or command data. The pane falls back to
the login shell when the Agent exits. macOS wraps every Surface command as
`exec -l <command>`, so restored commands are grouped inside a
`/bin/sh -c '<command>; exec -l <login shell>'` survival wrapper. The inner
login exec matches a normal terminal launch and reloads login-only prompt setup;
without the inner shell the outer exec discards the post-Agent command and the pane closes
the moment the Agent exits.
Remote restore replays original OpenSSH argv and passes only typed
`--remote-agent` / `--remote-agent-session` options to `+ssh`; the detected
Fish/bash/zsh shell restores cwd, emits a ready context, runs the allowlisted
resume command, then returns to its interactive prompt. When the conversation
ID is absent (the Agent exited back to a remote shell), the restore command
reconnects `+ssh` without `--remote-agent` so the pane lands in the remote
shell instead of spawning a fresh Agent session.

Each Surface also persists an `SSHResumeDescriptor` (validated SSH replay argv,
last ready remote cwd, and pre-SSH local cwd) whenever an `omg +ssh` connection
is active, independent of any Agent session. On restore, panes without a
usable Agent resume descriptor replay `+ssh` with the recorded remote cwd and
survival wrapper, so plain SSH tabs reconnect instead of degrading to a local
shell. The descriptor clears when the connection ends, matching the split
replay lifecycle.

Conversation identity comes from hook stdin (`session_id`), Pi-compatible
`sessionManager.getSessionId()`, OpenCode events, Reasonix's bounded machine JSON
command, or bounded cwd+creation-time JSONL discovery.
Multiple candidates are ambiguous and never resolved using `--last` or
`--continue`. Agent end or the first resumed SSH prompt clears the descriptor,
so a tab whose user explicitly ran `/quit` restores as a shell.

Resume lookup is directory-scoped for agents such as Pi (`pi --session-id <id>`
searches only the current project's sessions), and `pi resume` can start a
conversation owned by a directory other than the shell's current one. Hooks
that can observe the session's own project directory report it as validated
`omg_cwd` on the session signal (Pi-compatible adapters read
`sessionManager.getCwd()`); the resume descriptor prefers that directory over
the pane's shell cwd for both local and remote restoration, so the resumed
agent lands in the directory that owns the conversation instead of creating a
new one. When `omg_cwd` is absent (older hook, or an agent that cannot report
it), restoration keeps using the pane cwd.

### Terminal events

The following general process-plugin data kinds exist but no running external
event bridge publishes them:

- opened/closed;
- title changed;
- progress changed;
- foreground process changed;
- focus changed.

The planned public status CLI and authenticated app IPC are not implemented.
`OH_MY_GHOSTTY_SESSION` remains the stable Tab identity for the future process
plugin path; the built-in hook bridge is correlated directly by Surface.

## Workspace and SSH provider (Experimental)

`WorkspaceDescriptor` and `WorkspaceFilesystem` are generic boundaries for
local and remote workspace providers. `LocalWorkspaceFilesystem` is the local
implementation used by the Files provider. `SSHPlugin` reads non-wildcard
aliases from the user's `~/.ssh/config` without owning private keys, passwords,
known_hosts, ProxyJump, or ssh-agent state. `SSHWorkspaceFilesystem` uses the
system `/usr/bin/sftp` client and the user's OpenSSH configuration for bounded
remote directory operations and file/folder creation.

Tab presentation is a zero-I/O consumer of this boundary: remote folder names
are derived with pure POSIX string handling, and `WorkspaceDescriptor` identity
comes directly from the validated `sshReady` alias/cwd. It does not call
`URL(fileURLWithPath:)`, `lstat`, or parse `~/.ssh/config` from a SwiftUI row
body. OpenSSH configuration is resolved only when `WorkspaceFilesystemFactory`
actually creates the Files provider; a missing alias yields an unavailable SSH
filesystem and never falls back to local I/O.

The production path does not infer active SSH ownership from a GUI-process
environment variable or a human-readable terminal title. Each Surface has one
`PaneSessionContext` with these transient states:

```text
local
  -> sshConnecting(connection ID, alias)
  -> sshReady(connection ID, alias, remote cwd)
  -> local
```

Tab title, Tab icon, `InspectorPaneContext`, and the Files filesystem target all
consume this same state. `WorkspaceDescriptor` remains data identity and does
not own connection lifecycle. A new connection ID supersedes an older one, and
an end event only clears the matching active ID, preventing late host-A events
from clearing host B.

The lifecycle transport is typed OSC 3008 hierarchical context signalling. For
a simple interactive Fish, bash, or zsh destination, OMG's existing `+ssh`
action emits a `type=remote` start immediately before launching the final
OpenSSH child. That local start includes the percent-encoded pre-SSH cwd as
`localcwd`, so the snapshot does not depend on the ordering of asynchronous pwd
and context callbacks. Surface restoration explicitly injects
`OH_MY_GHOSTTY_CHANNEL` into each reconstructed PTY configuration. Restored
split trees therefore retain the correct `OMG` versus `OMG Dev` replay-storage
boundary even though they do not receive the fresh tab's per-Surface session
configuration. The transient remote prompt updates that same context ID
with `targethost` and a bounded cwd (`cwd` percent encoding for Fish or `cwdhex`
for shell-neutral startup hooks), and also emits standard OSC 7. Bash and zsh use a
mode-0600 temporary rc file/directory that sources the user's normal rc, installs
one prompt callback, and deletes itself before the first prompt; no persistent
remote file or service is installed. Shell selection happens inside the final
OpenSSH child, so multi-hop aliases do not incur a separate shell-detection
login. After `childExec` returns
for normal `exit`, Ctrl-D, authentication/network failure, or remote close,
`+ssh` emits the matching end from the actual child-process wait path and then
re-emits the inherited local cwd as OSC 7. It never parses `Connection closed`
or other terminal output. This is an in-process first-party lifecycle bridge,
not a new external plugin wire capability and not authorization for arbitrary
filesystem/network access.

On begin, `PaneSessionContext` snapshots the local cwd/title. On a matching end,
it atomically clears remote identity and restores that local snapshot before
Files refreshes. Connecting contexts continue to use the known local target;
only `sshReady` may construct `SSHWorkspaceFilesystem`. A ready context whose
SSH alias is unavailable returns an unavailable filesystem and never falls back
to local IO at a remote-looking path.

While an interactive SSH connection is active, `+ssh` also writes a bounded,
mode-0600 replay descriptor under
`~/Library/Application Support/OMG/SSHReplay/<connection-id>.json` for Release
or `~/Library/Application Support/OMG Dev/SSHReplay/<connection-id>.json` for
Debug. Replay writing requires either a per-tab `OH_MY_GHOSTTY_SESSION` or the
process-level channel marker, so restored Surfaces remain eligible without
making arbitrary standalone `+ssh` invocations part of app session state. It contains
the original OpenSSH executable, wrapper policy flags, and exact argv. The
validated descriptor is captured on the matching `PaneSessionContext.SSH` when
the lifecycle starts, so later Agent contexts and descriptor-file timing cannot
turn an active SSH split into a local shell. A split created from that Surface
uses only this matching active lifecycle and launches a new `omg +ssh` child
through `SurfaceConfiguration.command`; it does not inject keystrokes,
reconstruct options from `~/.ssh/config`, or connect to the resolved IP. The
ready remote cwd is passed as a separately shell-quoted wrapper option so the
independent remote shell starts in the same folder. On macOS the replay and its
post-disconnect interactive shell are grouped inside `/bin/sh -c`, because the
platform command launcher prepends an outer `exec -l`. After SSH disconnects,
the inner shell uses `exec -l` as well so fish/zsh login prompt setup is restored;
without that inner shell, the outer exec discards the post-SSH command and the
split exits. Embedded
surface commands now honor `wait_after_command` independently instead of
forcing it on whenever `command` is present. SSH replay splits leave it off, so
the first EOF returns to the local survival shell and a second EOF closes the
split normally rather than showing a terminal `Process exited` hold screen.
Therefore config aliases retain ProxyJump and other OpenSSH configuration, and
explicit direct invocations retain their original arguments. A new split uses
this replay path, while a new tab remains a local session: when tab cwd
inheritance is enabled it replaces the remote pwd with the `localcwd` snapshot;
when inheritance is disabled it leaves the directory unset so Ghostty applies
the configured home/custom/default working directory.
The descriptor is removed when the owning OpenSSH child exits and stale files
older than 24 hours are rejected. The same validated replay snapshot is
persisted on the Surface as `SSHResumeDescriptor` (with the ready remote cwd and
the pre-SSH local cwd) so app restoration can reconnect plain SSH tabs after a
relaunch, not only Agent and split panes. This is an internal first-party launch handoff,
not plugin storage or a public plugin API.

This first provider does not install a remote service and does not manage
credentials. It depends on the system SSH/SFTP client and configured
`ssh-agent`/known_hosts. Shells other than Fish, bash, and zsh do not yet publish
a ready remote cwd and remain Experimental. Remote `sftp ls -la` parsing is
bounded and is not yet a general remote file protocol.

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

`InspectorPaneContext` contains tab/session presentation identity, title,
optional working directory, workspace identity, and the canonical
`PaneSessionContext`. Providers can therefore distinguish local,
`sshConnecting`, and `sshReady` changes without parsing titles. A connection
begin, remote cwd update, matching disconnect, focused Pane change, or local cwd
change produces a new context/lifecycle appearance for the selected provider;
the previous appearance is discarded and its asynchronous work must not
publish afterward. Supported action values are disclosure toggle, refresh,
collapse all, create file, and create folder; whether they make sense is
provider-specific.

Actual in-process lifecycle:

```text
registerCorePane / registerPluginPane
  -> host selects and calls presentationDidChange
  -> lifecycle appeared(context)
  -> host requests typed content
  -> provider updates content / receives typed actions
  -> selection/context hides pane: disappeared(previousContext)
  -> unregister or disconnectPlugin: cleanup and disappeared
```

The Core owns Inspector visibility, width, chrome, focus, persistence, and
rendering. Hiding the Inspector does not unload a provider; it receives
`disappeared(previousContext)` so it can cancel work owned by that exact tab and
session. `disconnectPlugin` removes every pane owned by
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

The first storage contract is channel-specific:

```text
~/Library/Application Support/OMG/       # Release
~/Library/Application Support/OMG Dev/   # Debug
├── Plugins/<plugin-id>/manifest.json + plugin code
└── PluginData/<plugin-id>/              user data/config boundary
```

Debug and Release never update each other's plugin packages, disabled state,
data, or SSH replay descriptors. Global vendor Agent hooks are intentionally
outside this directory because they belong to each Agent's own configuration;
they must remain backward-compatible across OMG channels.

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
