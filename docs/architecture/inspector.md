# Right Inspector Architecture

## Status

The Core host foundation, `builtin.files`, `builtin.agent-history`, and the official in-tree `builtin.info` provider are implemented. Agent History discovers readable local session stores for Agents with a verified exact-resume mechanism. Info currently contains SSH port forwarding; machine status/resources and machine/session fields remain reserved and hidden. Git, Search, Issues, Pull Requests, AI Context Browser, and Marketplace panes remain out of scope.

## Shell hierarchy

A regular terminal window uses one Core-owned shell hierarchy:

```text
TerminalViewContainer (AppKit, window glass/blur owner)
└─ TerminalShellLayoutContainer (SwiftUI)
   ├─ TerminalTabSidebarView         [Vertical layout only, optional]
   ├─ TerminalSplitTreeView          [Ghostty terminal content]
   └─ RightInspectorHost             [optional, registry must be non-empty]
```

Horizontal layout keeps Ghostty's native titlebar tabs. It only omits the leading `TerminalTabSidebarView`; the terminal and trailing Inspector use the same shell and window-level state.

## Ownership

Core App Shell owns:

- leading/terminal/trailing layout;
- Inspector visibility, selected pane, width, resize interaction, divider, chrome, focus, and lifecycle delivery;
- background color/opacity and window blur integration;
- validation and rendering of pane data;
- cleanup when an owner disconnects.

`VerticalTabWindowLayoutState` currently carries the shared shell state for compatibility with the existing tab implementation. Despite the historical name, the instance is associated with `NSWindowTabGroup` and shared by Horizontal and Vertical tabs. Inspector state never belongs to one terminal tab.

`InspectorPresentationStore` is the typed persistence boundary for last-used visibility, committed width, and active pane. It uses the application UserDefaults domain because these are UI runtime state, not portable user configuration. Release and Debug have separate bundle domains. The values are intentionally absent from Ghostty config and the channel-specific OMG settings file.

Inspector context is derived from the controller's published focused `Surface`,
not merely the active tab. A split-pane focus change therefore updates the
workspace descriptor, cwd, Files provider, and typed content context as one
transaction; stale provider tasks are cancelled by the existing generation/key
model.

Core Features and Plugins own only pane-specific data and commands. They do not own the split view or Inspector chrome. Files consumes the generic `WorkspaceFilesystem` boundary: `LocalWorkspaceFilesystem` handles local paths and the in-tree SSH provider uses the system SFTP client for remote paths. The Files UI does not branch on Local versus SSH.

## Registry contract

`InspectorRegistry` accepts `InspectorPaneDescriptor` metadata, typed `InspectorPaneContent`, and owner-scoped actions:

- empty state;
- label/value fields;
- list items;
- recursive file-tree snapshots;
- bounded Agent session lists and readable user/assistant transcripts;
- extensible Info snapshots with optional status, fields, and port forwards;
- refresh, selection, exact Agent resume, collapse, disclosure, create, open,
  copy, and remove actions.

Descriptors include stable ID, title, SF Symbol name, owner, preferred width, and minimum width. IDs, labels, and widths are validated before registration. Duplicate IDs are rejected.

A Core Feature registers a typed content provider and may receive appeared/disappeared lifecycle events. A Plugin registers a data-only pane and updates its content through an owner-scoped API. Plugin ownership is checked on every update and all panes are removed on owner disconnect.

`BuiltInFilesInspectorProvider` dogfoods the Plugin path under owner `builtin.files`. `BuiltInAgentHistoryInspectorProvider` uses the same typed boundary under `builtin.agent-history`. The enabled official SSH Plugin registers `BuiltInInfoInspectorProvider` as the sibling `builtin.info` pane. Info reserves hidden optional status and machine/session sections; while they are empty, the antenna-labelled port-forward section begins at the top without an empty divider. Port rows split a remote target (`port` or `host:port`) and forwarded address into columns, show a bounded loopback listener process below, and reveal explicit browser/copy/stop actions on hover. Forwarding prefers the same local port, reports normalized SSH/bind failures, follows the live OMG English/Simplified-Chinese language setting, and never treats a row click as browser authorization. Forward intent is keyed by a remote-reported sshd host-key fingerprint (with OS machine ID fallback) plus remote port, never by alias, destination IP, HostName, or ProxyJump route. It is shared across every ready Pane reporting that stable server identity, persisted for restoration, and backed by an app-owned SSH process that ends only after the last matching SSH connection or the app exits.

