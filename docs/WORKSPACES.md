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
  current window's previous workspace; Return confirms, arrow keys choose, Escape cancels.
- `Control-Command-1` through `Control-Command-9`: select the corresponding
  workspace in its fixed catalog order.
- **New Workspace…**: choose a name, icon and color, then start with a local shell.
- **Edit Current Workspace…**: rename or change its appearance. The name field
  receives initial keyboard focus in both the create and edit forms.
- **Delete Current Workspace…**: confirm removal of the workspace label. Its live
  and saved tabs move to the default workspace in their respective windows;
  running sessions are retained. The default workspace cannot be deleted.
- **Move Current Tab to**: move the complete tab, including its splits and live
  sessions, into the target workspace in the same window. Moving the last tab
  leaves a new shell in that window's source workspace.

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

## Multiple windows

Each window switches workspaces independently. A stable window identity owns one
tab group per workspace, with its own tab order, selection and sidebar scroll
position. For example, if A shows workspace One with a1/a2 and B shows One with
b1/b2, switching B to Two and back restores b1/b2 in B; A stays unchanged.
Opening a workspace for the first time in B creates B's own terminal rather than
focusing A or moving A's tabs. New windows inherit the current workspace name
but receive a new window identity. Native tab detachment likewise creates an
independent window; explicit tab joins and undo transfer/restore that identity.
Workspace appearance and panel preferences are shared by workspace; terminal
content, drafts and send targets remain pane-owned.

## Session behavior

Switching workspaces keeps existing Surface/PTY objects alive. Background local
commands, Agent sessions and SSH clients continue running and consuming resources.
A network failure can still disconnect SSH independently of workspace switching.
Returning restores the saved tab order and selected tab. Native tab-group changes
during a handoff are not published to the sidebar: each workspace retains its
layout/host, and the destination list and selection appear together after the
handoff. This prevents intermediate mixed lists and selection-driven scrolling.
Only the current window's destination group participates in the switch. Other
windows displaying the same workspace keep their own sessions and selection.

Named workspace sessions are now checkpointed independently to
`workspaces/sessions.json` while the app runs. A valid nonempty checkpoint takes
precedence over AppKit restoration and resumes supported Agent/SSH descriptors.
Closing a window retains its saved tabs; explicitly closing a tab removes it.
If the current window's group has no usable presentation when selected again,
OMG reconstructs that group's saved tabs and splits, preserving their order and
selected tab. Records belonging to another window are not merged or claimed. It does not re-show closed windows whose content views have been
torn down. Explicitly removed tabs stay removed; a workspace without a restorable
record opens a fresh terminal. Reconstructing a closed workspace uses the same
supported session descriptors as startup, not arbitrary live process recovery.
Checkpoints preserve native window grouping, selected tabs, window frames and
native fullscreen state, stable window/group IDs and each window's current and
previous workspace. Legacy checkpoints migrate each saved native group to an
independent window identity; unrelated parked groups are not guessed to share
one window. The oldest records without any group field fall back to one group
per workspace. Startup assembles groups before showing selected tabs;
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
names, appearance, shortcut slots, tab membership, window-owned groups and their
selected tabs/order/scroll positions, window presentation and workspace layout preferences. It does not contain terminal output, SSH credentials or Agent transcripts.
The directory uses mode 0700 and the catalog uses mode 0600. Session content is
handled by the existing AppKit/terminal restoration path.
