# Host runtime

Each versioned host daemon owns multiple session threads, PTYs and children. Each
pane has a persistent UUID; its saved descriptor identifies its SSH connection and
runtime revision. The App owns one multiplexed relay per connection/revision.

The local H handshake carries an explicit open request. The outer protocol routes
open/data/detach/error frames by stream ID. Remote output, resize, snapshot ACK,
writer arbitration and exit remain per Session. The M metadata frame supplies the
remote foreground/shell cwd on attach and changes; the GUI uses that path with its
saved SSH identity for sidebar presentation.

Only `connect LOCAL_SOCKET CONNECTION_JSON` is a supported client transport.
`serve`, `host` and `bridge` remain internal daemon/testing operations. The fixed
VPS launcher and per-process experimental routing variables have been removed.

Output queues and active-session counts are bounded. Slow readers disconnect;
PTY reading and lifetime enforcement continue. Runtime revision upgrades never
restart a daemon with active sessions. Host crash, escaped descendants and
cross-core snapshot migration still have the limits documented in
RELEASE_PROGRESS.md.
