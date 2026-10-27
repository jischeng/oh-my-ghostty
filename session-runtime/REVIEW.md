# Native session prototype review

Review scope: session-runtime and native backend changes, staged + unstaged.
Unrelated Git UI worktree changes were left untouched.

## Fixed

- Native implementation moved to `src/omg/session/SessionBackend.zig`; no reference
  project names occur in runtime implementation. `src/omg_session_host.zig` is the
  minimal adapter to Ghostty's pre-existing terminal-I/O type. Existing upstream
  module names remain unchanged.
- Busy writer claims now return B and keep the requester attached as observer.
- Socket send failure shuts down the connection; a partially written frame cannot
  be followed by new frames and corrupt the byte stream.
- Initial window dimensions cross the reader/host thread boundary through an atomic
  packed value instead of reading host-owned mutable size concurrently.
- Normal child exit queues Exit after output and permits bounded draining before
  terminating the daemon, instead of one best-effort flush.
- Native client checks protocol version before accepting metadata.

## Verification

Rust: 5 tests pass, including observer liveness and Exit delivery added to the
real-PTY scenario. Clippy all targets with warnings denied passes. GhosttyKit and
Debug App rebuilt successfully with TMPDIR=/tmp. Diff whitespace check passes.
The previous full Swift run and its failed-test retry remain recorded in
VALIDATION.md; the full suite was not repeated in this review.

## Remaining limits / recommendation

Suitable for controlled manual prototype testing, not release approval. Actual
native-window/TUI acceptance is outstanding. No automatic reconnect, no writer
transfer UI, no SSH transport or multi-session manager. Blocking socket writes can
stall the host I/O thread until timeout. Snapshot schema is tied to the checkout;
remote negotiation, decode resource hardening and terminal capability/side-effect
policies need further work. Observer becomes writer only after explicit reattach.

Follow MANUAL_TEST.md. Do not interpret build success as rendering correctness or
as confirmation that every terminal query and Agent feature is supported.