Agent History scans only manifest-declared local JSONL stores/discovery roots for Agents that also declare non-empty, allowlisted exact-resume arguments. It skips symbolic links, validates conversation IDs with `AgentConversationID`, bounds enumeration, header reads, session count, transcript messages, and rendered message length, and performs file parsing/search off the main actor. A versioned mtime cache avoids reparsing unchanged session headers; `agents.historyLimit` controls the indexed session count (default 10,000). Registration starts no scan, timer, watcher, or helper process: the first pane appearance hydrates cached rows, then performs one cancellable refresh, and hiding the last presentation cancels outstanding cache/transcript work. Session search is debounced and emits title/metadata matches first, cached preview matches second, then streams complete user/assistant logs in recent order, returning bounded highlighted snippets; opening a result carries the query into transcript search and shows adjacent context. Long transcripts use an AppKit `NSTableView` with reusable, automatically-sized rows rather than a SwiftUI dynamic-height list, and explicit bounded page expansion prevents high-velocity scrolling from mounting the whole transcript. The pane also supports Agent filtering, project/Agent/date grouping, ordering, copy, per-tab transcript selection, native Agent-specific fork, and manual refresh. Resume first focuses an already-live matching Surface; otherwise it creates a new tab through a typed `AgentResumeDescriptor` and the existing survival-shell path. It never guesses unsupported resume flags, executes transcript content, scans remote homes, or treats arbitrary JSONL files as Agent history.

Files content is isolated by stable tab ID. Pane appearance, tab switches, and live `SurfaceView.$pwd` changes asynchronously refresh the selected root; title-only context updates never reload the tree. Disclosure uses node-scoped tasks and merges only the affected subtree, retaining the mounted ScrollView, other node identities, selection, scroll position, cached children, and per-tab expansion state. Root rebuilds are reserved for cwd changes and explicit refresh/create actions. The provider accepts typed New File, New Folder, Refresh, Collapse All, and disclosure actions without injecting a View or performing filesystem I/O on the main actor. Filename/extension metadata selects host-owned Git, shell, language, config, document, and media icons.

During Debug/development builds the provider emits `OSLog` diagnostics under the `files-inspector` category for pane lifecycle, cwd/root changes, disclosure actions, root/subtree generation cancellation/discard, directory read depth/count, total elapsed time, refreshes, and rejected creation names. The bounded generation/task cancellation model ensures stale reads cannot publish into a newer tree. Release builds can filter this category without changing the data path.

Disclosure never publishes an empty/loading root. The target node alone receives a loading state, the existing tree stays mounted, and children merge into that node when ready. Collapse retains its children cache. This preserves scroll position and avoids whole-column animations; only the local subtree uses a short opacity/layout transition.

The stable Plugin capability is `inspectorPane`. The v1 process transport does not yet expose pane registration messages; adding those messages must preserve this same typed, owner-scoped model.

## Prohibited Plugin access

An Inspector Plugin never receives or controls:

- `NSWindow` or `NSWindowTabGroup`;
- `NSSplitView`, `NSView`, `NSHostingView`, or arbitrary SwiftUI `View` values;
- terminal `Surface`, PTY, renderer, input, or scrollback;
- Sidebar or Inspector theme/material;
- resize, focus, selection, or pane lifecycle implementation.

This keeps a Plugin pane declarative and prevents it from bypassing Core layout, appearance, and terminal safety boundaries.

## Appearance

Window, terminal-adjacent chrome, Vertical Tabs, and Right Inspector consume the same Ghostty-derived background color and `background-opacity`. Background layers apply alpha locally. The application never uses `window.alphaValue` or a whole-tree SwiftUI opacity modifier, so glyphs, cursor, icons, and controls remain sharp and opaque.

Blur and macOS glass continue to be provided by Ghostty's `TerminalViewContainer` and `TerminalWindow` mechanisms. Inspector code does not install an independent material.

## Interaction

