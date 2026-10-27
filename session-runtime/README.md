# Native SSH Session Runtime

The GUI uses a per-pane host descriptor. Local windows have no remote routing.
There is no fixed host, global experimental socket override or legacy VPS launcher.

Open **OMG Dev PTY → Settings → Shell & Sessions → Session Runtime**, select the
retention policy, enter an SSH alias or user@host and connect. Deployment uses
versioned artifacts bundled with the signed app. Tabs/splits inherit that host;
restored panes attach by their saved identity.

See [TEST_RELEASE_PATH.md](TEST_RELEASE_PATH.md) for current acceptance steps and
[RELEASE_PROGRESS.md](RELEASE_PROGRESS.md) for remaining public-release gates.

## Runtime architecture

One host daemon manages multiple session actors/PTYs. A per-host relay multiplexes
all panes over one SSH connection. Session IDs survive detach; snapshot plus live
output restores the terminal. Remote cwd metadata comes from the PTY foreground
process, falling back to its owning shell, rather than the Mac launch directory.

## Tests

Build the matching libghostty-vt first, then run serially:

```sh
cargo test --manifest-path session-runtime/Cargo.toml -- --test-threads=1
cargo build --manifest-path session-runtime/Cargo.toml
python3 session-runtime/tests/test_sessions.py
python3 session-runtime/tests/test_location.py
python3 session-runtime/tests/test_lifecycle.py
python3 session-runtime/tests/test_agent_recovery.py
```

The optional SSH test takes an explicit connection JSON via
`OMG_SSH_TEST_CONFIG`; it never chooses a fixed host.
