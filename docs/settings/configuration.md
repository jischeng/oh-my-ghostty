# OMG Settings

Stable OMG preferences are stored in:

```text
~/.config/oh-my-ghostty/settings.json
```

Development builds use an isolated file:

```text
~/.config/oh-my-ghostty-dev/settings.json
```

On first launch, OMG Dev copies the stable file as a starting point when the
Dev file does not exist. The files are independent after that copy, so local
builds and tests cannot rewrite the main terminal's preferences.

The file is a flat, sorted JSON object. Only values explicitly chosen by the user are written. It is safe to edit with a text editor, script, or configuration-management tool.

## Example

```json
{
  "appearance.backgroundBlur": "enabled",
  "appearance.backgroundOpacity": 0.75,
  "appearance.darkTheme": "Catppuccin Mocha",
  "appearance.lightTheme": "Catppuccin Latte",
  "keyboard.quickInput": "shift+command+e",
  "keyboard.quickInputHeight": 252,
  "notifications.taskComplete": false,
  "tabs.grouping": "project",
  "tabs.layout": "vertical",
  "tabs.ordering": "manual",
  "tabs.pathDisplay": "folderName",
  "tabs.sidebarWidth": 300
}
```

Reload the file with **Settings > Advanced > Reload** or Ghostty's **Reload Configuration** command. `tabs.layout` applies to newly created windows because changing the NSWindow/titlebar class of an existing terminal would risk rebuilding its presentation hierarchy.

## Ownership And Precedence

| Layer | Owns | Priority |
| --- | --- | --- |
| Runtime/window state | Current tab Sidebar visibility/live width, Inspector visibility/width/active pane, collapsed groups, selected tab | Highest |
| OMG settings | Optional application and Appearance overrides listed below | Second |
| Ghostty config | Inherited baseline, including `macos-tab-layout`, theme, font, opacity, blur, and cursor | Third |
| Built-in defaults | Safe values for unset settings | Lowest |

The fork settings model is the single writer for `settings.json`. Settings UI controls bind directly to that typed model. Runtime code observes the same model; it does not mirror these preferences into a second UserDefaults domain.

Window UI state is intentionally separate: `InspectorPresentationStore` owns last-used Inspector visibility, committed width, and active pane in the application UserDefaults domain. These values are not Ghostty configuration and are not portable user preferences.

## Settings

| Key | Type | Default | Values / Range | GUI | Apply |
| --- | --- | --- | --- | --- | --- |
| `tabs.layout` | enum | Ghostty `macos-tab-layout` | `horizontal`, `vertical` | Settings > Tabs | New windows |
| `tabs.sidebarWidth` | number | `240` | `176...480` | Settings > Tabs | Next committed/default width |
| `tabs.grouping` | enum | `none` | `none`, `project`, `date` | Settings > Tabs | Runtime |
| `tabs.ordering` | enum | `manual` | `manual`, `created`, `recentlyUsed` | Settings > Tabs | Runtime |
| `tabs.pathDisplay` | enum | `folderName` | `fullPath`, `folderName` | Settings > Tabs | Runtime |
| `tabs.showShortcutLabels` | boolean | `true` | `true`, `false` | Settings > Tabs | Runtime |
| `tabs.rememberSidebarWidth` | boolean | `true` | `true`, `false` | Settings > Tabs | Runtime |
| `tabs.sidebarVisible` | boolean | `true` | `true`, `false` | Settings > Tabs | Runtime and new windows |
| `appearance.windowTheme` | enum | Ghostty config | `system`, `light`, `dark` | Settings > Appearance | Live |
| `appearance.lightTheme` | string | Ghostty config | Ghostty theme name | Settings > Appearance | Live |
| `appearance.darkTheme` | string | Ghostty config | Ghostty theme name | Settings > Appearance | Live |
| `appearance.fontFamily` | string | Ghostty config | Installed font family | Settings > Appearance | Live |
| `appearance.fontSize` | number | Ghostty config | `6...72` | Settings > Appearance | Live |
| `appearance.backgroundOpacity` | number | Ghostty config | `0.05...1` | Settings > Appearance | Live |
| `appearance.backgroundBlur` | enum | Ghostty config | `disabled`, `enabled`, `macosGlassRegular`, `macosGlassClear` | Settings > Appearance | Live |
| `appearance.cursorStyle` | enum | Ghostty config | `block`, `bar`, `underline`, `block_hollow` | Settings > Appearance | Live |
| `appearance.tabRowDensity` | enum | `compact` | `compact`, `comfortable` | Settings > Appearance | Runtime |
| `appearance.tabIconSize` | number | `16` | `12...20` | Settings > Appearance | Runtime |
| `notifications.taskComplete` | boolean | `true` | `true`, `false` | Settings > Plugins | Runtime policy |
| `notifications.attention` | boolean | `true` | `true`, `false` | Settings > Plugins | Runtime policy |
| `notifications.sound` | boolean | `false` | `true`, `false` | Settings > Plugins | Runtime policy |
| `agents.statusHooks` | boolean | `true` | `true`, `false` | Settings > Plugins | Runtime ingress policy |
| `keyboard.quickInput` | string | `shift+command+e` | Modifier combination plus one key | Settings > Keyboard | Runtime |
| `keyboard.quickInputHeight` | number | `252` | `140...480` | Settings > Keyboard / drag divider | Runtime |
| `sessions.restoreOnLaunch` | boolean | `true` | `true`, `false` | Settings > General | Next launch |
| `general.language` | enum | `system` | `system`, `en`, `zh-Hans` | Settings > General | Live (Settings UI) |

