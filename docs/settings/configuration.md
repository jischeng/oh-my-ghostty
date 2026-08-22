# Oh My Ghostty Settings

Fork-specific preferences are stored in:

```text
~/.config/oh-my-ghostty/settings.json
```

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
  "tabs.sidebarWidth": 300
}
```

Reload the file with **Settings > Advanced > Reload** or Ghostty's **Reload Configuration** command. `tabs.layout` applies to newly created windows because changing the NSWindow/titlebar class of an existing terminal would risk rebuilding its presentation hierarchy.

## Ownership And Precedence

| Layer | Owns | Priority |
| --- | --- | --- |
| Runtime/window state | Current sidebar visibility, current live width, collapsed groups, selected tab | Highest |
| Oh My Ghostty settings | Optional fork and Appearance overrides listed below | Second |
| Ghostty config | Inherited baseline, including `macos-tab-layout`, theme, font, opacity, blur, and cursor | Third |
| Built-in defaults | Safe values for unset settings | Lowest |

The fork settings model is the single writer for `settings.json`. Settings UI controls bind directly to that typed model. Runtime code observes the same model; it does not mirror these values into a second UserDefaults domain.

## Settings

| Key | Type | Default | Values / Range | GUI | Apply |
| --- | --- | --- | --- | --- | --- |
| `tabs.layout` | enum | Ghostty `macos-tab-layout` | `horizontal`, `vertical` | Settings > Tabs | New windows |
| `tabs.sidebarWidth` | number | `240` | `176...480` | Settings > Tabs | Next committed/default width |
| `tabs.grouping` | enum | `none` | `none`, `project`, `date` | Settings > Tabs | Runtime |
| `tabs.ordering` | enum | `manual` | `manual`, `created`, `recentlyUsed` | Settings > Tabs | Runtime |
| `tabs.showShortcutLabels` | boolean | `true` | `true`, `false` | Settings > Tabs | Runtime |
| `tabs.rememberSidebarWidth` | boolean | `true` | `true`, `false` | Settings > Tabs | Runtime |
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

Appearance controls resolve each value as `OMG override > Ghostty config > built-in default`. The UI reports the effective value and source, and **Reset to Ghostty** removes only OMG Appearance keys. The app writes a generated `appearance.ghostty` overlay beside `settings.json`; it never edits the user's Ghostty config. The overlay is loaded last and applied with Ghostty's existing live config update API, so current surfaces keep their PTY, shell, and scrollback.

Vertical tabs and the Right Inspector use the active terminal background color and background opacity. There is no independent Sidebar or Inspector theme. Transparency is painted only on background layers; window alpha, terminal glyphs, cursors, and icons remain opaque.

## Machine-readable Schema

[`schema.json`](schema.json) contains stable keys, types, allowed values, ranges, descriptions, categories, and apply requirements. Automation should read that file rather than inspect Swift source.

A future CLI should expose the same registry:

```text
ghostty +oh-my-config get tabs.layout
ghostty +oh-my-config set tabs.layout vertical
ghostty +oh-my-config list --json
```

The CLI is designed but not implemented in this iteration. It must call the typed settings registry and must not introduce another config store.

## Validation Captures

- [`settings-appearance.png`](../images/settings-appearance.png): inherited Appearance values, source labels, optional overrides, and Reset to Ghostty.
- [`appearance-transparency-vertical.png`](../images/appearance-transparency-vertical.png): Vertical Tabs and terminal content using the same 58% Ghostty background alpha.
- [`appearance-transparency-horizontal.png`](../images/appearance-transparency-horizontal.png): native Horizontal presentation under the same Ghostty opacity/blur configuration.
