# vps-jump experiment

Installed OMG Dev: `0.0.0-dev.session-runtime`, persistent Apple Development signing,
ReleaseFast GhosttyKit. This is an explicitly marked worktree experiment, not a
clean-commit/tag release. The standard clean-tree installer was not used; the
previous Dev bundle was backed up to `/Applications/OMG Dev.before-session-runtime-20261026.app`.
Release OMG was not changed.

Remote: Linux x86_64, glibc 2.34. Cross-compiled daemon and libghostty-vt uploaded to
`/root/.local/share/omg-session-test`. No Rust/Zig toolchain installed remotely.
Daemon runs under nohup with a single bash login session; this is not yet systemd
service management. Daemon PID 3844517, initial shell PID 3844518.

Quit any existing OMG Dev instance, then from a separate terminal run:

```sh
cd /Users/chengjisheng/code/test/oh-my-ghostty
bash session-runtime/test-vps-jump.sh
```

This connects the experimental native backend through a local Unix socket relay,
`ssh -T vps-jump`, remote stdio bridge and remote daemon. No intermediary PTY.
This is a single-session transport experiment, one SSH connection per attachment;
shared host connection multiplexing remains unimplemented. Plain `ssh vps-jump`
does not automatically attach to the durable session.

In the new window verify `hostname` and `echo $$`. Run a timer or installed Agent,
quit OMG Dev without exiting the shell/Agent, wait, then rerun the same script.
PID should remain unchanged; current TUI and input should recover. Do not issue
`exit` until finished: the prototype daemon ends when the shell exits. Existing
observers do not automatically become writer; use one window for this experiment.

Validated: real SSH process kill/reconnect retained PID/session and returned native
snapshot; full local relay→SSH→bridge→daemon returned metadata and snapshot. Actual
GUI/Agent visual acceptance is still manual. Runtime unit/integration tests 5 pass,
Clippy passes, installed app signature/hash/version and 6 SSH wrapper tests pass.

A Linux `io::copy` pipe path stalled small protocol frames; bridge output now uses
an explicit read/write loop. Linux binary was rebuilt and atomically replaced for
new bridge processes without restarting the existing daemon/session.

The launcher lives in the checkout and requires its built helper and libghostty
library. This experiment is not a self-contained deployable release.
