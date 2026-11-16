# OMG 0.21.3 · Ghostty 1.3.2-dev

OMG 0.21.3 is a Git Inspector, SSH transport, and History UX patch release on top of `v0.21.2`. It multiplexes SSH Git and Inspector commands over live `omgd` relays with automatic OpenSSH fallback and retry/backoff resilience, fixes disabled refresh actions on Git error states, speeds up Git history scope switching via in-memory snapshot reuse, and includes favorited non-bare worktrees in the Favorites scope.

## Highlights

- **Multiplexed SSH Git / Inspector execution over `omgd` relays & OpenSSH hardening.** Adds `exec/1` protocol support (`omgd exec-local`) in `session-runtime` and routes `SSHSessionTransport` commands over active `omgd` relay tunnels registered in `SessionRuntimeConnections`, falling back transparently to OpenSSH `ControlMaster` when the relay is absent or a remote host lacks `exec/1` (`\x1eOMG-EXEC-UNSUPPORTED\x1f`, exit `253`). Extends private Git `ControlPersist` idle lifetime to `3600s` (1 hour), serializes cold SSH/SFTP handshakes per destination (`coldHandshakeLimiter`, concurrency `1`) while sharing warm masters up to `4` concurrent channels, checks (`-O check`) and evicts broken control sockets on exit `255`, and retries explicitly allowlisted idempotent read-only Git commands (`SSHGitExecutor.isIdempotentReadOnly`) and working-file reads once after `150ms` on transport failures without retrying mutations.
- **Git Inspector error refresh, jump-host poll backoff & stale-while-revalidate.** Keeps the Inspector toolbar refresh button enabled (`git.fetch` -> `.refresh`) whenever `repository == nil` and not actively loading, adds a prominent enabled **Retry** (`git.retry`) button on error views, retains previously loaded repository snapshots across transient background poll failures (stale-while-revalidate), applies exponential backoff (`15s`, `30s`, `60s`, `120s`, capped at `300s`) on consecutive `.sshReady` poll failures, and pauses automatic polling after 3 consecutive initial failures (`repository == nil`) until a manual refresh or directory/session change.
- **Fast Git history scope switching & favorited worktrees.** Reuses the existing in-memory `GitHistorySnapshot` (`reuseSnapshot: true`, preserving repository `HEAD`, decorations, and precomputed `sortedTags`) when switching between Current / Favorites / All (`当前 / 收藏 / 全部`) scopes or browsing branches, tags, and worktrees so only a single `git log` page query runs instead of rescanning refs and rebuilding collection trees, and includes favorited non-bare worktrees (`worktree:<path>`) in the Favorites commit graph.

## Version and distribution

- OMG **0.21.3**, bundle version **58**.
- Ghostty **1.3.2-dev**, revision `9ae02a326f62bd88f7f5508cf1807c67e7775cb5` (unchanged from `v0.21.2`).
- Includes the changes since the published `v0.21.2` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  `omgd` relay, mobile support helper, and macOS (`arm64`, `x86_64`) and Linux
  (`x86_64`, `aarch64`) remote session runtime artifacts.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.21.3-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.21.3-ios-unsigned.ipa`).

## Validation

- Routine change-selected static checks, Rust `session-runtime` fmt/clippy/tests
  and Python discovery suite, app-hosted `GhosttyTests` (retained Tart VM),
  and post-sign packaged artifact / DR continuity / manifest hash / Sparkle
  EdDSA appcast checks recorded by `dist/macos/omg_release.py` (see
  `.release-build/0.21.3/release-summary.md`).
- **Not run**: iOS `mobile_gate` (not selected; no mobile implementation or
  shared VT dependency changed since `v0.21.2`), optional `.interactiveDesktop`
  native drag/focus suites, XCUITest, host desktop FPS/latency measurements,
  full desktop TCC upgrade experiments, live remote SSH / disposable Linux
  systemd-cgroup fault-injection acceptance (`test_containment_linux.py`), and
  `x86_64` launch execution (Rosetta 2 is absent on the arm64 build host;
  `x86_64` Mach-O slice, code signature, and `.ReleaseFast` marker verified).
