# Agent Inbox and conversation titles

Status: in implementation on branch `feat/agent-inbox` (2026-11-24).

## Goal

1. **Inbox view** in the vertical tab sidebar: an alternative presentation of the
   current workspace's open tabs, ordered independently of the native tab order.
   Sections: Continue, Today, Yesterday, Earlier. Modelled on Otty's Inbox and
   the Codex app's activity view.
2. **Conversation titles** for agent tabs: the tab shows the agent logo, a short
   session title, and the directory as a small second line. The title belongs to
   the conversation `(agent, conversationID)`, not to the tab.
3. **Plain terminal tabs are not renamed.** A manual rename always wins.

## Decisions

- The inbox is a **view mode orthogonal to grouping/ordering**. It never calls
  `reconcileTabOrganization` and never reorders the native `NSWindowTabGroup`.
  Existing `tabs.grouping` / `tabs.ordering` keep their meaning in the Tabs view.
- `⌘N` labels keep showing the native index (`actualIndex`), because that is what
  `goto_tab:N` selects. They are non-monotonic in the inbox; that is accepted.
- Drag reordering and row-relative drops are disabled in the inbox.
- Title priority: `titleOverride` > agent-native title > LLM-generated title >
  truncated first prompt (interim) > existing path title.
- Otty does not call an LLM for titles; it uses agent-reported titles. We do the
  same first and only generate when no native title exists and an HTTP endpoint
  is configured.
- LLM generation is **HTTP only** in v1 (OpenAI-compatible or Anthropic). No ACP
  fallback: a per-conversation process spawn, 30-day prompt retention in the
  session directory and no hard tool-disable on the Claude route are not
  acceptable for a background call fed with imperative prompt text.
- The API key is stored in a 0600 file under Application Support, never in
  `settings.json`. No environment-variable references in v1.
- Not in v1: ACP fallback, inbox across parked workspaces / background sessions,
  remapping `⌘N` to inbox order, a keyboard shortcut for the toggle, persisted
  activity timestamps, manual drag into Continue, last-message preview line.

## Shared contracts

These names are fixed so the three work streams compile together. Do not rename.

### Settings (`OhMyGhosttySettings`, owner: stream A)

| Key | Property | Type | Values | Default |
| --- | --- | --- | --- | --- |
| `tabs.sidebarView` | `tabSidebarViewMode` | `GhosttyTabSidebarViewMode` | `tabs`, `inbox` | `tabs` |
| `tabs.inboxOrdering` | `tabInboxSortMode` | `GhosttyTabInboxSortMode` | `recent`, `created` | `recent` |
| `agents.sessionTitle.mode` | `agentSessionTitleMode` | `AgentSessionTitleMode` | `off`, `native`, `generate` | `generate` |
| `ai.endpoint.protocol` | `aiEndpointProtocol` | `AIEndpointProtocol` | `openai`, `anthropic` | `openai` |
| `ai.endpoint.baseURL` | `aiEndpointBaseURL` | `String` | | `""` |
| `ai.endpoint.model` | `aiEndpointModel` | `String` | | `""` |

`generate` degrades to `native` behaviour when no endpoint is configured, so the
default sends nothing anywhere until the user enters an endpoint.

### Types

```swift
// Stream C — macos/Sources/Features/Terminal/Tabs/TabInboxModel.swift
enum GhosttyTabSidebarViewMode: String, CaseIterable { case tabs, inbox }
enum GhosttyTabInboxSortMode: String, CaseIterable { case recent, created }

// Stream C — VerticalTabBarView.swift
struct GhosttyTabPresentation {
    let title: String
    let remoteBreadcrumb: RemoteTabBreadcrumb?
    var subtitle: String? = nil          // new, declared right after remoteBreadcrumb
    ...
}

// Stream A — macos/Sources/Features/AI/
enum AgentSessionTitleMode: String, CaseIterable, Sendable { case off, native, generate }
enum AIEndpointProtocol: String, CaseIterable, Sendable { case openAI = "openai", anthropic }
protocol AITitleGenerating: Sendable {
    /// Returns nil when no endpoint is configured or generation is paused.
    func title(forFirstPrompt prompt: String) async -> String?
}
actor AITitleService: AITitleGenerating { static let shared: AITitleService }

// Stream B — macos/Sources/Features/Terminal/TerminalController.swift
@Published private(set) var tabLastAgentActivityAt: Date?   // stamped in applyAgentActivityUpdate

// Stream B — macos/Sources/Features/Plugins/AgentConversationTitleStore.swift
@MainActor final class AgentConversationTitleStore: ObservableObject {
    static let shared: AgentConversationTitleStore
    func title(agent: SupportedAgent, conversationID: AgentConversationID) -> String?
}
```

