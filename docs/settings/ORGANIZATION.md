# Settings organization

The settings layout follows user tasks, rather than internal implementation modules.
Otty is a visual/information-architecture reference, not a feature-parity requirement.

| Destination | Owned settings |
| --- | --- |
| General | Language, terminal close confirmation, quit behavior, and unified Notifications (terminal desktop notifications + Agent task completion/attention notifications & sound tone) |
| Appearance | Window/OMG theme, fonts, opacity/blur, cursor, focused split border, and font inheritance |
| Views & Tabs | Layout & Sidebar (horizontal/vertical tabs, default sidebar view, sidebar visibility/width/remembered width), Tabs List (grouping/order/path), Inbox View (inbox grouping/order/Continue window), Automatic Tab Titles (naming mode, always-shorten switch, title model sheet), Display & Resize (row density/icon size/shortcut badges/resize rendering/reset) |
| Shell & Sessions | Session recovery on launch, new tab/split inheritance, persistent terminal sessions (background runtime toggles, keep-on-quit controls, detached lifetime, expiration, Agent completion cleanup), shell integration |
| Input & Controls | Quick Input (composer height/opacity, auto-open on Agent start/complete, Control-J newline, Agent draft import), Sent History, text selection, clipboard permissions/paste safety, mouse focus, Option-as-Alt |
| Editor | File/directory destination, editor keymap, wrapping/pairs, typography, inline Editor Theme (background mode, syntax theme, opacity, blur), reset |
| Shortcuts | Quick Input, sidebar/inbox/inspector/workspace shortcut recorders, number shortcut families, Ghostty keybinding configuration access |
| AI | Unified Model Services (API services managed via modal sheets without draft leakage, alongside Local CLI model sheets in consistent `Codex`, `Claude Code`, `Pi`, `OpenCode` order), Terminal Coding Agents (live status toggle & local status extension/CLI setup), Agent History (session limit & background indexing) |
| Git | Auto-fetch interval, and AI Commit & PR Messages (ordered fallback models added from one unified API + Local CLI picker sheet, plus custom commit prompt sheet) |
| Remote Machines | Explicit SSH host registration, connection setup, inline host discovery toggle, and cached Agent inventory |
| Mobile Devices | LAN / Tailscale mobile gateway pairing and provisioning |
| Plugins | Official and local plugin installation/management with inline version and update controls |
| Advanced | OMG/Ghostty config locations, precedence, open/reload/reveal actions, and OMG Doctor diagnostics |

## Search and shared layout

Sidebar search accepts Chinese/English terms and persisted setting IDs. Results
navigate directly to their owning section on the page without redundant secondary
menus or duplicate editable copies. `SettingsSearchCatalog` maps descriptors by
the most specific key prefix; unknown future descriptors fall back to Advanced.
Tests require exactly one destination per descriptor and verify that every search
entry resolves to a live anchor on its destination page. Modal configuration tasks
(creating/editing an API service, inspecting CLI models, choosing task models,
editing custom prompts, adding an SSH host) use native AppKit sheets rather than
mutating settings eagerly or pushing multi-level navigation stacks. The AI page
keeps its `.agents` identifier so deep links and `agents.*` setting keys remain
unchanged while presenting general-purpose AI providers and Coding Agent setup.

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
