# OMG test selection

Use `macos/build.nu` for app-hosted Swift tests. `macos/build.nu --action test`
compiles on the host (`build-for-testing`) and runs `GhosttyTests` inside the
retained headless Tart VM (`macos/scripts/vm/omg-vm xctest`) so test windows
never take over the host desktop. Test selection is based on changed modules
and their direct dependents, **not the release's SemVer category**. A minor
release does not automatically require every unrelated feature suite.

## Three layers

1. **Routine module regression**: unit/policy and app-hosted integration suites;
   includes the version smoke suite. App-hosted does not mean a real foreground
   desktop is required: window fixtures and synthetic event-policy tests remain
   routine tests.
2. **Broad routine regression**: all routine Swift suites for shared host/core,
   build/test infrastructure, unmapped changes, or an explicitly requested sweep.
3. **Optional interactive desktop**: suites or individual tests tagged
   `.interactiveDesktop`: `VerticalTabMouseTests`, `VerticalTabFullscreenTests`
   (native fullscreen tab creation, framebuffer/sidebar handoff, and exit), `QuickInputFooterMouseTests`
   (icon-only History and its complete padded mouse hit target), and the visual
   `VerticalTabsIntegrationTests.appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces`,
   `TerminalLinkHoverTests.commandHoverRemainsStable` (Cmd-link hover in single/split panes),
   and `TerminalWorkspacePresentationTests.clickingWorkspaceButtonOpensItsNativePopover`
   (actual mouseDown/mouseUp opening the transient workspace popover), plus
   `TerminalWorkspaceManagementDesktopTests` (creation through the popover's
   form in native and non-native fullscreen), the 60-tab
   `TerminalWorkspacePopoverSwitchTests.nativeFullscreenMouseSelectionClosesAndSwitchesWithoutAnotherKey`,
   `TerminalApplicationTerminationTests.confirmedTerminationKeepsSelectedTabDuringRealSixtyTabFullscreenTeardown`
   (background tabs close without promoting fullscreen successors),
   and the borderless focus/membership methods
   `TerminalWorkspaceManagementTests.nativeTabObservationSurvivesRepeatedBorderlessStyleChanges`
   and `TerminalWorkspaceManagementTests.nonNativeFullscreenSupportsWorkspaceCreationAndReturn`,
   plus `NativeSettingsTests.foregroundSettingsNavigationReceivesNativeMouseClicks`
   (native settings navigation in light/dark foreground windows).
   Real CoreDrag, menu focus routing, native window appearance, and screenshots
   need an unlocked desktop and foreground test application. Lockscreen,
   background, and unattended runs cannot establish that behavior. Other methods
   in a mixed suite remain routine tests.

The test plan provides `OMG_TESTING=1` before the application starts. Workspace
singletons use this launch marker to avoid user catalog/checkpoint reads or writes
before XCTest classes have loaded. Persistence fixtures explicitly use temporary
paths; test-like names in a user's catalog are not automatically deleted.

Synthetic key-window hover fixtures use a fixture-owned notification center in
`NativeTableHover`, so real focus changes from other test windows cannot clear
a simulated pointer. Production defaults to the system notification center;
real pointer routing remains covered by the interactive desktop tier.

Synthetic native fullscreen and close notifications must use a fixture-owned
`NotificationCenter`, injected into `TerminalWorkspaceNativeAdapter`. Posting
these system notifications through `.default` also reaches AppKit observers:
clearing OMG's transition dictionary or closing the fixture window does not
guarantee that the host application's event state has recovered. Real native
fullscreen desktop tests continue to use `.default` and actual window actions.
Wait for asynchronous completion with a bounded condition rather than assuming
that a fixed sleep establishes success. The routine modal mouse-event regression
also exercises the formerly failing workspace-transition-then-alert order within
one test; it is not excluded as an interactive desktop test.
`AppKitTestWait.swift` is a shared test helper, so changes to it select the broad
routine sweep rather than only the foundation suites.

The wrapper excludes interactive-desktop suites by default and prints **NOT RUN**
when the chosen scope contains one. This is not a pass or a silently swallowed
failure. Pure drag-policy/lifecycle and tab integration tests still run normally.
When changing native tabs, drag/drop, focus, or event routing, schedule the desktop
regression explicitly while the desktop is available. If deferred, record that
coverage gap and its reason; unrelated releases must not be blocked by it.

