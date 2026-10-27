# OMG native session runtime — experimental vertical slice

**Current architecture:** one host daemon owns multiple session actor threads;
one SSH relay multiplexes all attached panes over one SSH subprocess. See
[HOST_RUNTIME.md](HOST_RUNTIME.md) for the current protocol, deployment, limits
and validation. The original single-session `serve` experiment below remains a
low-level test entry point; `host` is the current SSH product prototype.

This prototype owns a real PTY in a Rust daemon and uses **this checkout's**
libghostty-vt for authoritative terminal state, query replies and complete binary
snapshots. It never launches tmux or a local attach PTY. The macOS host retains
its existing Ghostty renderer and input pipeline through `src/omg/session/SessionBackend.zig`.

## Build and test

From the repository root, run serially:

```sh
mise exec zig@0.16.0 -- zig build -Demit-lib-vt -Demit-macos-app=false -Doptimize=ReleaseFast -Dversion-string=1.3.2-dev
cargo test --manifest-path session-runtime/Cargo.toml -- --test-threads=1
```

The C shim compiles against `include/ghostty/vt.h`; the Rust executable dynamically
links `zig-out/lib/libghostty-vt`. The build embeds a development rpath to this
checkout. These are development artifacts, not deployable remote packages.

## Native host experiment

Build GhosttyKit and the Debug app using `.agents/skills/omg-build/SKILL.md`.
Create a private directory, then run the daemon in a separate terminal:

```sh
mkdir -m 700 /tmp/omg-session-experiment
cargo run --manifest-path session-runtime/Cargo.toml --bin omg-sessiond -- \
  serve /tmp/omg-session-experiment/session.sock -- /bin/zsh -l
```

Launch the development executable directly with:

```sh
OMG_EXPERIMENTAL_SESSION_SOCKET=/tmp/omg-session-experiment/session.sock \
  macos/build/Debug/OMG.app/Contents/MacOS/omg
```

The Debug app uses the development bundle ID and settings, shared with OMG Dev.
Quit existing development instances before this experiment; the release app can
remain running. Start with exactly one experimental window. The environment variable selects this
backend for **every newly created surface in that process**. Do not set it for
your normal app. Disconnecting a surface only closes its socket. Start a new
surface/process with the same variable to attach again. The prototype has no
settings UI, automatic reconnect or user-facing close-session action.

## Protocol v1 experiment

Frames are `[kind:u8][output_offset:u64 BE][length:u32 BE][payload]`, maximum
16 MiB. One daemon owns one session, explicitly created by its launch command.
There is no per-pane SSH process, SSH transport, remote deployment or stream
multiplexing yet. The framing is **not** the final product protocol.

- `J`: initial metadata: version, session ID, child PID, dimensions, attachment ID.
- `S`: complete native Ghostty snapshot at the current output byte offset.
- `A`: client acknowledges snapshot at that offset. Live frames wait behind it.
- `W`: claim writer, acknowledged only if unclaimed or already owned.
- `B`: writer busy; the attachment remains a read-only observer.
- `O`: PTY bytes; offset identifies the end of the chunk, validated by clients.
- `I`: writer input; never automatically replayed on reconnect.
- `R`: writer resize, two big-endian u16 dimensions; ordered broadcast to clients.
- `K`: explicit writer close (SIGTERM process group, SIGKILL after two seconds).
- `X`: process exit.

A disconnected writer releases ownership. Observers cannot write or resize;
the prototype GUI does not automatically reclaim ownership. Close and reopen an
observer after the old writer disconnects to claim input.
Queues are bounded by bytes; slow peers disconnect and must request a fresh
snapshot. PTY reading continues without peers. Snapshot schema compatibility is
currently limited to the same checkout; production negotiation is not implemented.

## Scope and remaining work

This is a feasibility experiment, not a shipped SSH feature. Remaining gates:
GUI execution/visual verification, broader Swift regressions, Linux execution,
real Agent TUI acceptance, robust authenticated capability negotiation, multi-session
registry and fair transport multiplexing, reconnect UI, clipboard/notification policy,
query capability parity, bounded snapshot decode allocation, and service management.

The daemon ends after its child exits; it does not retain exited sessions. Daemon
crash/restart does not preserve PTYs. Close cannot guarantee termination of
subprocesses which have escaped the process group. The host uses a bounded blocking
socket write as a prototype; replace this with queued asynchronous writes before
production. An experimental attach is deliberately explicit; no local session is
silently migrated.
