# OMG 0.22.2 · Ghostty 1.4.1-dev

OMG 0.22.2 is a macOS & session-runtime release on **Ghostty `1.4.1-dev`** (`7a8ff4d99`) that introduces unified remote single-host session runtime management with graceful cross-snapshot-revision handoff, retains active-tab GPU frames across window/Space occlusion for Mission Control thumbnails (`#85`), adds Phase 1 end-to-end OSC 26 (TAP) Tier 1 agent status protocol support (`#82`), and overhauls the Agent Status Engine and tab status badges.

## Highlights

- **Unified remote single-host session runtime, in-place takeover & graceful cross-snapshot-revision handoff.**
  - **Single-host session-holder & in-place takeover**: Consolidates remote PTY ownership into a single per-host `omgd` session-holder with in-place daemon takeover (flushing takeover ACKs cleanly before shutdown), safe remote GC that probes `sessions/` sockets before pruning, and legacy compatibility on macOS (`88384ee06`..`a0100994b`).
  - **Graceful cross-snapshot-revision session handoff**: Adds coordinated session handoff across `snapshot-revision` upgrades, validating resume before emitting completion markers and canceling in-flight handoffs cleanly on window close.
- **Mission Control active-tab frame retention across window occlusion (`#85`).**
  - Retains the active tab's front GPU presentation frame across window and Space occlusion so macOS Mission Control thumbnails stay populated instead of blanking out, while preserving spare-buffer trimming and background/minimized tab hibernation (`c1a254e25`, `d21258632`).
- **End-to-end OSC 26 (TAP) Tier 1 agent status protocol — Phase 1 (`#82`).**
  - Bridges OSC 26 (`osc_unknown` zero-ABI-diff path) from Zig VT core through `session-runtime` into the macOS Swift host and updates `docs/PLUGIN_DEVELOPMENT.md`, enabling native Tier 1 agent status reporting without ABI breakage (`effb400a4`, `757f3f74f`, `604d8f131`).
- **Agent Status Engine overhaul & visual polish.**
  - **Strict Tier 1 authority & canonical priority lattice**: Enforces strict Tier 1 status authority across Rust (`session-runtime`) and Swift, unifies the priority lattice and `omg_context` subagent/background tracking, unlocks pending attention on `omg_event=attention_resolved`, and drops pruned idle records when a new live signal arrives (`8f43ffd77`, `c4ad32677`, `2986a6214`).
  - **Per-agent adapter updates (`hookVersion` 14)**: Aligns hook/adapter integrations across `antigravity`, `claude`, `codex`, `opencode`, `pi`, `omp`, and `hermes` (`c4ad32677`, `30e137e6a`, `8f983a3b8`).
  - **Tab status badges & tooltips**: Replaces the permission lock icon with distinct orange attention badges (`hand.raised.fill` for permission requests, `questionmark.circle.fill` for questions) and adds background status tooltips (`5d367e680`).

## Version and distribution

