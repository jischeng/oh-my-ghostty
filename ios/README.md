# OMG Mobile

An iPhone/iPad client for the same local sessions managed by `omgd`, implementing
[#37](https://github.com/jischeng/oh-my-ghostty/issues/37). The app reuses Termio's
complete UIKit application and shared UI at revision
`819658751635eb298a467f4d84e793729c5242bc`, including projects, Chats, Terminals,
Needs You, terminal drawers, Files, Diff and Settings. OMG supplies the backend
adapter rather than maintaining a second mobile UI.

See [Vendor/Termio/UPSTREAM.md](Vendor/Termio/UPSTREAM.md) for source locations,
local adaptations, dependency pins and licenses. Remux, Orca and Paseo remain
references; their code is not included. The active shared terminal uses OMG's
matching Ghostty VT core, snapshots, key encoding and selections.

## Build

Requirements: full Xcode with iOS SDK, Zig 0.16.0 through mise, XcodeGen and
Rust/Cargo. No Xcode GUI is needed.

```sh
ios/scripts/build.sh iphonesimulator
ios/scripts/build.sh iphoneos
```

The first command builds for Apple Silicon Simulator. Simulator builds use local
ad-hoc signing so Keychain works without a device profile. Device builds are
unsigned unless `OMG_IOS_DEVELOPMENT_TEAM` names an existing development team;
physical installation requires matching provisioning. Generated projects,
headers, libraries and build products remain ignored. The minimum OS is iOS 17.

## LAN pairing

Build the runtime and start its separate gateway on the Mac:

```sh
ios/scripts/build-vt.sh macos
cargo build --manifest-path session-runtime/Cargo.toml
ios/scripts/serve-lan.sh
```

The script discovers existing **OMG Dev local** runtime namespaces. Select a
channel with `OMG_MOBILE_APP_SUPPORT`, a binary with `OMG_MOBILE_RUNTIME`, or an
interface with `OMG_MOBILE_LISTEN=192.168.1.10:8791`. Keep the Mac awake and allow
local-network/firewall access. The gateway stays independent of the Mac GUI;
stopping it disables mobile access without closing the underlying sessions.

In another shell, print a private pairing link using the same configuration:

```sh
ios/scripts/serve-lan.sh --print-invite
```

Paste the `omg://device?...` link into the original app's device pairing flow or
open it on the phone. It contains a bearer token: keep it private. The app checks
the authenticated roster before saving; the token goes to Keychain rather than
UserDefaults. `--print-invite` creates/reuses the token without starting a second
listener. The token file is mode 0600; token changes require restarting the
gateway, which disconnects its mobile transports.

For an explicit runtime without a Mac catalogue:

```sh
session-runtime/target/debug/omgd mobile \
  --listen 192.168.1.10:8791 \
  --socket /private/path/to/runtime/host.sock \
  --token-file /private/path/to/mobile.token
```

Only explicit loopback/private IPv4 listeners are accepted. Public TLS/tunnels
remain a later validation stage. Saved provider credentials and SSH secrets are
not sent to the phone.

## Existing sessions and agents

The original Termio UI receives its wire-v2 roster from `/control`. Projects
include live working directories and Mac workspace checkpoint names. Codex,
Claude Code, Pi and Antigravity appear with upstream icons, agent session rows,
activity summaries and Needs You grouping. State comes from retained host
hook/OSC activity, with a lightweight read-only holder mirror; listing sessions
does not open a terminal viewer or claim input. Older runtimes without that
capability show unavailable activity rather than inferred completion.

Opening a terminal observes. Typing implicitly requests writer transfer and
waits for its grant; the Mac can reclaim while both clients keep receiving
output. UUID **and generation** bind every attachment and close operation.
Offline/obsolete input is discarded. Native snapshot watermarks and ordered
output remain authoritative, and automatic phone terminal reports never become
user keystrokes. All viewers share one PTY grid; only the writer resizes it.
Leaving a terminal detaches; the explicit session-row Close action ends it.

The original flows can create terminals/allowlisted agent sessions, browse and
edit project files, upload files, inspect git diffs and start an ordinary local
`ssh` terminal for a configured alias. File operations are bounded and confined
to canonical project roots. Writes use mtime conflict detection and the original
Reload/Overwrite flow. New sessions follow the existing runtime launch policy.
An idle broker can restart its **cached** binary; the gateway never upgrades
running daemons or replaces binaries. App naming alone does not isolate channels.

Agent status is presentation of existing host reports, not a native chat or
structured approval API. Hooks still run on the host. Phone permissions never
infer a reply by parsing terminal text. The earlier custom activity-card UI has
been removed; see the [design record](../docs/plans/ios-agent-experience-2026-11-07.md).

Current limits: markdown reads show source, SSH alias parsing handles basic Host
blocks rather than full Include resolution, and terminal query answers remain
host-owned even when the phone changes its local display theme. Kitty image
rendering, push notifications and public networking are not enabled. Upstream
voice UI is retained, but microphone/provider/network behavior requires separate
device acceptance. Provider credentials and real inference turns are not part
of the synthetic agent-status test.

## Change-selected checks

Mobile checks are independent of routine macOS releases. Compare to the previous
published tag for release work or the integration base for development:

```sh
python3 dist/omg_mobile_test_plan.py --changed-since <base-ref>
ios/scripts/test.sh --changed-since <base-ref>
ios/scripts/test-vm.sh --changed-since <base-ref>
```

The selector includes committed, staged, unstaged and untracked changes,
deletions and both rename paths. Unrelated Mac features, version changes and
documentation exit before mobile tools, VM or Simulator start. Explicit commands
without a reference intentionally run mobile checks:

```sh
ios/scripts/test.sh
cargo test --manifest-path session-runtime/Cargo.toml
```

Native tests cover fragmented transport, watermark gaps, route/generation
validation, real snapshot/parser/alternate-screen restoration and key/paste
encoding. Rust integration uses real PTYs and authenticated WebSockets for
reconnect, shared writers, roster activity, file editing/diff, terminal creation
and stale-generation rejection.

## VM + Simulator acceptance

```sh
bash ios/scripts/test-vm.sh
bash ios/scripts/test-vm.sh --skip-build --simulator <SIMULATOR_UUID>
```

Use the existing retained **`omg-test`** VM for this mainline work; no separate
mobile clone is needed. The Mac app runs only in the guest, and iOS runs in the
host Simulator. The guest needs Python 3. Prerequisites are documented in
[macos/VM_TESTING.md](../macos/VM_TESTING.md).

Builds run serially: native GhosttyKit, Mac app, runtime bundle, then iOS. The
runner resets only the disposable guest Dev profile, creates a terminal through
the actual Mac GUI and starts an authenticated gateway on guest port 18790.
The observer fixture never claims input. Test-only credentials are synthetic.
No host app or host profile is installed, stopped or reset.

The full-app UI suite covers project/session navigation, live synthetic Codex /
Claude / Pi / Antigravity status, Needs You, parked terminal reopen, mobile input,
Mac GUI reclaim, app relaunch/reattach, terminal drawing, original drawer Files /
Diff and README editing, native tabs/settings, and creation/explicit closure of
a terminal. Guest receipts require the original UUID, generation, PTY-root PID
and shell PID to remain unchanged. Synthetic OSC reports verify presentation;
real-provider authentication, inference and hook coverage remain separate.

Evidence defaults to `/tmp/omg-mobile-vm-evidence-<run-id>/`: ready/result JSON,
Simulator xcresult and logs, plus guest captures. Set `OMG_MOBILE_TEST_EVIDENCE`
to override. Cleanup closes only fixture-owned sessions, stops its gateway and
shuts the VM down while preserving its disk. `--skip-build` requires matching
source-built Mac app/runtime and iOS VT libraries.

Validated on 2026-11-07: all three full-app UI tests passed against guest runtime
`16648856c40342129196`; the guest receipts confirmed every operation and the
unchanged original session/PIDs. Home/Needs You, terminal, drawer, Diff, editor
and Settings screenshots were exported for inspection. Evidence:
`/tmp/omg-mobile-vm-evidence-2827fc8bcccd499facdc9b074a0a5465/`.
The VM shut down normally.

Regression checks passed: 69 Rust tests, 10 native Swift tests, 50 test-selector
tests and documentation checks. Python ran 35 tests with four prerequisites
initially skipped; the legacy-runtime and bidirectional VT snapshot checks were
then run successfully against the installed previous Dev artifacts. Only the
external Linux-systemd and explicit SSH-deployment checks remain skipped.
The full app compiled for both arm64 Simulator and unsigned arm64 iPhoneOS.
The OMG-owned Swift adapters passed strict SwiftLint.

Physical iPhone installation has not been performed: a matching provisioning
profile is required. The app icon is reused from OMG's macOS icon.
