# Single host daemon and multiplexed SSH transport

Current implementation supersedes the per-session subprocess prototype described
in VPS_TEST.md and FIXES_V2.md. GUI v2 uses the same local H(UUID) handshake.

## Process model

One `omg-sessiond host DIRECTORY -- SHELL...` owns a registry and creates one
session actor thread per pane UUID. Each actor owns its PTY, shell child, VT state
and attachment queues. Shells share the host daemon as their parent; there is no
per-session daemon subprocess. Actors currently communicate with the transport
through private per-session Unix sockets inside the same daemon process.

One `ssh-relay` invocation creates one SSH subprocess and one remote bridge for
all attached panes. Outer frames multiplex H(open UUID), D(encoded inner frame),
Q(detach) and E(error) by connection-local stream ID. Existing inner snapshot ACK,
output offsets, writer ownership, resize and exit messages are unchanged.

Queues are byte-bounded, iteration and flush work is bounded per peer. Slow pane
connections are disconnected; exhausting the shared transport budget disconnects
that transport, preserving PTYs. This is bounded failure, not full per-stream
credit flow control or strict latency isolation. A large snapshot may still cause
head-of-line latency on the shared SSH byte stream.

Limits: 64 recorded session IDs per daemon lifetime, 64 streams per connection,
8 host transports. Exited IDs remain tombstones; restart cannot silently recreate
a marked session. IDs/marker cleanup and a session management UI remain future
work. Host daemon crash kills all its PTY ownership; no FD handoff is claimed.

## Deployment and testing

vps-jump test host lives at `/root/.local/share/omg-host-test`. Its daemon is
launched with nohup; no automatic service deployment or reconnect has been added.
The older `/root/.local/share/omg-session-test` workers were not migrated or killed.

Use the existing GUI v2 with:

```sh
bash session-runtime/test-vps-jump.sh
```

The script now uses the new host directory. Existing pane IDs from the old test
backend are first-time sessions on this host, so their old PIDs do not migrate.
Subsequent restore on this host preserves their PIDs. Keep the startup preference
set to restore tabs/sessions; use Cmd-Q rather than closing panes to test restore.

The launcher refuses to start if OMG Dev PTY is already running. Start this
experiment through the script, not by opening another copy from Finder first.
The PTY GUI also holds a profile lock before AppDelegate loads restoration data,
so simultaneous launches cannot overwrite each other's workspace/session catalog.
The lock is released automatically at process exit and is not inherited by shell
children. Other OMG bundle IDs use separate profiles and remain independent.

## Validation

- Rust 6 tests pass (PTY persistence, snapshots, framing, permissions, bounded
  queues/ACK barrier, inherited signal reset).
- `python3 session-runtime/tests/test_sessions.py` passes: two distinct shells
  have one common host parent PID, survive transport reconnect, and terminate
  separately; ended IDs cannot silently respawn.
- `OMG_SSH_TEST=1 python3 session-runtime/tests/test_ssh_mux.py` passes on vps-jump:
  two local pane sockets share exactly one SSH child; killing it and restarting
  relay retains both remote PIDs; Ctrl-C resumes shell; Close delivers Exit.
- macOS helper and Linux x86_64 release cross-build pass; Clippy warnings denied,
  docs and diff whitespace checks pass.
- Actual GUI visual regression remains manual; no GUI source change in this step.

Linux testing found parent-retained PTY slave handles in Command after spawn.
Dropping Command immediately after spawn fixes missing EOF/Exit notification.
The shared SSH transport also drains queued Exit/output before closing a pane.

This is the next experimental runtime iteration, not completion of automatic
SSH bootstrap, multi-host connection pooling across separate relay processes,
service upgrades or full session management. One relay per host is still enforced
by the test launcher rather than by an app-wide HostConnection coordinator.
