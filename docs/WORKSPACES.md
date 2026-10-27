# Terminal workspaces

Named workspaces keep separate groups of terminal tabs, for example Personal for
personal projects and Work for company projects. They organize terminal sessions;
they do not sandbox files, credentials, shell environment variables or networking.

## Use

The upper-left workspace name replaces the vertical sidebar's TABS heading. Click
it to search, switch, create or edit a workspace. Each workspace has a name, symbol
and muted accent color. When the vertical sidebar is hidden, or horizontal tabs
are enabled, a compact workspace control remains above the terminal content.

- `Control-Command-W`: open the searchable switcher. It initially selects the
  previous workspace; Return confirms, arrow keys choose, Escape cancels.
- `Control-Command-1` through `Control-Command-9`: select the corresponding
  workspace in its fixed catalog order.
- **New Workspace…**: choose a name, icon and color, then start with a local shell.
- **Edit Current Workspace…**: rename or change its appearance.
- **Move Current Tab to**: move the complete tab, including its splits and live
  sessions. Moving the last tab leaves a new shell in the source workspace.

Configure shortcuts in **Settings > Shortcuts > Workspaces**. Workspace shortcuts
must include Command and apply inside OMG. Conflict captions cover duplicate
workspace shortcuts, OMG panel/composer shortcuts, menu items and detected
Ghostty bindings. Third-party global shortcuts are not exhaustively detectable.
Existing tab and Inspector panel shortcuts retain their meanings.

## Session behavior

Switching workspaces keeps existing Surface/PTY objects alive. Background local
commands, Agent sessions and SSH clients continue running and consuming resources.
A network failure can still disconnect SSH independently of workspace switching.
Returning restores the saved tab order and selected tab. A workspace already
visible in another window is focused there instead of duplicated.

Restart recovery follows **Settings > Sessions > Startup Mode**:

- Restore Sessions uses existing supported Agent and SSH resume descriptors and
  shell restoration behavior.
- Restore Tabs recovers layout and directories without resuming those processes.
- New Terminal starts fresh; the named workspace catalog remains available.

Restarting the application does not preserve arbitrary running processes. Agent
resume requires a supported exact conversation descriptor. SSH reconnect and
remote process persistence retain their existing limitations.

Workspace metadata is written atomically to `workspaces/catalog.json` inside the
channel-specific Application Support directory (`OMG` or `OMG Dev`). It records
names, appearance, shortcut slots, tab membership, selected tabs and parked-group
order. It does not contain terminal output, SSH credentials or Agent transcripts.
The directory uses mode 0700 and the catalog uses mode 0600. Session content is
handled by the existing AppKit/terminal restoration path.
