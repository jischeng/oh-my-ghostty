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

## Workspace layout

Each workspace remembers sidebar visibility and width, Inspector visibility,
width and selected panel, and Quick Input visibility, pinning and height. Tabs
within a workspace share these presentation preferences. New workspaces start
from the global sidebar and composer defaults; changing one workspace does not
change another workspace's saved layout. Quick Input drafts, queues and send
targets remain attached to their original panes. Theme, fonts and keyboard
shortcuts remain global.

## Session behavior

Switching workspaces keeps existing Surface/PTY objects alive. Background local
commands, Agent sessions and SSH clients continue running and consuming resources.
A network failure can still disconnect SSH independently of workspace switching.
Returning restores the saved tab order and selected tab. Native tab-group changes
during a handoff are not published to the sidebar: each workspace retains its
layout/host, and the destination list and selection appear together after the
handoff. This prevents intermediate mixed lists and selection-driven scrolling.
A workspace already
visible in another window is focused there instead of duplicated.

Named workspace sessions are now checkpointed independently to
`workspaces/sessions.json` while the app runs. A valid nonempty checkpoint takes
precedence over AppKit restoration and resumes supported Agent/SSH descriptors.
Closing a window retains its saved tabs; explicitly closing a tab removes it.
Checkpoints preserve native window grouping, selected tabs, window frames and
native fullscreen state. Older checkpoints without these fields fall back to
one group per workspace. Startup assembles groups before showing selected tabs;
quit freezes hidden-workspace metadata before window teardown begins. If all
records fail to decode, startup creates a terminal; if restoration leaves every
window hidden, it reveals an existing workspace.
Snapshots are written on structural changes and checked once per second for
changed directory/title/resume data. A forced kill restores the last successful
checkpoint; changes not yet written at the instant of termination may be lost.
This is process reconstruction, not a process checkpoint: arbitrary running
commands and remote jobs cannot be resurrected by OMG.

Without a named-workspace checkpoint, legacy recovery follows **Settings > Sessions > Startup Mode**:

- Restore Sessions uses existing supported Agent and SSH resume descriptors and
  shell restoration behavior.
- Restore Tabs recovers layout and directories without resuming those processes.
- New Terminal starts fresh; the named workspace catalog remains available.

Restarting the application does not preserve arbitrary running processes. Agent
resume requires a supported exact conversation descriptor. SSH reconnect and
remote process persistence retain their existing limitations.

Workspace metadata is written atomically to `workspaces/catalog.json` inside the
channel-specific Application Support directory (`OMG` or `OMG Dev`). It records
names, appearance, shortcut slots, tab membership, selected tabs, parked-group
order and workspace layout preferences. It does not contain terminal output, SSH credentials or Agent transcripts.
The directory uses mode 0700 and the catalog uses mode 0600. Session content is
handled by the existing AppKit/terminal restoration path.
