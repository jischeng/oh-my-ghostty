# OMG 0.23.0 · Ghostty 1.4.1-dev

OMG 0.23.0 makes Agent History something you can search and read: a full-text index, search across SSH hosts, results ordered by relevance, and transcripts that show the conversation instead of the log. It also adds session fork for SSH and splits, `omg +edit` / `omg +view` from the shell, a redesigned Info pane, and a reworked Settings window.

## Highlights

### Agent History

- **Full-text search that is instant.** Local sessions are kept in a private search index, so a search reads one database instead of every transcript. It matches substrings, which is what works for Chinese and for identifiers. The index is updated when you open Agent History; **Settings → Agent → Agent History → Update Search Index in the Background** (off by default) also refreshes it every 30 minutes.
- **Search reaches SSH hosts.** With an SSH pane focused, a search also looks through the transcripts on that host, in one bounded command (the 500 newest sessions, 15 seconds). It needs `python3` on the host; without it, titles and previews still match.
- **Best match first.** Results are ordered by relevance while you search: a title that names the query, then how often the conversation mentions it, then recency. The order menu still offers Recently Updated and Title.
- **Open a result at the match.** A result opens the whole conversation scrolled to the first matching turn, with every occurrence highlighted. The find bar shows your position among the matches; Return and Shift-Return step through them.
- **Transcripts show the conversation.** Injected system prompts, tool calls and results, compaction summaries, sub-agent side chains and abandoned retry branches are no longer shown as messages. An Agent's consecutive replies read as one turn, sessions that were opened and never used are not listed, and messages render Markdown (headings, lists, code blocks, tables).
- **More Agents.** OpenCode, Hermes and Cursor sessions are now listed and readable, and Antigravity shows the full conversation instead of its summary. Archived Codex sessions (`.jsonl.zst`) are searchable and readable, locally and over SSH.
- **Fork a session.** Fork is available for SSH sessions as well as local ones, and opens in a new tab or in a split to the right or below. It is offered for Claude Code, Codex, Pi and Qoder CLI, which have a native fork; other Agents show no fork entry rather than silently resuming.
- **Faster first load.** Scanning a large history for the first time is about five times faster.

### Shell and editor

- **`omg +edit <file>` and `omg +view <file>`** open a file in the built-in editor or viewer of the pane you are in, so `$EDITOR` can point at OMG. The app listens on a per-channel Unix socket that only your user can reach, and it accepts these two requests only.

### Info pane

- The pane leads with the focused pane's working directory and its actions: Copy Path, Reveal in Finder, and Open in an installed editor. The list of applications can be edited.
- An Agent section names the conversation running in the pane, with Copy Conversation ID and, for local conversations, the transcript's path.
- Command history shows each command's exit status and duration; a failed command is marked with its exit code.
- Forwarded ports size to their content instead of scrolling inside a fixed box.

### Settings

- Explanations are shown under each setting instead of in tooltips, menus open below their control, and embedded lists no longer trap the scroll wheel.
- Toggle Sidebar and Toggle Inspector shortcuts are configurable, and number shortcuts are chosen as one modifier per family (tabs, right-sidebar panels, workspaces).
- The Add AI Models sheet reports loading, failure and empty results in place, and Agents are picked with icon tabs.

### Fixes

- The Files pane, tab menus, group titles, window tooltips and accessibility labels follow the OMG language setting, and tooltips show the shortcuts you configured.
- Command history restored with a session no longer gains rows for text that was not a command, and keeps each command's time, status and source.
- A restored Inspector keeps its titlebar at the restored width.
- Info finds an Agent's transcript when it is written after the Agent attaches.

## Notes

- The search index is stored in OMG's Application Support folder with owner-only permissions and holds only text that is already in your session stores. For a large history it can reach about 100 MB.
- OMG reads other Agents' session databases without writing to them.
- Resuming a Cursor session uses `cursor-agent --resume <chatId>`, as documented by the Cursor CLI. Listing and reading Cursor sessions were verified against real data; the resume action itself was not exercised.
- Copilot, Reasonix, Grok, Droid, Kimi, Amp, Cline and Crush sessions are not listed yet.

## Version and distribution

- OMG **0.23.0**, bundle version **65** (`CFBundleVersion`).
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.22.2`).
- Includes the changes since the published `v0.22.2` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**, using the same pinned release certificate as previous releases. macOS Gatekeeper may block the first launch; users who trust the download can review and allow it in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally. Sparkle updates retain their separate EdDSA signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session runtime artifacts. The session runtime revision is `055999ff4b9b33266b48` (`7a07794199e8ef12ad94` in `0.22.2`); the snapshot revision `7abe5365444c63ee8df6` is unchanged. The runtime's own code did not change; its revision moves because the terminal core it embeds did. A remote daemon that owns live sessions is never replaced in place, so existing sessions stay on the revision they started with.
- iOS physical device installation requires signing with the user's own Apple ID (a free Personal Team Apple ID works via `OMG-Mobile-0.23.0-ios-installer.tar.gz`, or via a sideloader using `OMG-Mobile-0.23.0-ios-unsigned.ipa`).

## Validation

- **Static and contract checks**: passed (`swiftlint --strict`, `zig fmt --check`, settings schema, documentation contract, `plutil`, `ibtool`, signing, keychain, release, test-plan and mobile-plan contracts).
- **Swift**: all 13 routine modules, 204 suites, run in the retained Tart VM. `TerminalWorkspaceAppearanceTests` failed in the broad run and passed when rerun on its own; every other suite passed in the broad run.
- **Zig**: the tests of the files changed since `0.22.2` pass: command history (13), `+ssh` (20) and the CLI entry point (8). The whole Zig suite was not run.
- **Session runtime** (run because the bundled revision changed): `cargo fmt --check` and `cargo clippy -D warnings` pass; 184 of 185 Rust tests and all 42 Python tests pass (4 skipped: they need a configured SSH or Linux host).
- **iOS**: native core, simulator build and the guest simulator flow passed.
- **Agent History** was exercised in the VM against a copy of a real history (about 4,200 sessions across nine Agents) and against a real SSH host.
- **Known failures, unchanged from `0.22.2`**: two results were compared against the `v0.22.2` tag and are identical there, so neither comes from this release.
  - Six `Terminal` tests (grapheme transfer when widening wraps, and Devanagari wide graphemes on the next line or page) abort on a page-integrity assertion that only Debug builds evaluate.
  - The runtime test `login_wrapper_shell_child_osc133a_fence_and_agent_child_crash_detection` times out waiting for an activity update.
- **Not run**: optional `.interactiveDesktop` native drag/focus suites (15 deferred), XCUITest, full desktop TCC and Sparkle upgrade experiments, live remote SSH deployment and Linux containment gates, and host frame-rate, multi-display and latency measurements.
- **Packaging**: the release tooling signs every app with the pinned certificate, checks the designated requirement against `0.22.2`, recomputes the session-runtime manifests after signing, runs a launch probe, and signs the appcast with Sparkle's EdDSA key; it stops if any of these fails. The `x86_64` app was not launched, because Rosetta 2 is not installed on the Apple Silicon build host; its Mach-O slice and signature are verified instead.