Appearance controls resolve each value as `OMG override > Ghostty config > built-in default`. The UI reports the effective value and source, and **Reset to Ghostty** removes only OMG Appearance keys. The app writes a generated `appearance.ghostty` overlay beside `settings.json`; it never edits the user's Ghostty config. The overlay is loaded last and applied with Ghostty's existing live config update API, so current surfaces keep their PTY, shell, and scrollback.

Vertical tabs and the Right Inspector use the active terminal background color and background opacity. There is no independent Sidebar or Inspector theme. Transparency is painted only on background layers; window alpha, terminal glyphs, cursors, and icons remain opaque.

`tabs.pathDisplay` applies to the path portion of every Vertical Tab label. Local and SSH panes use the same policy: `fullPath` preserves the current full-path presentation, while `folderName` displays only the final folder component. SSH keeps its alias prefix, for example `cloud /home/user/code` becomes `cloud code`.

Settings > Keyboard > Agent Quick Input records `keyboard.quickInput`; the default is `⌘⇧E`. The composer is a real bottom dock: opening or resizing it reduces the terminal presentation height, so rows displaced from the visible grid remain reachable through normal terminal scrollback. Its 8pt drag target and 1pt divider reuse the same resize interaction and renderer-derived divider color as the left and right Sidebars. All three hit targets overlap inward over adjacent content while consuming only the 1pt divider in layout, avoiding a transparent resize gutter; `keyboard.quickInputHeight` remembers the last committed height. For a normal draft, `⌘↩` sends the text plus a real Enter key event, `⌥⌘↩` appends it to the current Pane's in-memory FIFO queue, and Escape closes the composer while preserving the draft. While editing a queued item, `⌘↩` saves it in place without sending, `⌥⌘↩` saves and moves it to the queue end, and Escape keeps the original message. The composer is backed by a native AppKit `NSTextView`, so `⌘A/C/V/X/Z/⇧⌘Z`, selection, undo, and IME marked text use standard macOS behavior. Option+left/right is explicitly mapped to word movement, Option+up/down to paragraph movement, and adding Shift extends the selection. Escape first cancels active Pinyin/IME composition; otherwise the editor consumes it to close the composer without exiting macOS fullscreen. Image-only Command-V reuses OMG's private PNG temporary-file adapter and inserts the generated path, while text/file pasteboards keep native behavior. One queued message is written only when that Pane reports a new normalized `done` Agent transition; `needsAttention` and `idle` do not drain the queue. Queued drafts appear in a dedicated 60pt bottom lane that reduces terminal presentation height instead of covering terminal text. Its 44pt cards flow left-to-right with content-aware 136–420pt widths and horizontal overflow follows the newest item. The left Enter control sends that queued message immediately; Enter, edit, and remove controls use 30×30pt hit targets plus a pointing-hand cursor. Only the central message region opens the complete-message popover after 300ms; hovering any action button never triggers it. Edit/remove actions retain spring insertion/removal transitions. Composer open/close uses an explicit animated height and high-damping spring; Queue lane presence uses the same dock animation while card reorder keeps its own spring, preventing competing layout animations during Option-Command-Enter. Placeholder and glyphs use the native editor's 13pt font, but Placeholder placement is derived from the real AppKit caret geometry rather than `textContainerOrigin` alone. In a real window the editor converts `firstRect(forCharacterRange:)` from screen to local coordinates and draws after `caretRect.maxX + 1 device pixel`; the no-window fallback uses `textContainerOrigin + lineFragmentPadding`. The caret itself is never repositioned. Marked text hides the placeholder immediately, the cursor is clamped to the font size, footer hints use 12pt, and the Queue total uses only a static tray icon plus its numeric count. Queue contents move with an in-process Pane move but are cleared when the Pane closes or OMG exits. Every write revalidates the Surface identity, the 1 MiB limit, and Secure Input before writing to the PTY.