XCUITest (`GhosttyUITests`) is separate and remains excluded by this CLI wrapper
because it requires a permissions-enabled workflow. `--include-desktop-tests`
does not enable XCUITest. Raw `xcodebuild` does not implement this wrapper's
selection policy; a Swift Testing tag alone does not disable a suite.

## Commands

```bash
# List modules and their direct dependents; does not build or launch apps
macos/build.nu --list-test-modules

# Select modules explicitly (including their direct dependents)
macos/build.nu --action test --test-modules git,editor

# Preview changes since a commit/tag, including the current worktree
macos/build.nu --action test --changed-since v0.15.3 --test-plan-only

# Execute that Swift selection, using the previous published tag for releases
macos/build.nu --action test --changed-since v0.15.3

# Keep the existing one-suite/method interface
macos/build.nu --action test --only-testing GhosttyTests/SSHHostRegistryTests

# Broad routine sweep; neither native desktop interaction nor XCUITest
macos/build.nu --action test --test-modules all
# Backward-compatible equivalent: macos/build.nu --action test

# Optional real native drag regression; keep desktop unlocked/test window foreground
macos/build.nu --action test \
  --only-testing GhosttyTests/VerticalTabMouseTests --include-desktop-tests

# Optional Cmd-link hover regression (single pane and split panes)
macos/build.nu --action test \
  --only-testing 'GhosttyTests/TerminalLinkHoverTests/commandHoverRemainsStable()' \
  --include-desktop-tests

# Optional visual test; Swift Testing method selectors include parentheses
macos/build.nu --action test \
  --only-testing 'GhosttyTests/VerticalTabsIntegrationTests/appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces()' \
  --include-desktop-tests
```

Test actions set `ENABLE_TESTABILITY=YES` and `ONLY_ACTIVE_ARCH=YES`, including
`--configuration Release`, so optimized app-hosted tests can use `@testable`
imports and a native-only GhosttyKit build. Normal build/archive actions retain
the configuration's original settings. Pointer-posting desktop tests additionally
require macOS event-posting permission; a failed permission prerequisite is not a
hover-latency result.

Use exactly one of `--test-modules`, `--changed-since`, and `--only-testing`.
`--test-plan-only` emits JSON without invoking Xcode. Invalid modules, unknown
suites, conflicting scopes, and invalid Git refs fail before a build. An explicit
desktop suite/method without `--include-desktop-tests` also fails with guidance,
instead of producing a misleading zero-test success. If desktop opt-in is enabled
but focus cannot be established, the test fails early with its prerequisite error;
its real-drag assertions have not been weakened.

## Module map

The single executable source of truth is `MODULES` in `dist/omg_test_plan.py`.
Suite ownership can overlap intentionally (for example SSH Git execution).
Dependents are one hop from every changed/requested module, not a recursive graph
expansion. Shared interfaces use the broad fallback instead.

| Module | Main test areas | Direct dependents |
| --- | --- | --- |
| `foundation` | Root, Helpers, Ghostty app adapters | — |
| `terminal` | Terminal history/restoration, Splits | tabs, inspector, agents, editor |
| `tabs` | Vertical tabs, drag policy, tab selection restoration | terminal |
| `git` | Git services and UI models | editor, inspector |
| `editor` | Editor and Markdown models/integration | git, terminal |
| `inspector` | Inspector registry, decks, history, providers | git, agents |
| `settings` | Settings and settings schema | foundation, terminal, tabs, editor, git, inspector |
| `plugins` | Plugin host/protocol | agents, ssh, inspector, tabs |
| `agents` | Agent integration/status/history | inspector, quick-input, tabs, terminal |
| `ssh` | SSH configuration, workspace, remote Git execution | agents, terminal, git, tabs |
| `quick-input` | Agent Quick Input | agents |
| `control` | Local control socket, `omg +edit` / `+view` | editor |
| `update` | Updater, release notes, version metadata | — |

Selection safety:

- Git comparison includes committed changes since the exact supplied ref **and**
  staged, unstaged, and non-ignored untracked files. Both sides of a rename and
  deleted paths count. Paths are NUL-delimited; no shell evaluation is used.
- Nested source namespaces use the most specific mapping (Tabs before Terminal).
- Shared Zig/C core, App/Ghostty host adapters, central TerminalController,
  Xcode/build/test infrastructure, and any unmapped code fall back to all routine
  Swift suites. This is conservative rather than pretending a precise dependency
  graph exists.
