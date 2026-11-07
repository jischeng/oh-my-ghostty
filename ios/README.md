# OMG Mobile

iPhone/iPad client for existing `omgd` local sessions. Implements the first LAN
slice of [#37](https://github.com/jischeng/oh-my-ghostty/issues/37).

The initial implementation adapts Termio's UIKit terminal, Metal/CoreText
renderer, IME, key repeat and WebSocket reconnection code at revision
`819658751635eb298a467f4d84e793729c5242bc`. See
[Vendor/Termio/UPSTREAM.md](Vendor/Termio/UPSTREAM.md) and the bundled MIT license.
The app also bundles the repository's Ghostty MIT license.
Remux remains the second design reference; no Remux code is included.
The VT parser, snapshots, keyboard/mouse encoding and selections come from
OMG's own matching Ghostty core. There is no second terminal parser.

## Build

Requirements: full Xcode with iOS SDK, Zig 0.16.0 through mise, XcodeGen,
Rust/Cargo. No Xcode GUI is needed.

```sh
ios/scripts/build.sh iphonesimulator
ios/scripts/build.sh iphoneos
```

The first command builds for Apple Silicon Simulator; it does not install a
Simulator runtime. Simulator builds use Xcode's local ad-hoc signing and
simulated application identifier so Keychain works without a device profile.
Device builds are unsigned unless
`OMG_IOS_DEVELOPMENT_TEAM` names an existing Apple Development team.
Signing/provisioning and a connected device are needed for a physical install.

Generated projects, copied VT headers, libraries and app bundles stay in
ignored paths. The matching VT library is built from this checkout; do not
replace it with an unrelated prebuilt Ghostty framework.

## Connect over the LAN

1. Build the Mac runtime:

   ```sh
   ios/scripts/build-vt.sh macos
   cargo build --manifest-path session-runtime/Cargo.toml
   ```

2. Keep the Mac awake on the same Wi-Fi as the phone and run:

   ```sh
   ios/scripts/serve-lan.sh
   ```

   This discovers existing **OMG Dev local** runtime namespaces. For another
   channel, explicitly set `OMG_MOBILE_APP_SUPPORT`. Set
   `OMG_MOBILE_LISTEN=192.168.1.10:8791` to choose a LAN interface. The gateway
   stays independent of the Mac GUI; stopping it disables mobile access.

3. The gateway prints its address and the pairing-token file location. Read
   that private file locally. Enter the Mac address (for example
   `192.168.1.10:8791`) and token in OMG Mobile. Allow the iOS local-network
   permission and Mac firewall access when requested.

4. Select an existing session. Opening observes without claiming input or
   resizing the PTY. Tap **接管** to acquire input and fit the PTY to the
   phone's viewport. Mac clients with the matching implementation can reclaim
   on focus or typing; both remain attached and receive output.

Older pinned runtime processes remain untouched. They can be viewed, but do
not advertise `writer_transfer` and cannot transfer an occupied writer.
Create a session using the newly built runtime to validate transfer.
The first slice exposes local runtimes only; saved SSH credentials and endpoint
configuration are never sent to the phone.

For an isolated runtime or a server without an app catalogue:

```sh
session-runtime/target/debug/omgd mobile \
  --listen 192.168.1.10:8791 \
  --socket /private/path/to/runtime/host.sock \
  --token-file /private/path/to/mobile.token
```

The token file is generated with mode 0600 and retained across gateway restarts.
Token changes take effect after restarting the gateway, which also disconnects
existing mobile transports. Public exposure/TLS/tunnels are a later validation
stage; this listener accepts explicit loopback or private IPv4 addresses only.

## State and input contracts

- The phone attaches by UUID **and generation**, never creates a replacement.
- The authoritative native snapshot is decoded before its watermark is ACKed.
  Output byte offsets must stay contiguous; corruption or a gap stops the
  attachment rather than applying bytes to an uncertain screen.
- Session queries are answered by the runtime. Automatic phone terminal
  reports do not become user keystrokes.
- Input is accepted only after a writer grant. Offline input is discarded.
- Closing the phone view or losing the network detaches; it never closes the
  underlying shell. There is no mobile End Session control in this first slice.
- All viewers follow the PTY's one ordered grid. An observer does not resize;
  the phone writer coalesces identical viewport reports.

Kitty image rendering, voice, uploads, agent notifications, QR/Bonjour discovery
and public networking are not enabled in this slice. The text/TUI path,
Chinese IME, terminal keyboard, paste and reconnection are the initial scope.

## Checks

Mobile checks are selected independently from macOS releases and routine suites.
Use the previous published tag for a release or the branch integration base for
development. The comparison includes committed, staged, unstaged and untracked
changes, including deletions and both sides of renames:

```sh
python3 dist/omg_mobile_test_plan.py --changed-since <base-ref>
ios/scripts/test.sh --changed-since <base-ref>
ios/scripts/test-vm.sh --changed-since <base-ref>
```

With no mobile implementation/shared dependency changes, the gated commands
print the skip reason and exit before starting builds, VM or Simulator.
macOS-only features, version bumps and documentation do not select mobile
checks. Explicit commands without `--changed-since` remain available when a
mobile validation is intentionally requested.

```sh
ios/scripts/test.sh
cargo test --manifest-path session-runtime/Cargo.toml
mise exec zig@0.16.0 -- zig build test \
  -Dversion-string=1.3.2-dev -Dtest-filter='session'
```

Swift package tests check fragmented transport frames, output gaps, real native
snapshot/parser-continuation/alternate-screen restoration, and Ghostty's key and
bracketed-paste encoding. Rust tests use real PTYs and authenticated WebSockets,
including reconnect to the same session and transfer between live observers.
These checks do not replace unlocked Simulator/device interaction acceptance.

## VM + Simulator acceptance

```sh
# Build this checkout, deploy only to Tart, and run the iOS UI in Simulator.
bash ios/scripts/test-vm.sh

# Reuse matching, already built and packaged artifacts.
bash ios/scripts/test-vm.sh --skip-build --simulator <SIMULATOR_UUID>
```

The runner uses the existing headless `omg-test` VM and a local iOS Simulator.
It never deploys or launches the Mac app on the host. The host needs full Xcode,
an installed iOS Simulator runtime and the prerequisites in
[macos/VM_TESTING.md](../macos/VM_TESTING.md). The guest needs Python 3.

The default build is serial: native GhosttyKit, Mac app, native runtime bundle,
then iOS app. The test creates a fresh terminal through the actual guest GUI,
discovers its UUID/PID in the runtime catalogue, and starts an authenticated
gateway on the guest's private IP, port 18790. The test-only token is synthetic;
it never reads a user's pairing token. The observer fixture does not claim input.
Before launch it resets only the disposable **guest Dev** preferences, support
directory and saved-window state, so ended sessions from older runtime epochs
cannot become the test's terminal. No host profile is reset.
The Simulator takes over and executes a marker command; the **Mac GUI** then
types a second command to reclaim input through `SessionBackend`. The Simulator
terminates/relaunches the mobile app, opens the same session and executes again.
The guest requires matching UUID, generation and shell PID for all receipts.
Native launches may retain `/usr/bin/login` as the runtime's PTY-root PID; the
fixture identifies its shell descendant and checks both PIDs remain unchanged.

Evidence defaults to `/tmp/omg-mobile-vm-evidence-<run-id>/`: `ready.json`,
`result.json`, guest screenshot, Simulator xcresult/screenshots and logs.
Set `OMG_MOBILE_TEST_EVIDENCE` to choose another output directory. Cleanup closes
only the fixture's new session, stops its gateway, and shuts down the VM while
keeping its disk. `--skip-build` requires matching source-built Mac app/runtime
and iOS VT libraries; it is not an acceptance of an old installed app.

Validated on 2026-11-07 with freshly built Mac/Simulator apps and runtime
`d321f98a140a04e566cb`: one real VM + Simulator XCUITest passed, including mobile
input, Mac GUI reclaim and mobile relaunch/reattach. The guest execution receipts
confirmed the same UUID, generation, PTY-root PID and interactive shell PID.
The two client screenshots were inspected, and the VM shut down cleanly.

## LAN UI acceptance

After building the Simulator app, start an isolated fixture in a separate shell:

```sh
python3 ios/scripts/ui-fixture.py \
  --directory /tmp/omg-mobile-ui-fixture \
  --listen 192.168.1.10:18790
```

Replace the example LAN IP with this Mac's address; the directory must not
already exist. The fixture owns one disposable session and uses a synthetic
test-only pairing token. Run `OMGMobileUITests` against a booted Simulator:

```sh
xcodebuild -project ios/OMGMobile.xcodeproj -scheme OMGMobile \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath ios/.build/app \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  OMG_MOBILE_UI_SERVER=192.168.1.10:18790 test
```

The test pairs through the normal connection screen, opens the existing
session, takes input, executes an octal-encoded `printf`, and observes the
desktop Unix client taking back input and restoring a 120x50 grid. Echo alone
cannot satisfy the execution receipt. A screenshot pixel check additionally
requires visible terminal text after the shared grid grows beyond the phone.
Stop the fixture with Ctrl-C; it explicitly closes only its own session before
stopping its private host and gateway.

Validated on 2026-11-05:

- Simulator connected through the Mac's LAN address; both client commands
  executed in the same session UUID/PID, and the larger desktop grid stayed
  visible on the phone. The native keyboard bar and Chinese output were
  visually inspected.
- macOS regression: 1406 tests in 176 routine suites passed with packaged
  runtime resources. Optional macOS desktop interaction tests were not run.
- Native mobile core: 7 XCTest tests passed. Runtime: 55 Rust tests and
  31 Python tests (2 external Linux-systemd/SSH tests skipped); previous
  packaged runtime compatibility passed.
- arm64 iPhoneOS app compiled. macOS arm64 and Linux x86_64/aarch64 runtime
  artifacts built and passed bundle verification. Linux artifacts were not
  executed on a Linux host.
- Physical-device installation was not performed: no existing provisioning
  profile matched the new mobile bundle ID and connected device.

The app icon is reused unchanged from the fork's macOS OMG icon.
