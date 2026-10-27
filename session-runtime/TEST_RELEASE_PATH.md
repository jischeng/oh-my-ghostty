# Test the automatic deployment path

Use OMG Dev PTY, not release OMG. Open Settings → Shell & Sessions → Session Runtime.
Enter an SSH alias or `user@host` and Connect. The app deploys matching bundled
runtime artifacts; no local checkout, test-vps-jump script or remote compiler is
required on this path. SSH config carries ports/jump hosts/keys. Password and host
key prompts use SSH askpass. Unsupported platforms or setup errors are visible.

Lifecycle settings apply to newly created Sessions. Default detached lifetime is
24 hours; 0 explicitly disables it. An optional ISO-8601 cutoff applies only while
detached. Completion cleanup is off by default; enable it with a grace period only
for supported Agent hooks and conversation stores. Connections install the current
OMG Codex/Claude/Pi hooks when remote Python 3 is available. No Python means terminal
persistence still works, but completion cleanup/recovery cannot be assumed.

Checks:

1. Connect, inspect remote hostname/PID, split and create tabs. Each pane has a
   distinct PID and inherits its host descriptor. Normal new local windows remain
   local. Two configured hosts must not share sessions.
2. Cmd-Q and reopen OMG Dev PTY normally. No test launcher is needed for descriptor
   panes. Layout, IDs and still-live remote PIDs must match.
3. Set a short detached TTL for a new session, disconnect and wait. Its process
   should terminate; reopen displays an ended-session error for ordinary shells.
   Output alone must not prevent expiry. Check the record's reason remotely.
4. With a supported real Agent, record its conversation ID, let its task complete
   while detached, wait through the grace period, then reopen. PID changes but the
   original conversation resumes. Missing conversation metadata/file must fail
   visibly, never silently start a fresh conversation.
5. Existing live sessions keep their policy and runtime revision. App updates may
   reuse a cached runtime only if the snapshot compatibility hash matches. Incompatible
   cores preserve the remote process and report the mismatch.

Current release gates remain in RELEASE_PROGRESS.md: ordinary typed `ssh host`
is not yet intercepted into this native path, transparent network reconnect and
full management UI remain pending, and real vendor Agent/cross-platform execution
acceptance is required before public release. The development default for quitting
without a prompt is enabled in the PTY profile, independent from other OMG variants.