Settings > Plugins > Agent Integration installs the versioned, removable JSON/plugin/TOML/script integration declared by each bundled Agent manifest. Detector-only Antigravity, Crush, and Hermes use an explicit Host-owned Install/Update/Remove marker instead of pretending a vendor hook exists; their process/screen fallback is disabled when the marker is removed. `agents.statusHooks` controls both normalized event ingress and the bounded local foreground-PID fallback used when an agent does not emit `SessionStart`. Vertical Tabs use the focused pane's bundled Agent glyph/title/ring and keep other panes' attention/error/done as trailing alerts; idle has no ring. Normal `done` and unexpected-interruption `error` remain visible even on the currently focused pane; Tab selection/focus does not clear them, and only mouse click or keyboard input in the owning focused terminal acknowledges the terminal state. Horizontal Tabs keep Ghostty's native presentation. **Export SSH Installer…** writes an auditable Python 3 script that the user can explicitly transfer and run in a remote account. Remote hooks work through SSH because they write the bounded event to that remote TTY; OMG does not log in or alter remote accounts automatically.

Settings > General > Sessions controls `sessions.restoreOnLaunch`. When enabled, AppKit restores every open window, canonical tab order, split tree, cwd, and typed Agent resume descriptor. Only Agents still running at quit are resumed with an exact validated conversation ID; a tab whose Agent already exited restores as a shell. SSH restore reuses original OpenSSH argv and never stores credentials or an arbitrary remote command.

Settings > General > Language controls `general.language`. `system` (the default) follows the macOS preferred language; `en` pins English and `zh-Hans` pins Simplified Chinese. The language applies live to the Settings window and the app-owned static macOS main-menu hierarchy. Dynamic window names, Services entries, terminal content, titles, and Agent events are not translated.

## Machine-readable Schema

[`schema.json`](schema.json) contains stable keys, types, allowed values, ranges, descriptions, categories, and apply requirements. Automation should read that file rather than inspect Swift source.

A future CLI should expose the same registry:

```text
omg +oh-my-config get tabs.layout
omg +oh-my-config set tabs.layout vertical
omg +oh-my-config list --json
```

The configuration action is designed but not implemented in this iteration. It will extend the existing `omg` executable rather than introduce another CLI binary, must call the typed settings registry, and must not introduce another config store.

## Validation Captures

- [`settings-appearance.png`](../images/settings-appearance.png): Dark Appearance, inherited values, source labels, optional overrides, and Reset to Ghostty.
- [`settings-appearance-light.png`](../images/settings-appearance-light.png): the same native Settings hierarchy under explicit Light Appearance.
- [`appearance-transparency-vertical.png`](../images/appearance-transparency-vertical.png): Vertical Tabs and terminal content using the same 58% Ghostty background alpha.
- [`appearance-transparency-horizontal.png`](../images/appearance-transparency-horizontal.png): native Horizontal presentation under the same Ghostty opacity/blur configuration.