- OMG **0.22.2**, bundle version **64** (`CFBundleVersion`).
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.22.1`).
- Includes all OMG changes since the published `v0.22.1` tag (`88384ee06` → `8f983a3b8`).
- macOS release apps and DMGs are **persistently self-signed (`OMG_SIGNING_MODE=self-signed`); not notarized**, using the same pinned release certificate and designated requirement across `OMG.app`, Sparkle helpers, `DockTilePlugin`, and nested `session-runtime` Mach-O binaries.
- **First-launch Gatekeeper & signer trust note**: Because apps and DMGs are not notarized, macOS Gatekeeper may block the first launch. Users who trust the downloaded app can review and allow it once in **System Settings → Privacy & Security**, and optionally install one-click Code Signing trust via **OMG → Settings → Plugins → OMG Doctor → Trust Release Signer for Updates** (or `omg +doctor`) to preserve TCC grants across updates (migrating from older ad-hoc builds may prompt once; never disable Gatekeeper globally). Sparkle updates retain their separate EdDSA signature on the `universal` DMG enclosure (`SUEnableAutomaticChecks` remains `false`).
- Each `arm64`, `x86_64`, and `universal` macOS app bundles `Contents/Resources/session-runtime` containing the universal local `omgd` relay (`omg-session-runtime/2 snapshot/1`), `omg-mobile-support`, `askpass`, `macos-aarch64` / `macos-x86_64` and `linux-x86_64` / `linux-aarch64` (`libghostty-vt.so.1`) remote session runtime artifacts, post-sign SHA-256 `manifest.json` files, `revision` (`7a07794199e8ef12ad94`), and `snapshot-revision` (`7abe5365444c63ee8df6`). Existing remote `omgd` daemons owning live PTYs are never overwritten in place; older hosts without `durable-close/1` retain pending-close compatibility limits.
- iOS physical device installation requires signing with the user's own Apple ID (a free Personal Team Apple ID works via `OMG-Mobile-0.22.2-ios-installer.tar.gz`, or via SideStore / AltStore / Sideloadly using `OMG-Mobile-0.22.2-ios-unsigned.ipa` and `altstore-source.json`).

## Validation

- **Static, `session-runtime`, Swift & iOS mobile gates**:
  - Passed parallel static/contract checks (`swiftlint --strict`, `zig fmt --check`, `docs/settings/schema.json`, `check_omg_docs.py`, `plutil`, `ibtool`, and `dist/test_omg_*.py` signing, keychain, test-plan, mobile-plan, and release contracts).
  - Passed `session-runtime` gates (`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test -- --test-threads=1` — 137 tests, `cargo build`, and `session-runtime/tests` Python discovery; environment-dependent SSH and Linux containment tests skipped).
  - Passed all 12 routine app-hosted `GhosttyTests` modules (`200` suites in the retained Tart VM); `GhosttyTests/EditorWorkspaceLifetimeTests` failed during the broad run and passed on isolated `--skip-build` retry.
  - Passed iOS `mobile` test gates (`native-core`, `simulator-build`, `vm-simulator-ui`, selected by changes in `session-runtime/src/lib.rs` and `session-runtime/src/registry.rs`), recorded by `dist/macos/omg_release.py` (see `.release-build/0.22.2/release-summary.md`).
- **Architecture, signing & Rosetta 2 status**:
  - `arm64` and `universal` `OMG.app` bundles and mounted DMGs: verified `codesign --verify --deep --strict`, persistent self-signed designated requirement (`omg_signing.py verify`) with mutual DR continuity against `0.22.1`, post-sign `session-runtime` manifest SHA-256 & universal `omgd version` (`omg-session-runtime/2 snapshot/1`) probe, and native `omg --version` (`build mode : .fast`, i.e., `ReleaseFast` under Zig `0.17.1`) launch probes on Apple Silicon (`arm64`).
  - `x86_64` `OMG.app` bundle and mounted DMG: verified `x86_64` Mach-O slice (`lipo -archs`), `codesign --verify --deep --strict`, persistent self-signed DR continuity, post-sign `session-runtime` manifest SHA-256, and `_ghostty_info` `ReleaseFast` (`.fast`) verification (`x86_64` executable launch probe **NOT RUN** on the `arm64` build host because Rosetta 2 is not installed).
  - Sparkle `appcast.xml` EdDSA signature (`sparkle:version = 64`), `altstore-source.json`, and `SHA256SUMS.txt` verified across all release assets.
- **Not run**:
  - Optional `.interactiveDesktop` native drag/focus suites: **NOT RUN** (excluded by default; requires an unlocked foreground desktop session).
  - Full desktop TCC / Folders / Accessibility / Sparkle upgrade permission experiments: **NOT RUN**.
  - `x86_64` binary launch execution under Rosetta 2: **NOT RUN** (Rosetta 2 not installed on build host; static `x86_64` Mach-O slice, code signature, and `_ghostty_info` `ReleaseFast` mode verified).
  - XCUITest, host desktop frame-rate / multi-display / input-to-photon latency measurements, and live remote SSH / disposable Linux `systemd`/cgroup v2 fault-injection (`test_containment_linux.py`) / external live Agent conversation recovery gates: **NOT RUN**.
