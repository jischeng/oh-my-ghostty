# Host runtime

Each versioned remote host daemon owns multiple session threads, PTYs and children.
Local sessions use a persistent per-channel broker (`host-local`) plus an independent
holder process (`session-holder`) per session; each holder owns its PTY, VT state and
child. Each pane has a persistent UUID; its saved descriptor identifies its local or
SSH host and runtime revision. The App owns one multiplexed relay per connection/revision.

The local H handshake carries an explicit open request. The outer protocol routes
open/data/detach/error frames by stream ID. Remote output, resize, snapshot ACK,
writer arbitration and exit remain per Session. The M metadata frame supplies the
PTY foreground/shell cwd on attach and changes. It also reports password input
mode and child runtime; local sessions include validated foreground PID and
slave PTY name for local-only process presentation.
J version 2 includes cell and pixel dimensions, password-input state and elapsed
runtime. M repeats those metadata as they change; the final runtime M is queued
before X, whose exit-code text remains unchanged. R accepts the legacy four-byte
cell-size form and the version-two eight-byte cell-plus-pixel form.

`connect LOCAL_SOCKET CONNECTION_JSON` supports `transport: "ssh"` (also the
default for old JSON) and `transport: "local"`. The local transport uses a private,
stable per-channel `local_state_directory` (`omg-local-v2` key) across releases while
still discovering unlocked legacy revision-scoped siblings; it bypasses SSH but shares
the host protocol. Local broker bootstrap serializes concurrent callers with
`<root>/bootstrap.lock` before racing `host.sock`.
The relay owns the listener and pane sockets independently from its replaceable
host connection. `retry-local LOCAL_SOCKET --interactive` requests an immediate
retry with explicit interactive authentication; healthy streams remain attached.
Local startup prefers the helper from the descriptor's versioned bundle when present
and falls back to the active binary if a pinned historical helper is absent. On macOS,
`HostIdentity` (`host.meta` and `b'V'`) also records the local wrapper mode
(`app-bundle` vs `unbundled`), parent `+internal-runtime-host` PID, executable path and
on-disk `(st_dev, st_ino)`. When `ensure_host_mode` (`omgd connect` or
`omgd ensure-host --local`) finds a running local broker whose `revision` changed (with
compatible `snapshot-revision`) or whose `+internal-runtime-host` parent wrapper became
unhealthy after an in-place `.app` replacement (Sparkle rename/unlink or `rm -rf` +
`ditto` inode change, even when `revision` is unchanged) while a valid `.app` bundle is
present on disk, it requests a `b'T'` broker takeover (falling back to a verified
`host.lock` + `omgd host-local` single-PID `SIGTERM` for pre-takeover brokers), waits
for `host.lock` release so the old `+internal-runtime-host` `bootout`s and exits, and
bootstraps a fresh `+internal-runtime-host` + `host-local`. Live `host-local` also
checks its own wrapper health on poll ticks and before `b'C'` new local holder creation,
stepping down before `SNAPSHOT` when an on-disk replacement `.app` invalidated its
wrapper so `omgd connect` reconnects transparently. A broker can exit while its holders
continue running; the replacement broker verifies each holder with its UUID, generation
and private capability before adopting it. Persisted session `Record` PIDs remain
metadata only and are never signalled.

Only local C/open requests may carry a one-time launch specification with
Ghostty's resolved argv, environment, cwd and initial terminal dimensions.
Optional initial input is sent to the new PTY once, then discarded. Launch data
is never stored in session records or replayed on transport reconnect. SSH
requests reject local launch data. `local-launch/1` advertises this support; an
older local host reports a clear error without creating a replacement shell.

Restored workspace panes (`recreate_if_gone: true`) negotiate `recreate-if-gone/1`:
live sessions attach normally and local `EndReason::Lost` sessions with a valid
snapshot still resurrect via `resurrect_launch`, whereas missing/ended/closed or
corrupt-snapshot sessions retire stale artifacts and open a fresh shell in the
saved directory. When talking to an older remote SSH host lacking `recreate-if-gone/1`,
the relay omits the field on the wire and performs a one-time `create=true` fallback
if the host reports the session unknown or ended. Calls with `recreate_if_gone: false`
(such as the Session Library) preserve strict attach/error behavior.

