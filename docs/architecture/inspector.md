# Right Inspector Architecture

## Status

The Core host foundation and a minimal `builtin.files` provider are implemented. Git, Search, Issues, Pull Requests, AI Context Browser, and Marketplace panes remain out of scope.

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

`InspectorPresentationStore` is the typed persistence boundary for last-used visibility, committed width, and active pane. It uses the application UserDefaults domain because these are UI runtime state, not portable user configuration. The values are intentionally absent from Ghostty config and `~/.config/oh-my-ghostty/settings.json`.

Core Features and Plugins own only pane-specific data and commands. They do not own the split view or Inspector chrome.

## Registry contract

`InspectorRegistry` accepts `InspectorPaneDescriptor` metadata, typed `InspectorPaneContent`, and owner-scoped actions:

- empty state;
- label/value fields;
- list items;
- recursive file-tree snapshots;
- refresh, collapse, disclosure, and create actions.

Descriptors include stable ID, title, SF Symbol name, owner, preferred width, and minimum width. IDs, labels, and widths are validated before registration. Duplicate IDs are rejected.

A Core Feature registers a typed content provider and may receive appeared/disappeared lifecycle events. A Plugin registers a data-only pane and updates its content through an owner-scoped API. Plugin ownership is checked on every update and all panes are removed on owner disconnect.

`BuiltInFilesInspectorProvider` dogfoods the Plugin path under owner `builtin.files`. Content is isolated by stable tab ID. Pane appearance, tab switches, and live `SurfaceView.$pwd` changes asynchronously refresh the selected root; title-only context updates never reload the tree. Disclosure uses node-scoped tasks and merges only the affected subtree, retaining the mounted ScrollView, other node identities, selection, scroll position, cached children, and per-tab expansion state. Root rebuilds are reserved for cwd changes and explicit refresh/create actions. The provider accepts typed New File, New Folder, Refresh, Collapse All, and disclosure actions without injecting a View or performing filesystem I/O on the main actor. Filename/extension metadata selects host-owned Git, shell, language, config, document, and media icons.

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

- The window titlebar owns the extensible pane switch and persistent `sidebar.right` control; active panes display icon + title while inactive panes display icon only. Left and Right controls share the same icon size, 24pt hit target, corner radius, spacing, hover, disabled, and Medium active-label tokens. A deterministic 12pt width bucket keeps a fixed visible prefix and moves overflow into an icon + title + checkmark `…` menu without threshold jitter. Hidden Inspector panes remove every Plugin item and retain only the reopen control. **View > Toggle Inspector** and `⌘⇧I` use the same state.
- Inspector content begins directly with the selected pane. Files uses the reusable lightweight Plugin context header to show the current root's last path component with its filesystem casing preserved. The active titlebar entry, context header, and root tree row derive their leading positions from the same content inset; the header updates from the same typed tree snapshot whenever cwd/root changes and adds no duplicate action chrome.
- Sidebar separators remain two coordinated segments because Ghostty's native AppKit titlebar and SwiftUI content shell are separate layout layers. Both segments use the same Core-owned width and Ghostty `splitDividerColor(for:)` semantic resolver, evaluated against the focused surface's actual background. The default result is an opaque background-derived contrast color, avoiding titlebar/content alpha-compositing differences; an explicit `split-divider-color` remains authoritative. Each stroke is centered in the same 8pt boundary slot. The Right titlebar accessory includes that slot in its width, so its divider center matches the content resize handle exactly. Files never draws a separator, and committed width is still persisted only on mouse-up.
- Left and Right visibility use one two-phase transition: shell width changes once while pane content uses a short opacity/6pt horizontal transform. Hidden tabs synchronize immediately, the selected terminal avoids per-frame width animation, and Reduce Motion switches to an immediate state change.
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