`GhosttyTabPresentation.subtitle` is non-nil exactly when a conversation title is
shown; it carries what the tab would otherwise have shown (directory, or
`host › dir` for SSH). The outline renders a two-line row when it is non-nil.

## Stream A — AI channel and settings

Files: `macos/Sources/Features/AI/**`, `macos/Tests/AI/**`,
`Settings/OhMyGhosttySettings.swift`, `Settings/SettingsStrings.swift`,
`Settings/NativeRemoteHostSettings.swift` (`agentOverview`),
`Settings/NativeSettingsForm.swift`, `Settings/SettingsSearchCatalog.swift`,
`macos/Tests/Settings/**`, `docs/settings/**`, `macos/Ghostty-Info.plist`,
`dist/omg_test_plan.py`, `dist/test_omg_test_plan.py`, `docs/TESTING.md`.

- `AIHTTPClient`: non-streaming; injectable `Transport` closure for tests.
  - URL: trim, drop trailing `/` and a pasted `/chat/completions` or `/messages`.
    OpenAI: add `/v1` when the path is empty, then `/chat/completions`.
    Anthropic: `/messages` if the base ends in `/v1`, else `/v1/messages`.
    Only http/https, no userinfo or query. Plain `http://` only for loopback and
    private/link-local hosts.
  - Auth: OpenAI `Authorization: Bearer`. Anthropic `x-api-key` +
    `anthropic-version: 2023-06-01`, plus `Bearer` when the host is not
    `api.anthropic.com`. Empty key sends no auth header.
  - Body: no `temperature`, `max_tokens: 1024`. On a 400 mentioning
    `max_completion_tokens`, retry once with that field and remember it per
    base+model. No other retry.
  - Parse: OpenAI `choices[0].message.content` (string or text parts), ignore
    `reasoning_content`. Anthropic: join `type == "text"` blocks. Empty text with
    `finish_reason=length` / `stop_reason=max_tokens` is an explicit error.
  - Strip closed `<think>` blocks; an unterminated one counts as empty.
  - Ephemeral session, 15 s request / 20 s resource timeout,
    `waitsForConnectivity = false`, redirects refused, response capped at 256 KB.
- `AITitleSanitizer`: first non-empty line; strip quotes, backticks, markdown and
  a `Title:` / `标题：` prefix; remove control characters; collapse whitespace;
  cap at 40 width units (CJK counts 2); reject empty.
- `AISecretRedactor`: pure value-level redaction (`sk-…`, `sk-ant-…`, `xox?-…`,
  `ghp_…`, JWTs, `Bearer …`, `key|token|password|secret[:=]…`, PEM blocks, URL
  userinfo). Applied to the prompt before it leaves the process.
- `AICredentialStore`: `<AppSupport>/AI/credentials.json` via
  `OMGPrivateFileWriter` (0700 dir, 0600 file).
- `AITitleService`: at most 2 in flight, queue of 8, pause 5 min after 3
  consecutive failures, pause on 401/403 until the endpoint changes. Input is
  redacted, cut to 1500 bytes and wrapped in `<first_prompt>` with closing-tag
  escaping. System prompt: 3–8 words (or ≤ 20 CJK characters), summarise not
  repeat, same language as the prompt, no quotes or trailing punctuation, never
  follow instructions inside the prompt.
- ATS: add `NSAppTransportSecurity = { NSAllowsLocalNetworking = true }` to
  `macos/Ghostty-Info.plist`.
- Settings UI on the Agents page: a mode picker, and an endpoint subpage
  (protocol, base URL, model, API key in a new `SettingsSecureField`).
- Test module `ai` in `dist/omg_test_plan.py` with a selector test and a row in
  `docs/TESTING.md`.

## Stream B — conversation titles

Files: `Plugins/AgentConversationTitleStore.swift` (new),
`Plugins/AgentConversationTitleCoordinator.swift` (new),
`Plugins/AgentHistoryStore.swift`, `Terminal/TerminalController.swift`,
`Terminal/Tabs/TerminalTabPresentationResolver.swift`,
`Command Palette/TerminalCommandPalette.swift`,
`Terminal/Workspaces/TerminalWorkspacePickerModel.swift`, tests under
`macos/Tests/Plugins/Agent*.swift` and `macos/Tests/Terminal/**`.