- A project-file diff containing only balanced changes to `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` selects update/version coverage instead of forcing a
  broad sweep. Any structural project-file edit still falls back broadly.
- Documentation/skill-support and no-change selections do not invoke Xcode; the
  plan explicitly says no Swift tests ran. Settings schema and mapped editor
  resources are not treated as irrelevant documentation.
- Suite names are discovered from `Tests`/`Suite` type declarations in Swift test
  files. Add new areas and dependency edges to the map alongside feature changes.
  Unmapped test files or undiscoverable test types are errors, not silently omitted
  coverage. Keep each desktop-tagged test type in its own file. Method-level tags
  exclude only that method, not the remaining routine tests in its suite.

## Non-Swift and release gates

### iOS client selection

The iOS app is a separate product and is not part of the routine macOS sweep.
Neither a macOS release nor `--test-modules all` starts an iOS build, Simulator
or VM mobile acceptance. For releases, compare against the previous published
tag; for development, compare against the integration base:

```bash
python3 dist/omg_mobile_test_plan.py --changed-since <base-ref>
ios/scripts/test.sh --changed-since <base-ref>
ios/scripts/test-vm.sh --changed-since <base-ref>
```

`dist/omg_mobile_test_plan.py` is the executable source of truth. If there are no
mobile implementation or shared dependency changes, both gated runners exit
before invoking mobile build tools or starting the VM/Simulator. Documentation,
macOS UI features and macOS version bumps alone do not select mobile tests.
iOS-only changes also do not force a broad macOS Swift sweep; run their separate
mobile checks instead.

| Changed area | Mobile checks |
| --- | --- |
| `ios/` implementation, assets, build or UI-test scripts, `session-runtime` mobile companion/gateway (`mobile.rs`, `mobile/**`, `mobile-support/**`), or shared desktop/runtime schemas (`Workspaces/**`, `SSHHostRegistry.swift`, `WorkspaceProvider.swift`, `session-runtime/src/{lib,registry,record}.rs`) | Native core, Simulator build, VM + Simulator acceptance |
| Shared `libghostty-vt` (`include/ghostty/vt*`, `src/lib_vt.zig`, `src/terminal/**`, `src/simd/**`, `src/unicode/**`, VT input encoders) or snapshot wire compatibility | Native core (`ios/scripts/test.sh`) only; no Simulator or VM mobile UI |
| Desktop `SessionBackend`, non-mobile `session-runtime`, macOS UI features, release metadata, documentation | No mobile build, Simulator launch or mobile acceptance |