Remote session creation also negotiates `init-size/1` and `remote-env/1` on `P` frames.
When supported on initial creation or `recreate_if_gone` spawn, `OpenRequest` may carry
optional initial PTY/pixel geometry (`cols`, `rows`, `pixel_width`, `pixel_height`) and
client environment/theme hints (`term`, `colorterm`, `term_program`,
`term_program_version`, `color_scheme`, `foreground`, `background`, `cursor`). The relay
strips these fields for legacy hosts or confirmed attach/reconnect retries. Remote hosts
open the PTY directly at the requested initial geometry, configure `libghostty-vt`
identity/theme query replies, preserve `COLORTERM`/`TERM_PROGRAM`/`TERM_PROGRAM_VERSION`
and default `AGY_CLI_OSC7501=on` when unset, and select `TERM=xterm-ghostty` whenever
the provisioned `xterm-ghostty` terminfo resolves cleanly (falling back to
`xterm-256color`). SSH deployment provisions Ghostty's embedded terminfo via `tic -x`
when available and injects `-o Compression=yes`, `-o ServerAliveInterval=15`, and
`-o ServerAliveCountMax=3` while letting explicit user SSH options win.

`list-local SOCKET` sends the read-only L sequence-zero request through an
already running relay. It does not create or attach a session and does not
refresh detached lifetime. Concurrent catalogue requests share one host query.
The bounded JSON array contains only identity, timestamps, PID, end/recovery
state, lifetime policy and optional cwd. It excludes holder capabilities and
launch argv/environment. Older hosts already support L.

Local `T` frames carry connection state JSON and a pane attachment generation in `seq`. Clients
must pause input until a fresh snapshot is restored, acknowledged and followed
by writer confirmation. `I`, `R`, `W` and `K` carry the current generation in `seq`;
snapshot `A` keeps its output offset in `seq` and carries the generation as eight
big-endian bytes. A single-pane retry changes only its generation; a transport
loss retires every affected attachment. Relay startup uses a fresh random seed
so delayed input cannot match a restarted relay. The relay rejects stale frames and never replays disconnected
input. The remote host protocol and snapshot output offsets stay independent.
Session-level errors retain the pane; only an explicit retry reopens that stream.
Confirmed sessions always retry with `create=false` and are never silently recreated,
while an unconfirmed initial `create=true` retains its launch data across transient
pre-open `E`/`Q` failures until snapshot confirmation (`S`) or an inner actor `E`.
Before any session open, heartbeat capability negotiation must confirm
`strict-open/1`. Old runtimes without this guarantee remain running but cannot
be attached by the new supervisor. `durable-close/1` remains independently
negotiated so pending closes do not depend on opening a session.

`serve`, `host`, `host-local`, `session-holder` and `bridge` remain internal
daemon/testing operations. The fixed VPS launcher and per-process experimental
routing variables have been removed.

Output queues and active-session counts are bounded (`MAX_STREAMS = 512` and
`64` host connections; `MAX_PEERS = 512` per relay) with a `64 MiB` per-peer output
queue limit and `256 MiB` buffer budget, plus host-side read backpressure (`1 MiB`
queued-byte high-water for interactive PTY streams and `MAX_QUEUE / 2` for other streams).
Remote actors also batch PTY reads with a bounded `6 ms` DEC 2026 (`?2026h..l`) sync
completion window and apply `512 KiB`/`128 KiB` `POLLIN` backpressure hysteresis when
peers fall behind, while `inline` batches stdout writes, defers `OSC 3008` host metadata
until `!in_sync && continuation.is_empty()`, and skips spurious scrollback
newline emissions on initial attach, alt-screen, active TUI modes, or repeated
reconnects. Slow readers
disconnect when either budget is exhausted; PTY reading and lifetime enforcement
continue. Exceeding `MAX_STREAMS` rejects only the extra open with stream `E`
instead of tearing down the shared host transport. Snapshot format compatibility
hashes only the wire snapshot sources (`src/terminal/snapshot`) while keeping the
full binary `revision` unchanged. Legacy monolithic `remote` daemons are never
restarted while sessions remain active, whereas decoupled `host-local` and
`remote-holder` brokers support compatible `b'T'` stepdown and re-adoption of
surviving `session-holder` processes across upgrades. Host crash, escaped descendants
and cross-core snapshot migration still have the limits documented in
RELEASE_PROGRESS.md.
