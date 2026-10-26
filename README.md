<p align="center">
  <img src="images/omg/omg-app-icon-1024.png" alt="Oh My Ghostty app icon" width="112">
</p>

<h1 align="center">Oh My Ghostty · OMG</h1>

<p align="center">
  A macOS terminal for AI-agent workflows, built on Ghostty.
  <br>
  Keep your agents, prompts, files and Git context in one native window.
</p>

<p align="center">
  <a href="https://github.com/jischeng/oh-my-ghostty/releases/latest">Download</a>
  · <a href="README.zh-CN.md">简体中文</a>
  · <a href="docs/REPORTING.md">Report a problem</a>
  · <a href="docs/CONTRIBUTING.md">Contribute</a>
</p>

<p align="center">
  <a href="https://github.com/jischeng/oh-my-ghostty/releases/latest"><img src="https://img.shields.io/github/v/release/jischeng/oh-my-ghostty?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

> OMG is an independent, actively developed **pre-1.0 Ghostty fork**, not an
> official Ghostty release. It can coexist with `Ghostty.app` and uses its own
> application identity. Public releases are available for Apple Silicon and Intel.

![OMG split terminal, Agent CLI and Git Inspector](docs/images/omg-agent-git-workspace.png)

*An everyday workspace: vertical tabs, an Agent CLI and repository history side
by side.*

## Why OMG?

Running an Agent CLI often means switching between terminal output, long prompts,
files and repository context. OMG adds a native application layer around Ghostty
for that workflow—not another terminal engine or a hosted AI service.

OMG is still in iterative development. In the author's everyday workflow, it
already handles some tasks that previously required switching between Ghostty,
VS Code and other tools. That is a personal-use observation, not a claim to
replace a full IDE, every VS Code extension, or Ghostty's cross-platform releases.

| What you want to do | What OMG adds |
| --- | --- |
| Write a multiline prompt without fighting terminal input | **Quick Input**: a resizable composer with deliberate Send and Queue actions |
| Reuse a prompt or keep the composer open | **Sent history** with search, keyboard navigation, append/replace, and a global Pin control |
| Organize several sessions | **Vertical tabs** with grouping/order controls and optional Agent activity indicators; native horizontal tabs remain available |
| Work with the current workspace | **Files Inspector + editor**, including live Markdown preview |
| Check repository context alongside a running session | **Git Inspector** for status, diffs and history |
| Find earlier shell activity | **Command history** in Info, with navigation back to retained output when valid shell-integration anchors are available |
| Draft a commit message from staged changes | **ACP connection to a locally installed Agent**, with configurable Agent/model routes and a prompt; review the draft before committing |
| Work on remote machines | **SSH-aware Git, Agent session status, file browsing and port forwarding**, using OpenSSH configuration and system tools |

Agent CLIs such as Codex, Claude Code and Pi are installed separately. OMG's
optional Agent integrations provide activity/session context; support varies by
Agent. OMG does not supply a model subscription or replace your Agent CLI.

## More than terminal input

- **Editor:** inspect and edit workspace files, review diffs, and use live
  Markdown preview without leaving the terminal workspace. It is a focused
  editor, not an implementation of VS Code's extension ecosystem.
- **Command history:** review earlier shell commands in the Info Inspector.
  Navigation depends on valid retained shell-integration anchors; expired
  entries do not pretend to have an exact output location. This is separate
  from Quick Input sent-message history and an Agent's transcript.
- **Port forwarding:** manage remote ports from Info, with browser/copy/stop
  actions, using the recognized SSH connection context.
- **AI commit-message drafts over ACP:** read the staged patch and ask an
  installed Agent through the Agent Client Protocol. Supported adapters include
  Claude, Pi, Codex and OpenCode; setup/authentication is explicit. For an SSH
  repository, Git reads happen remotely while the ACP process runs on the Mac.
  Generation does not commit automatically.

A local ACP process can still call a remote model service: **local Agent does
not mean offline inference**. Staged source may be sent to that provider; review
its policy and OMG's [commit-generation settings](docs/settings/configuration.md)
before enabling the feature.

## Built around an SSH-heavy workflow

OMG grew out of the maintainer's own workflow: connecting to remote machines,
working in Git repositories there, and running Agent CLIs inside SSH sessions.
A remote terminal should offer useful workspace context—not just display bytes.