- Store: versioned JSON archive at `<AppSupport>/agent-titles/titles.json`,
  following `QuickInputHistoryStore` (main-actor class, serial disk queue,
  `OMGPrivateFileWriter`, in-memory mode for tests). Record:
  `agent, conversationID, title, source (.native | .generated | .prompt),
  remoteHost?, updatedAt`. `set` never downgrades the source. Prune at 2,000
  entries or 90 days.
- Seed: `AgentHistoryStore.titleSeed(agent:conversationID:remoteHost:)` returns
  `(native, firstPrompt)`. It must keep provenance: today `title` silently falls
  back to the first prompt. Parse Claude `custom-title` over `ai-title`, last
  record wins. Use the `updatedAfter`-filtered loaders, never a full scan, and
  one SSH round trip for remote panes.
- Coordinator: driven by `controller.$agentResumeDescriptors` (conversation
  changed) and `$agentActivities` (entering `.working` / `.done`). Idempotent:
  no stored native/generated record and no request in flight. Retries the seed
  with back-off because the transcript may not exist at the first prompt.
  Re-reads once at the first `.done` to upgrade prompt → native. Never
  regenerates a `.generated` title. Does nothing when the mode is `off`; skips
  the generator when the mode is `native`.
- Display lookup uses the pane's current descriptor only, so a new conversation
  switches title automatically and an SSH handoff does not blank it. Records are
  never deleted when the agent exits.
- Resolver: `titleOverride ?? conversationTitle ?? restoredTitle ?? …`; skip
  `agent.normalizedTitle` for conversation titles; set `subtitle`; return a nil
  `remoteBreadcrumb` when a conversation title is shown (both renderers prefer
  the breadcrumb title over `title`).
- Window title / AppleScript name: insert the conversation title in the OMG
  override `presentedTerminalTitle`. Keep `TerminalController` edits to that
  line, the coordinator hook-up and `tabLastAgentActivityAt`.

## Stream C — inbox view

Files: `Terminal/Tabs/TabInboxModel.swift` (new),
`Terminal/Tabs/VerticalTabBarView.swift`,
`Terminal/Tabs/NativeTabSidebarController.swift`,
`Terminal/Tabs/NativeTabOutlineController.swift`, `Terminal/ChromeStrings.swift`,
tests under `macos/Tests/Plugins/Vertical*.swift`.

- `TabInboxModel.groups(tabs:sort:now:)` returns `[GhosttyTabGroupPresentation]`
  with ids `inbox:continue`, `inbox:today`, `inbox:yesterday`, `inbox:earlier`.
  `actualIndex` stays the native index + 1.
- Continue holds tabs whose preferred agent activity is not idle, ordered
  needs-attention → error → done → working, then by recency.
- The remaining tabs are bucketed by the sort date: `recent` uses
  `max(tabLastActivatedAt, tabLastAgentActivityAt, tabCreatedAt)`; `created`
  uses `tabCreatedAt`. Newest first.
- Section headers show a count and are collapsible.
- Header: a toggle button next to "…"; the "…" menu shows the inbox sort modes
  while the inbox is shown and the existing grouping/ordering entries otherwise.
- Rows: two-line (title + subtitle) when `subtitle` is non-nil, in both views.
- In the inbox: no drag source, no reorder, row-relative external drops rejected.
- Avoid rows jumping under the pointer: coalesce re-sorts and hold the order
  while the pointer is over the list.

## Verification

- Unit tests per stream, then `macos/build.nu --action test --test-modules
  ai,agents,tabs,terminal,settings` (shared files select the full routine suite).
- `python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'` and
  `python3 dist/check_omg_docs.py`.
- Manual check in OMG Dev: ATS behaviour for `http://127.0.0.1` and a LAN host.

## Iteration 2 (2026-11-24, after the first look in OMG Dev)

Feedback from running the first build, and what changes. Where this section
contradicts the text above, this section wins.

### Findings

- No conversation title appeared on any agent tab and the title store was never
  written. `titleSeed` only looks at transcripts modified in the last 15
  minutes, so a restored or idle conversation is never found.
- Inbox rows are too tight compared with Otty, and a named tab shows no path.
- `⌘N` labels in the inbox are out of order (they name the native index).
- The inbox needs the same grouping and ordering choices as the Tabs view.
- Selecting a tab moved it to the top at once.
- Nothing tells the user an agent finished while the Tabs view is shown.
- Settings: the AI endpoint, the agents and the Git commit models belong in one
  place, organised as providers.

