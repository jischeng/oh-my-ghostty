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
| `sessions.restoreOnLaunch` | boolean | `true` | `true`, `false` | Settings > General | Next launch |

Appearance controls resolve each value as `OMG override > Ghostty config > built-in default`. The UI reports the effective value and source, and **Reset to Ghostty** removes only OMG Appearance keys. The app writes a generated `appearance.ghostty` overlay beside `settings.json`; it never edits the user's Ghostty config. The overlay is loaded last and applied with Ghostty's existing live config update API, so current surfaces keep their PTY, shell, and scrollback.

Vertical tabs and the Right Inspector use the active terminal background color and background opacity. There is no independent Sidebar or Inspector theme. Transparency is painted only on background layers; window alpha, terminal glyphs, cursors, and icons remain opaque.

`tabs.pathDisplay` applies to the path portion of every Vertical Tab label. Local and SSH panes use the same policy: `fullPath` preserves the current full-path presentation, while `folderName` displays only the final folder component. SSH keeps its alias prefix, for example `cloud /home/user/code` becomes `cloud code`.

Settings > Plugins > Agent Integration installs the versioned, removable JSON/plugin/TOML/script integration declared by each bundled Agent manifest. `agents.statusHooks` controls both normalized event ingress and the bounded local foreground-PID fallback used when an agent does not emit `SessionStart`. Vertical Tabs use the focused pane's bundled Agent glyph/title/ring and keep other panes' attention/error/done as trailing alerts; idle has no ring, and focusing a completed pane acknowledges only that pane. Horizontal Tabs keep Ghostty's native presentation. **Export SSH Installer…** writes an auditable Python 3 script that the user can explicitly transfer and run in a remote account. Remote hooks work through SSH because they write the bounded event to that remote TTY; OMG does not log in or alter remote accounts automatically.

Settings > General > Sessions controls `sessions.restoreOnLaunch`. When enabled, AppKit restores every open window, canonical tab order, split tree, cwd, and typed Agent resume descriptor. Only Agents still running at quit are resumed with an exact validated conversation ID; a tab whose Agent already exited restores as a shell. SSH restore reuses original OpenSSH argv and never stores credentials or an arbitrary remote command.

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
