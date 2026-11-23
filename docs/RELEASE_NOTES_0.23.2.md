# OMG 0.23.2 · Ghostty 1.4.1-dev

OMG 0.23.2 is a patch release hardening macOS workspace tab-group restoration and window-close lifecycles, and eliminating the transparent terminal center flash on cold startup.

## Highlights

### Workspaces & Native Tabs

- **Hardened cold-start tab group restoration.** Unified `tabbingIdentifier` across workspace members before attaching, detached foreign tab groups before re-attaching, verified tab-group membership, and preserved tab ordering for pre-selection members on cold start. Added automatic fallback to non-retained mode when retained apply fails, pruned stale empty windows/groups, and kept right-sidebar visibility synced once native tab selection settles.
- **No more resurrected closed windows or crash on multi-tab close.** Closing a standalone window (`Cmd+Shift+W`) now forgets its closed tabs and prunes the empty host window from persisted workspace state instead of resurrecting it on relaunch, while preserving Undo Close Window and parked workspaces. Guarded empty `tabGroup` selection reads and invalidated `TransparentTitlebarTerminalWindow` KVO/refresh callbacks on close to prevent `NSInternalInconsistencyException` when closing multi-tab windows with parked workspaces.
- **Preserved suspended sibling-workspace tabs on shared hosts.** Closing a shared host window now forgets closed tabs and prunes the host window only when no other workspaces or tabs remain on that `windowSessionID`, retaining suspended sibling-workspace tabs for restoration.

### macOS Startup & Rendering

- **No transparent terminal center flash on cold startup.** Filled the center terminal rect in `TerminalShellNativeView`'s chrome backdrop before SwiftUI mounts any `SurfaceView`, then covered only surfaces whose `IOSurface` has not yet arrived (excluding unhealthy/error and editor-covered panes), clearing the fill synchronously via KVO in the same main-thread `CATransaction` as soon as the first `IOSurface` presents.

## Version and distribution

- OMG **0.23.2**, bundle version **67**.
- Ghostty **1.4.1-dev**, revision `7a8ff4d992edd2aad7537e5bef73ec911aa126bf` (unchanged from `0.23.1`).
- Includes the changes since the published `v0.23.1` tag.
- macOS release apps and DMGs are **persistently self-signed; not notarized**.
  macOS Gatekeeper may block the first launch; users who trust the download can
  review and allow it in **System Settings → Privacy & Security**. Do not
  disable Gatekeeper globally. Sparkle updates retain their separate EdDSA
  signature on the universal DMG enclosure.
- The `arm64`, `x86_64`, and `universal` macOS apps bundle the local universal
  relay, mobile support helper, and Linux (`x86_64`, `aarch64`) remote session
  runtime artifacts. The session runtime revision `8e8d42c58b3ddd438eb3` and
  snapshot revision `7abe5365444c63ee8df6` are unchanged from `0.23.1`. A remote
  daemon that owns live sessions is never replaced in place, so existing
  sessions stay on the revision they started with.
- iOS physical device installation requires signing with the user's own Apple ID
  (a free Personal Team Apple ID works via `OMG-Mobile-0.23.2-ios-installer.tar.gz`,
  or via a sideloader using `OMG-Mobile-0.23.2-ios-unsigned.ipa`).

## Validation

- **Static and contract checks**: passed (`swiftlint --strict`, settings schema,
  documentation contract, `plutil`, `ibtool`, signing, keychain, release,
  test-plan, mobile-plan, and zig-tests contracts; `zig fmt --check` skipped as
  no `.zig` files changed).
- **Zig / Session runtime**: not selected (no `.zig` or session-runtime inputs
  changed since `v0.23.1`).
- **Swift**: all 13 routine modules (204 suites) passed in the retained Tart VM.
  `EditorWorkspaceLifetimeTests` failed in the initial broad run and passed on
  isolated retry; all other 203 suites passed in the broad run.
- **iOS**: `native-core`, `simulator-build`, and `vm-simulator-ui` checks passed.
- **Packaging**: all three macOS builds (`arm64`, `x86_64`, `universal`) signed
  with the pinned persistent certificate (`9b2e176c03e5458e6fdaf73392cd9d79203972c6`),
  post-sign `session-runtime` manifests verified, `arm64` and `universal` launch
  probes passed, `x86_64` Mach-O slice and signature verified (launch skipped as
  Rosetta 2 is not installed), and Sparkle EdDSA `appcast.xml` verified.
- **Not run**: optional `.interactiveDesktop` native drag/focus suites (15
  deferred), XCUITest, full desktop TCC and Sparkle upgrade experiments, live
  remote SSH deployment/Linux containment gates, and host frame-rate/latency
  measurements.