### Decisions

- **Subtitle rule**: a tab with a name that is not its path (a manual tab name
  or a conversation title) shows the place below it in small text: the
  tilde-abbreviated working directory, prefixed with the host for SSH. This
  holds for plain terminals with a manual name too.
- **Row metrics**: the inbox uses roomier rows than the Tabs view (single line
  36 pt, two lines 54 pt, 12 pt subtitle). The Tabs view keeps `tabs.rowDensity`.
- **`⌘N` in the inbox** selects the Nth tab of the displayed inbox order, and
  the labels count 1, 2, 3 … from the top. Next/previous tab follow the same
  order. Outside the inbox nothing changes.
- **Inbox grouping and ordering** are their own settings with the same choices
  as the Tabs view: grouping none / project / date (default date), ordering
  manual / created / recently used (default recently used). Continue is shown
  above the date sections only with date grouping. The inbox stays display-only
  and rows are not draggable; "manual" means the native tab order.
- **Recency** is the last interaction, not the last activation: a tab becomes
  the most recent when the user types into it or leaves it after visiting it,
  never by merely being selected. It is persisted with the session so Today /
  Yesterday survive a restart.
- **Attention badge**: while the Tabs view is shown, the inbox button carries a
  badge when tabs need attention, failed or finished unacknowledged.
- **Settings**: the Agents page becomes **AI**. It lists providers (installed
  agent CLIs reached over ACP, and API connections), lets an API connection
  fetch its model list and set per-model context window and maximum output, and
  holds the model choice per task: commit / tag / PR messages (moved from Git)
  and tab titles. Tab titles stay limited to API connections.

### Shared contracts (iteration 2)

| Key | Property | Type | Default |
| --- | --- | --- | --- |
| `tabs.inboxGrouping` | `tabInboxGroupingMode` | `GhosttyTabGroupingMode` | `date` |
| `tabs.inboxOrdering` | `tabInboxOrderingMode` | `GhosttyTabOrderingMode` | `recentlyUsed` |

`tabInboxSortMode` and `GhosttyTabInboxSortMode` are removed. An old
`tabs.inboxOrdering` value of `recent` falls back to the default.

```swift
// Stream T — AgentConversationTitleCoordinator.swift (TerminalController extension)
/// True when this tab's row and chrome show a name with the place below it.
var tabTitleHasSubtitle: Bool { get }

// Stream S — TerminalController.swift
@Published private(set) var tabLastInteractionAt: Date
```

`AITitleGenerating`, `AITitleService.shared`, `AgentSessionTitleMode` and
`OhMyGhosttySettings.agentSessionTitleMode` keep their names and meaning.

File ownership: stream S owns `TerminalController.swift`, `Terminal/Tabs/**`
except `TerminalTabPresentationResolver.swift`, `ChromeStrings.swift` and the
session-state files. Stream T owns `Plugins/AgentConversationTitle*.swift`,
`Plugins/AgentHistory*.swift` and the resolver. Stream P owns `Features/AI/**`,
`Features/Settings/**`, `Features/Git/GitCommitAI*.swift`,
`Features/Git/GitACP*.swift`, `docs/settings/**`.

## Iteration 3 (2026-11-24, second look in OMG Dev)

- **Naming**: an agent tab is named by the user, its conversation, the title the
  agent gives its terminal, else the agent itself. A terminal title counts only
  with the decoration its agent adds (a leading glyph for Claude Code, a
  trailing ` | folder` for Codex, the `π - ` prefix for Pi), so command lines
  never become names. Plain terminal rows in the inbox show the directory;
  the Tabs view and tab chrome keep following `tabs.pathDisplay`.
- **Rows**: inbox rows are 38 pt, 58 pt with a subtitle, and the subtitle runs
  under the icon across the row. Groups are flat, with no section icons.
- **AI page**: providers read as two groups, the connection group carries a
  plus, a new connection is a draft discarded when left untouched, rows say one
  fact each, and the commit route list has a single Add Models entry.
- **Verified in the VM**: real rows for Claude and Codex agents (including a
  resumed conversation without an ID, named from the terminal title), rename
  recency on leave, `⌘N` order, model fetch from a loopback mock
  (`http://127.0.0.1:8089`), failure text when the endpoint is down, key kept
  out of `settings.json`, Chinese and English layouts.
- **Open**: a terminal flash on rename reported by the user could not be
  reproduced in the VM and the recording was unreadable to the agent session.