- A **recognized, ready SSH pane** can resolve the remote working directory and
  Git repository. The Git Inspector runs against that remote repository rather
  than a same-path local directory, with status, diffs and history alongside the
  terminal.
- **Remote Agent activity/session context** can follow the owning SSH pane, so
  its tab can show working, attention, completion or failure states. Supported
  hook integrations require explicit installation in the remote account;
  availability varies by Agent. OMG does not silently modify remote dotfiles.
- Remote Files browsing, port forwarding and split/session restoration build on
  the captured OpenSSH connection and workspace context, including supported
  alias, port and jump-host options.

This is optimization for a real personal workflow, not a promise to recognize
arbitrary nested SSH sessions or every Agent automatically. Recognition requires
recoverable connection/workspace context and usable remote tools/authentication.
See [SSH Git transport](docs/PLUGIN_DEVELOPMENT.md#ssh-git-parity-and-transport)
and [Agent integration](docs/settings/configuration.md) for the exact boundaries.

![OMG SSH session with split panes and Agent activity in vertical tabs](docs/images/omg-ssh-agent-splits.png)

*An SSH session with split panes and Agent activity indicators in the tab sidebar.*

## Download and install

Requires **macOS 13 or later**. Open the
[latest GitHub release](https://github.com/jischeng/oh-my-ghostty/releases/latest)
and choose a DMG:

| Mac | Release asset |
| --- | --- |
| Apple Silicon | `OMG-<version>-macos-arm64.dmg` |
| Intel | `OMG-<version>-macos-x86_64.dmg` |
| Either architecture | `OMG-<version>-macos-universal.dmg` |

1. Open the DMG and drag **OMG.app** to Applications.
2. Launch OMG. It does not replace the official Ghostty app.
3. If macOS blocks the first launch, review the warning and—only if you trust the
   download—allow the app in **System Settings → Privacy & Security**.

**Signing:** releases use a persistent **self-signed identity** and are **not
notarized**. They are not Apple Developer ID-signed apps. Do not disable Gatekeeper
globally. Releases include `SHA256SUMS.txt`; signing and distribution details are
in [Releasing OMG](docs/RELEASING.md).

To uninstall, remove `OMG.app`. Settings, saved session data and history are not
automatically erased. You can clear sent history in Settings before removing the
app; see [configuration and storage](docs/settings/configuration.md).

## Your first Agent workflow

1. Start your usual shell or installed Agent CLI in the terminal.
2. Press **⌘⇧E** to open Quick Input and write a prompt. Use **⌘↩** to send it,
   or **⌥⌘↩** to queue it. Queue dispatch depends on the owning Agent session's
   normalized completion signals; it is not a generic shell-command scheduler.
3. Press **⌘⇧H** or click the clock icon to open sent history. Use **↑/↓** to
   select, type to search, and **Enter** to insert. Selection does not send text.
4. Use **Pin** to keep Quick Input open after sending/queueing. Explicit Escape
   still closes it; visibility and Pin are shared across OMG tabs/windows.
5. Open **Settings → Editor → Quick Input** for history scope, append/replace,
   expiration and retention. Agent hook installation is optional and explicit in
   **Settings → Agent Integration**.

| Shortcut | Action |
| --- | --- |
| ⌘B | Toggle the left tab sidebar |
| ⌘⇧B | Toggle the right Inspector sidebar |
| ⌘⇧E | Toggle Quick Input (configurable) |
| ⌘↩ | Send the draft; save when editing a queued message |
| ⌥⌘↩ | Queue the draft; move a queued edit to the queue end |
| ⌘⇧H | Toggle History; reopening remembers selection/search |
| ↑ / ↓ | Browse History; in the composer, initial boundary navigation needs two distinct presses |
| Esc | Dismiss the composer; in History, leave search before closing |

Browse-only history navigation preserves the newest unsent draft and caret;
editing recalled text makes it a new draft without changing the sent record.
See the [full Quick Input behavior](docs/settings/configuration.md) for IME,
focus, queue and persistence details.

## Privacy and current boundaries

- **Sent history is local, unencrypted text.** It can contain private prompts,
  source code or credentials. The default is Tab visibility, seven-day expiration
  and retention after quitting. Change these settings or clear history when needed.
- History is bounded, but stored records from closed panes can remain until expiry.
  Turning retention off removes the saved copy, not the current in-memory history.
- An Agent CLI or remote server has its own network and data-handling policies.
  Local history storage is not a promise that every workflow stays offline.
- **OMG's added application features target macOS.** Inherited cross-platform
  Ghostty source is not a promise of equivalent OMG Linux/Windows releases.
- **Plugin system: Beta.** The in-tree provider/extension foundation is still
  evolving, is not a stable public API, and its future development/distribution
  workflow is still being designed. Built-in typed providers are working host
  features; a public third-party executable plugin loader/SDK is **not available
  yet**. Beta does not mean external plugin installation is supported. See
  [Plugin Development](docs/PLUGIN_DEVELOPMENT.md) for exact capability status.
- This is active pre-1.0 development, not a claim of bug-free behavior or a stable
  public extension API. Consult [release notes](https://github.com/jischeng/oh-my-ghostty/releases)
  and [reported issues](https://github.com/jischeng/oh-my-ghostty/issues).

## Feedback and contributions

English and Chinese are welcome. OMG has its **own** community entry points; you
do not need to complete Ghostty's upstream vouch process to participate here.

- [Reporting guide](docs/REPORTING.md): reproduction, version identification,
  evidence, privacy and optional agent-assisted reporting.
- [Open an OMG issue](https://github.com/jischeng/oh-my-ghostty/issues/new/choose):
  bugs or workflow requests. Do not send OMG-only problems to upstream Ghostty.
- [Contribution guide](docs/CONTRIBUTING.md): focused patches, build/test commands,
  documentation requirements, AI disclosure and PR expectations.
- Security concerns: use the confidential-reporting guidance in
  [Reporting](docs/REPORTING.md), not an ordinary public issue with exploit details.

## Build from source

You need Xcode, Zig 0.16.0, Nushell and SwiftLint. **Build GhosttyKit first on a
clean checkout**, following the [contribution guide](docs/CONTRIBUTING.md). Then:

```bash
macos/build.nu --configuration Debug --action build
macos/build.nu --action test --test-modules quick-input
```

The Debug output is `macos/build/Debug/OMG.app`; the internal Xcode scheme/Swift
module is still named `Ghostty`. Local installs use **OMG Dev**, with separate
identity and mutable storage—never overwrite a user's release OMG for testing.
The current Swift test target requires macOS 15.5+. See [Testing](docs/TESTING.md)
for selection and optional foreground-desktop coverage.

## Architecture and upstream

OMG retains the complete Ghostty macOS host and favors fork-owned feature files
and small upstream adapters. It keeps OMG release versions separate from the
Ghostty base version/revision. See [Architecture](docs/oh-my-ghostty-architecture.md)
and [Releasing](docs/RELEASING.md) for the engineering contracts.

Ghostty was created by Mitchell Hashimoto and its contributors. Thank you to the
[upstream project](https://github.com/ghostty-org/ghostty); this fork preserves its
copyright, license and attribution, and is not affiliated with or endorsed by it.
For the inherited terminal configuration, consult [Ghostty documentation](https://ghostty.org/docs).

## Thanks and inspiration

- **[Ghostty](https://github.com/ghostty-org/ghostty):** the terminal foundation
  and upstream project; created by Mitchell Hashimoto and its contributors.
- **[Visual Studio Code](https://github.com/microsoft/vscode):** an important
  workflow/UI reference for workspace, Git and remote-development interactions,
  not a claim that OMG embeds VS Code or implements its extension system.
- **[CodeEdit / CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor):**
  the native source-editor component used by OMG.
- **[CodeMirror](https://codemirror.net/), [Mermaid](https://mermaid.js.org/) and
  the Markdown rendering ecosystem:** live Markdown editing and diagram support.
- **[Agent Client Protocol](https://agentclientprotocol.com/)** and the Agent
  adapter authors who make local Agent integration possible.

Thank you to these projects and their contributors. Reference/integration does
not imply their endorsement. Components retain their own licenses and notices;
Markdown asset notices are in
[THIRD_PARTY_NOTICES](macos/Resources/MarkdownPreview/THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE). Preserve the Ghostty copyright notice and license terms when
redistributing copies or substantial portions of this software.
