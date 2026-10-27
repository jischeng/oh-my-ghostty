# Session prototype v2: signal and pane isolation fixes

Built/signed artifact: `macos/build/Debug/OMG.app`, version
`0.0.0-dev.session-runtime.2`. Remote vps-jump helper updated atomically; existing
legacy daemon/session left running. Installed `/Applications/OMG Dev.app` is still
v1: normal quit did not stop its GUI and existing cloud SSH sessions, so overwrite
was deferred. Do not mix the v1 GUI with the new routed launcher.

Changes:
- PTY pre-exec restores default HUP/INT/QUIT/TERM/PIPE/CHLD/job-control signals and
  clears inherited signal mask. Background/nohup dispositions no longer disable Ctrl-C.
- Native surface sends its stable UUID to the relay. New tabs/splits receive new
  UUIDs; restored surfaces retain theirs. Remote attach uses a private per-UUID
  worker/socket. Marker files prevent silent recreation of exited/lost sessions.
- Launcher enables routed handshake and window saving. Set OMG Dev startup mode
  to restore tabs/sessions; quit with Cmd-Q to restore the same pane identities.
  Closing a pane and creating another intentionally creates a new session.

Tests: Rust 6 pass; stdio identity integration passes (distinct PIDs, stable
reattach); real vps-jump test created two separate sessions and interrupted sleep
with PTY 0x03, then executed a shell command successfully. Those two test sessions
were closed. GhosttyKit and Debug App builds, Clippy, targeted SwiftLint, docs and
whitespace checks pass. Full Swift suite and actual GUI restoration remain NOT RUN
for this revision.

The legacy loop still has inherited ignored signals; updating the binary cannot
repair the signal disposition of an already-running process. New routed sessions
use the fix. This remains one worker and SSH connection per session attachment;
full host multiplexing and automatic deployment are separate future work.