- The window titlebar owns the extensible pane switch and persistent `sidebar.right` control. The Inspector toggle occupies a fixed 44pt trailing slot in every state and is structurally outside the Plugin pane/overflow area, so it never moves, clips, or folds into `…` as the Inspector width changes. Active panes display icon + title while inactive panes display icon only in the remaining width. A deterministic 12pt width bucket keeps a fixed Plugin prefix and moves only Plugin items into an icon + title + checkmark `…` menu without threshold jitter. Overflow decisions measure titles with the same font, spacing, icon, and padding tokens used by the rendered controls, including localized and Plugin-provided titles. Hidden Inspector panes remove every Plugin item and retain the fixed toggle. **View > Toggle Inspector** and `⌘⇧I` use the same state.
- Inspector content begins directly with the selected pane. Files uses the reusable lightweight Plugin context header to show the current root's last path component with its filesystem casing preserved. The active titlebar entry, context header, and root tree row derive their leading positions from the same content inset; the header updates from the same typed tree snapshot whenever cwd/root changes and adds no duplicate action chrome.
- Sidebar separators belong only to the SwiftUI content shell; the unified native AppKit titlebar does not duplicate them. Content dividers use Ghostty's `splitDividerColor(for:)` semantic resolver against the focused surface background, with an explicit `split-divider-color` remaining authoritative, and stay centered in the 8pt resize hit area. The Right titlebar accessory spans only Inspector content width and excludes the content resize handle. The shared AppKit/SwiftUI titlebar bridge publishes the collapsed minimum width required for reliable first-window attachment; every host width change synchronizes the Auto Layout constraint, accessory intrinsic width, and actual AppKit frame before layout, so the Plugin area receives the full expanded width instead of overflowing a stale 44pt frame. The host publishes explicit titlebar presentation width and visibility alongside the AppKit constraint, so SwiftUI Plugin controls do not depend on a stale `GeometryReader` proposal after reopen. On reveal, the accessory expands first and Plugin controls enter on the next runloop with the same 0.18s opacity/6pt transition as the pane; on hide, controls animate out before the accessory contracts. During collapse, SwiftUI removes Plugin pane/overflow controls one runloop turn before the host contracts the accessory, preventing a transient AppKit `…` item. Files never draws an additional separator, and committed content width is still persisted only on mouse-up.
- Left and Right visibility use one two-phase transition: shell width changes once while pane content uses a short opacity/6pt horizontal transform. The boundary background remains mounted while content opacity changes, so transparent/vibrant compositing stays continuous. Hidden tabs synchronize immediately, the selected terminal avoids per-frame width animation, and Reduce Motion switches to an immediate state change.
- Left and Right resize handles share one `SidebarResizeInteraction`, including an 8pt hit area, horizontal resize cursor, first-mouse behavior, drag-width direction, and mouse-up commit semantics. The native drag view invalidates its cursor rect whenever its frame changes, so an Inspector handle mounted from a hidden zero-width state registers the full resize cursor after expansion.
- Visibility, width, and active pane restore for later windows/app launches.
- An empty registry still removes the complete trailing host from layout.

## Performance

Idle CPU profiling found no repeating Files refreshes or surviving provider tasks. The 83–93% regression was an AppKit appearance KVO feedback loop: the effective-appearance observer wrote `NSApp/window.appearance`, which scheduled another appearance invalidation timer. The observer now only forwards color scheme to libghostty; explicit OMG appearance assignment is idempotent and happens only after a real settings/config change. The same Debug build measures approximately 0.5–1.0% idle CPU with a terminal and Inspector open.

## Empty registry behavior

An empty registry does not add a trailing view, divider, width constraint, process, or startup dependency. Terminal creation and rendering are unchanged. Visibility state can remain set while the registry is empty; if a pane is registered later, the Core host can present it without rebuilding a Surface or restarting a shell.

## Lifecycle

1. An owner registers a validated descriptor.
2. Core selects the existing window-group pane ID or the first available descriptor.
3. The host resolves typed content using the selected tab/surface context.
4. Core emits appeared/disappeared lifecycle events as presentation changes.
5. Owner updates trigger declarative re-rendering only.
6. Unregister/disconnect removes owned descriptors and content; Core reconciles selection.

Changing selection, resizing, hiding, registering, updating, or removing an Inspector pane must not rebuild `Ghostty.SurfaceView`, restart the PTY, or alter `NSWindowTabGroup.windows`.
