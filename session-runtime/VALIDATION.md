# Native session vertical-slice validation

Validated on local macOS arm64, 2026-10-26. This is an experimental implementation,
not SSH feature acceptance.

| Check | Result |
| --- | --- |
| Current checkout libghostty-vt ReleaseFast build | PASS |
| GhosttyKit native ReleaseFast build | PASS with TMPDIR=/tmp |
| Debug macOS App build (`macos/build.nu`) | PASS |
| Rust tests | 5 PASS (1 unit + 4 integration) |
| Clippy all targets, warnings denied | PASS |
| Zig formatting check, diff whitespace check | PASS |
| OMG documentation contract | PASS |
| Routine Swift suites | 1065 tests, 1 issue; full run FAILED |
| Failed Swift test isolated retry | PASS (9.374 seconds) |
| Desktop visual/native attach acceptance | NOT RUN: Orca CLI unavailable |
| Real Codex/Pi/Claude TUI acceptance | NOT RUN |
| Linux / SSH transport acceptance | NOT IMPLEMENTED / NOT RUN |
| Optional interactive desktop suites | NOT RUN |

The routine suite's sole reported issue was
`SSHGitExecutorTests.realSSHProvidesReadWriteAndDiffParityWithoutLocalPathFallback()`:
`SSH provider did not publish expected state`. Its isolated retry passed. This
suggests timing sensitivity but does not establish a pre-existing baseline or
prove the full suite green. No unrelated test or production timeout was modified.

The first GhosttyKit packaging attempt reported `ar: temporary file: No such file
or directory`. Rebuilding with `TMPDIR=/tmp` passed; no packaging script changed.

## What the new tests establish

- A real controlling PTY child keeps running and producing output without clients;
  reattach returns the same child PID and session ID, with an advanced output offset.
- Native Ghostty snapshot restores screen state before the next contiguous output.
- DAEMON answers a DSR query delayed until after the client has disconnected.
- Resize reaches the PTY/terminal and is reflected in subsequent attach metadata.
- Alternate-screen state and unfinished CSI, UTF-8 and OSC sequences survive binary
  snapshot restoration; subsequent output produces matching native snapshots.
- Truncated snapshots and oversized protocol frames are rejected.
- Insecure socket-directory permissions are rejected.
- Live output is held behind snapshot ACK; slow peer queue accounting stays bounded
  and marks the attachment disconnected on overflow.
- Review follow-up: a busy writer claim leaves the observer connected; clients
  receive an Exit event before normal daemon shutdown.

The tests exercise the runtime and libghostty client model. They do not exercise
`SessionBackend` through a live macOS window. GUI backend compilation is established,
but rendering, input, resize races and closing/reopening actual windows still need
runtime acceptance. Snapshot format is tied to this checkout and remains upstream
work in progress. No release installation was modified, and no commit/push was made
by this implementation session.

Local logs: `/tmp/omg-runtime-build.log`, `/tmp/omg-runtime-app.log`,
`/tmp/omg-runtime-tests.log`, `/tmp/omg-runtime-retry.log`.
