# Settings organization

The settings layout follows user tasks, rather than internal implementation modules.
Otty is a visual/information-architecture reference, not a feature-parity requirement.

| Destination | Owned settings |
| --- | --- |
| General | Language, terminal close confirmation, quit behavior |
| Shell & Sessions | Shell integration, working-directory inheritance, startup/session restoration, terminal notifications |
| Input & Controls | Quick Input size/history/privacy, terminal selection, clipboard permissions/paste safety, mouse focus, Option-as-Alt |
| Editor | File/directory destination, editor keymap, wrapping/pairs, editor theme/font/tab width |
| Integrations → Agent | Per-host Hook/CLI setup and maintenance, Agent history limit, automatic Quick Input opening, Agent notifications |
| Views & Tabs | Horizontal/vertical tabs, sidebar geometry, grouping/order/path, tab density/icons, resize rendering |
| Appearance | Terminal theme, fonts, opacity/blur, cursor and font inheritance |
| Shortcuts | Quick Input and Inspector shortcut recorders; original Ghostty keybinding configuration access |
| Integrations → Git | Auto-fetch, ordered AI commit routes and instructions |
| Integrations → SSH | Explicit host registration and cached inventory |
| Integrations → Plugins | Official and GitHub plugin installation/management |
| Advanced | OMG/Ghostty config locations, precedence, open/reload/reveal actions |

## Search and shared layout

Sidebar search accepts Chinese/English terms and persisted setting IDs. Results
navigate to their owning section, rather than inventing a second editable copy.
`SettingsSearchCatalog` maps descriptors by the most specific key prefix; unknown
future descriptors fall back to Advanced. Tests require exactly one destination per
descriptor. `OMGSettingsRow` provides a label/caption with a trailing control;
`OMGSettingsSection` gives sections stable scroll anchors and themed cards. Controls
must remain usable at the 720-point minimum window width, in both languages and
appearances. Long warnings and destructive actions retain their original semantics.

Settings controls share a 32-point action height, subtle themed background/border,
consistent corner radius and trailing alignment. `OMGSettingsPicker` draws a full-width
trigger with a single trailing chevron; its transparent native button opens an `NSMenu`
for keyboard/type-ahead and accessibility, with a checkmark on the current value.
This avoids the macOS SwiftUI Menu bridge discarding custom label layouts. Menu
selection uses captured values, not mutable list positions. Disabled controls cannot
commit changes. Short choices use `OMGSettingsSegments`; numeric fields use direct
editing plus minus/plus controls. Destructive buttons remain red and keep their
existing confirmations. Agent navigation keeps its `.agents` identifier but is now
labelled **Agent** inside the expandable **Integrations** group.

## Optional core behavior overrides

The 18 options in `CoreSetting.all` are capabilities already implemented in Ghostty:
close confirmation/last-window exit, working-directory and font inheritance, shell
integration, selection clearing, copy-on-select, clipboard read/write/trim/paste
safety, mouse focus/hiding, Option-as-Alt, terminal notifications and cursor blinking.

They are stored as `core.<ghostty-key>` in OMG `settings.json`; the value is an
allowlisted string. The empty value or a missing key means **Follow Ghostty Config**.
It is not a guessed built-in value or a forced default. Explicit choices are written
to the existing generated `appearance.ghostty` overlay, loaded after the original
Ghostty config. Resetting an option removes only its OMG override. The original
file and unrelated/unknown JSON keys are preserved. Invalid values cannot inject
new config lines. Real Ghostty parser tests validate every exposed value and prove
that removing an override restores inheritance.

Shell integration and inheritance changes affect newly created terminals. Other
options use the existing config reload pathway and retain Ghostty's runtime rules;
for example, terminal applications can override cursor blinking. No defaults or
existing JSON key names are migrated merely by reorganizing pages.

## Explicitly not claimed

This pass does not implement Otty Recipes, new completion/history engines,
per-command replay, a general-purpose Ghostty keybinding editor, custom theme
thumbnail galleries, browser data management, or unimplemented Agent sleep/badge
policies. These need separate capability designs, not inert switches. Existing
Ghostty settings beyond the closed catalog remain available through the original
configuration file. Existing editor capabilities are exposed; unsupported controls
are not fabricated for screenshot parity.