Native mobile checks run locally without GUI. The integration runner uses the
actual OMG Dev GUI inside Tart and the iOS app in Simulator: mobile takeover,
Mac GUI reclaim and mobile relaunch/reattach must execute in the same session
UUID, generation and shell PID. The full Termio UI suite also covers live agent
rows/Needs You, opening the existing TUI directly, grid reflow after the phone
takes the writer, project navigation, drawer Files/Diff, versioned editing,
workspace/add-project controls, acknowledgements, settings, and
creating/explicitly closing a terminal. Agent status transitions are synthetic;
provider inference and hooks require separate acceptance. Reuse the retained `omg-test`
VM for mainline mobile work, without a separate clone. The runner owns its guest
gateway and disposable sessions, saves receipts/screenshots and shuts the VM down. See
[ios/README.md](../ios/README.md#vm--simulator-acceptance).
Physical-device provisioning and acceptance are separate; ordinary macOS releases
do not require them.

### Zig tests

Run Zig unit tests through the wrapper instead of typing `zig build test`:

```bash
# Tests of the Zig files changed since a ref, including the worktree
python3 dist/omg_zig_tests.py --changed-since <base-ref>

# Preview that selection without building
python3 dist/omg_zig_tests.py --changed-since <base-ref> --plan-only

# One file, or any text contained in a test's full name (repeatable)
python3 dist/omg_zig_tests.py --filter terminal.Terminal.

# The whole suite: about 4,400 tests, several minutes
python3 dist/omg_zig_tests.py --all
```

A changed file `src/terminal/Terminal.zig` selects the filter
`terminal.Terminal.`, because a test's full name starts with its file's path
below `src/`. The wrapper exists because a hand-typed `zig build test` goes
wrong in five ways here:

- **Toolchain.** The `zig` on `PATH` is usually not the release named in
  `build.zig.zon`. The wrapper runs `mise exec zig@<minimum_zig_version>`.
- **Tagged commits.** Without `-Dversion-string`, the build reads its version
  from Git and panics (`tagged releases must be in vX.Y.Z format matching
  build.zig`) on any commit that carries an OMG tag, which is every `main`
  right after a release. The wrapper passes the Ghostty version from
  `build.zig.zon`. This also lets an old tag be built in a `git worktree`.
- **Filters that match nothing.** Unnamed `test { … }` blocks run under every
  filter, so a misspelled filter still prints a passing summary. The wrapper
  first builds with a filter no test can match, then reports how many
  **selected** tests ran on top of that. A typed `--filter` that selects
  nothing fails. A file selected by `--changed-since` that selects nothing
  (not compiled for this platform) is reported, not failed.
- **Reused results.** zig reuses the result of an identical earlier test run
  and then prints `cached` with no counts, so a second run cannot tell a pass
  from a filter that selected nothing. The wrapper puts an id unique to the
  invocation into the version's build metadata, which makes every run real.
- **An unfiltered run does much more than run Zig tests.** On macOS,
  `zig build test` without `-Dtest-filter` also builds a **Debug** GhosttyKit
  over `macos/GhosttyKit.xcframework` and runs the app's XCTest through raw
  `xcodebuild` on the host desktop, with none of `macos/build.nu`'s selection
  or VM isolation. `-Demit-macos-app=false` alone does not prevent this;
  the wrapper also passes `-Demit-xcframework=false`. If it happened anyway,
  stop `xcodebuild` and rebuild GhosttyKit (see below) before the next app
  build or Swift test run.

A crash in one test is reported with its name, and the remaining tests still
run.

### Session runtime

The bundled runtime embeds `libghostty-vt`, so its revision changes whenever
`session-runtime/`, `src/terminal/`, `include/ghostty/vt/`, the OMG shell
integration or its build scripts change. Run its checks for any of those, not
only for edits under `session-runtime/`:

```bash
# The crate links zig-out/lib/libghostty-vt: build the current terminal core first
mise exec zig@0.17.1 -- zig build -Demit-lib-vt -Demit-macos-app=false \
  -Demit-xcframework=false -Doptimize=ReleaseFast -Dversion-string=1.4.1-dev

export OMG_RUNTIME_CC=/usr/bin/cc OMG_RUNTIME_AR=/usr/bin/ar
cargo fmt --manifest-path session-runtime/Cargo.toml --check
cargo clippy --manifest-path session-runtime/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path session-runtime/Cargo.toml --no-fail-fast -- --test-threads=1
cargo build --manifest-path session-runtime/Cargo.toml
python3 -m unittest discover -s session-runtime/tests -p 'test_*.py'
```

- `OMG_RUNTIME_AR` matters when Homebrew binutils is on `PATH`: GNU `ar`
  writes archives that the macOS linker rejects as `not 8-byte aligned`.
- Without `--no-fail-fast`, cargo stops at the first failing test binary and
  the later binaries are never run.
- The first command is not optional. The crate links whatever
  `libghostty-vt` is in `zig-out/lib`, so without it the tests exercise the
  terminal core that was built there last, or fail to link in a fresh
  checkout. `-Dversion-string` is the Ghostty version in `build.zig.zon`.
- Python discovery skips the tests that need a configured SSH or Linux host.
  Report them as skipped, not passed.

### GhosttyKit under Swift tests

`macos/build.nu` links whatever is in `macos/GhosttyKit.xcframework` and never
rebuilds it. After a change under `src/`, `include/`, `pkg/`, `vendor/` or to
`build.zig*`, rebuild it before running Swift tests, or they exercise the
previous core:

```bash
mise exec zig@0.17.1 -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true \
  -Dxcframework-target=native -Demit-macos-app=false -Dversion-string=1.4.1-dev
```

`-Dversion-string` is the Ghostty version in `build.zig.zon`. Keep the build
ReleaseFast: a Debug core enables page-integrity checks on every terminal
write, which makes the app slow and is never what a release ships.

### Other layer checks

The Swift selector runs **Swift tests only**. It does not rebuild GhosttyKit or
run Python, shell, browser, lint, code-signature, or artifact launch checks.
Run the ones that match the changed layer, strictly serially:

```bash
# Selector/CLI contract tests: no Xcode, zig or desktop interaction
python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'
python3 -m unittest discover -s dist -p 'test_omg_zig_tests.py'

# Changed SSH transport/integration/wrappers: validate the actual rebuilt artifact
python3 dist/test_ssh_shell_integration.py \
  --omg macos/build/Debug/OMG.app/Contents/MacOS/omg
python3 -m unittest discover -s dist -p 'test_ssh_agent_wrappers.py'

# Public README/report/contribution entry points and upstream-only Vouch jobs
python3 -m unittest discover -s dist -p 'test_omg_community_docs.py'

# Always keep the OMG documentation contract
python3 dist/check_omg_docs.py

# Signing contracts
python3 -m unittest discover -s dist -p 'test_omg_signing.py'
python3 -m unittest discover -s dist -p 'test_omg_keychain.py'
```

### What the release gate runs

`python3 dist/macos/omg_release.py gate` compares against the previous published
OMG tag and runs each layer only when the changes select it.
`python3 dist/macos/omg_release.py plan` prints the selection without running
anything.

| Layer | Selected when | What runs |
| --- | --- | --- |
| Static and contract checks | Always | SwiftLint, `zig fmt --check` on changed Zig files, settings schema, documentation contract, `plutil`, `ibtool`, and the signing, keychain, release, test-plan, mobile-plan and Zig-test-selection contracts |
| Session runtime | An input of the runtime revision changed (see above) | The commands under [Session runtime](#session-runtime) |
| Zig | A changed file under `src/` declares tests | `dist/omg_zig_tests.py` for those files |
| GhosttyKit | Swift is selected and a source of GhosttyKit changed | The native ReleaseFast rebuild under [GhosttyKit under Swift tests](#ghosttykit-under-swift-tests) |
| Swift | The module map selects suites | `macos/build.nu --action test --changed-since <tag>`; up to three suites that fail in that run are rerun alone |
| iOS | The mobile plan selects checks | `ios/scripts/test.sh`, `ios/scripts/test-vm.sh` |

The gate does **not** run: the whole Zig suite, `.interactiveDesktop` suites,
XCUITest, TCC and Sparkle upgrade experiments, live remote SSH deployment and
Linux containment checks, or frame-rate, multi-display and latency
measurements. Record the ones a release leaves out as NOT RUN in its notes,
together with the selected modules, any broad fallback, and measured results.
Do not select only the version bump commit. Release apps use persistent
self-signed code signatures and are not notarized; certificate/DR continuity,
Sparkle EdDSA, and artifact launch checks are packaging steps, described in
[RELEASING.md](RELEASING.md).

### When a check fails

There is no list of expected failures. The whole Zig suite and every
session-runtime test passed on the build host on 2026-11-22, so a failing test
is either new or depends on the machine.

- **Decide whether it is new before fixing it.** Check out the previous tag in
  a worktree and run the same test there:
  `git worktree add --detach /tmp/omg-prev v<PREVIOUS_VERSION>`. Remove the
  worktree afterwards. Tags up to `v0.23.0` predate `dist/omg_zig_tests.py`;
  there, run the `zig build test` command that `--plan-only` prints here.
- **A Swift suite that fails only in the broad run.** Rerun it alone without
  rebuilding: `macos/build.nu --action test --skip-build --only-testing
  GhosttyTests/<Suite>`. If it passes alone, the release notes name the suite
  and say so. The suite has varied from release to release
  (`EditorWorkspaceLifetimeTests` in 0.22.2, `TerminalWorkspaceAppearanceTests`
  in 0.23.0), which suggests interference between suites in one app process
  rather than a defect in one test.
- **A debug assertion in the terminal core** (`page integrity violation`) is
  compiled only into Debug builds. It still means the page was inconsistent at
  the moment of the check, so fix the order of the writes instead of the check.
- **A test that starts another program** depends on what that name resolves to
  on the host. The framework Python that Homebrew and Xcode install starts a
  second process and replaces `argv[0]`, which broke a runtime test that
  expected to see a process named `login`.

## Isolated GUI runs

To smoke-test a Debug build without taking over the host desktop, use the
retained Tart VM described in [macos/VM_TESTING.md](../macos/VM_TESTING.md). It
covers Debug deployment, GUI launch, keyboard input, PTY shell behavior and
guest screenshots, including mouse-drag selection and native fullscreen.
Sidebar tab drag, multi-display behavior, frame rate and input-to-photon
latency still require a host desktop run.
Agents should follow the `omg-vm-testing` skill
(`.agents/skills/omg-vm-testing/SKILL.md`) for that workflow.
