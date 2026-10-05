# Releasing OMG

This document is the source of truth for building, signing, packaging, and
publishing the macOS application. Commands are written for the current
repository layout and must be updated in the same change that modifies a build
path, product name, version key, package script, signing step, or updater feed.

OMG's Xcode target and Swift module retain the internal name `Ghostty` to reduce
upstream merge conflicts. The shipped product is independent:

```text
Application:       OMG.app
Executable:        omg
Bundle identifier: com.jischeng.omg
Debug identifier:  com.jischeng.omg.debug
```

Release and Debug are separate operating channels. Maintainer builds may only
overwrite `/Applications/OMG Dev.app`; they must never replace or terminate
`/Applications/OMG.app`. Their UserDefaults, window restoration, settings,
appearance overlay, plugin package/data, and SSH replay directories are
isolated. Vendor Agent hooks are the sole intentionally shared integration and
must only be changed through the versioned owner-marker installer.

## Current automation status

OMG releases are currently a **maintainer-run macOS workflow**. The inherited
`.github/workflows/release-tag.yml` and `publish-tag.yml` use Ghostty-owned
runners, signing credentials, R2 storage, and appcast infrastructure. Both
upstream publishing workflows are guarded from running in this fork and are not
an OMG release path.

The checked-in scripts that are authoritative for OMG are:

- `macos/build.nu` — Xcode development/test wrapper;
- `dist/macos/sign_omg_app.sh` — consistent nested code signing;
- `dist/macos/package_omg_dmg.sh` — architecture-specific and universal DMG packaging.

A future OMG GitHub Actions release workflow must implement this document; it
must not enable the inherited Ghostty publishing jobs.

## Version model

OMG and Ghostty have independent version lifecycles.

### OMG version

OMG uses SemVer (`MAJOR.MINOR.PATCH`) and controls application/update ordering.
Until an explicit 1.0 product decision, releases remain in `0.x.y` and select the
next version by this mandatory policy:

```text
0.3.0 -> 0.3.1     bug fixes only; Ghostty base unchanged
0.3.1 -> 0.4.0     any new user-visible feature or capability
0.3.1 -> 0.4.0     any Ghostty base version/revision update
0.x.y -> 1.0.0     only an explicit stable product/API milestone decision
```

A release containing both fixes and features takes the minor bump. Automation
must never infer or publish `1.0.0`; reaching 1.0 requires an explicit human
product decision and release-plan update. "Automatic bump" means applying the
rules above when preparing a requested release, not publishing without approval.

For a published release, the tag and `CFBundleShortVersionString` contain only
this value:

```text
v0.1.2
```

Local OMG Dev builds are the sole exception and use the traceability suffix and
separate `dev-` tag namespace documented in [Development build](#1-development-build).
Do not append `-ghostty.x.y.z`; SemVer treats that as a prerelease. Do not use
build metadata as the only Ghostty record; SemVer ignores it for precedence.

### Ghostty base

The Ghostty base records the terminal core independently:

```text
GhosttyBaseVersion  = upstream release or development version
GhosttyBaseRevision = exact full upstream commit
```

A normal OMG update increments only OMG when the base is unchanged. Any change
to `GhosttyBaseVersion` or `GhosttyBaseRevision` requires the next OMG **minor**
release while OMG remains pre-1.0, even if the sync is itself only upstream bug
fixes:

```text
OMG 0.3.1 · Ghostty 1.x.x
OMG 0.4.0 · Ghostty 1.x.y   # after any upstream base/revision sync
```

The Ghostty change never resets or replaces OMG SemVer. Release titles use:

```text
OMG <OMG_VERSION> · Ghostty <GHOSTTY_VERSION>
```

## Version sources

Before release, update and cross-check:

1. Main app target `MARKETING_VERSION` in
   `macos/Ghostty.xcodeproj/project.pbxproj` for Debug, Release, and
   ReleaseLocal.
2. Main app target `CURRENT_PROJECT_VERSION` (Sparkle/CFBundleVersion) in those
   same three configurations. It is a monotonically increasing integer for
   every published OMG release and never resets on minor bumps.
3. `OMGVersion`, `GhosttyBaseVersion`, and `GhosttyBaseRevision` in
   `macos/Ghostty-Info.plist`.
4. Ghostty's source version in `build.zig.zon`.
5. The actual base revision from `git rev-parse upstream/main` (or the selected
   upstream release commit).

The Zig `-Dversion-string` remains the Ghostty core version. Never pass the OMG
version to that option.

Verification:

```bash
xcodebuild -project macos/Ghostty.xcodeproj \
  -target Ghostty -configuration Release -showBuildSettings \
  | grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'

head -n 6 build.zig.zon
git rev-parse upstream/main
```

## Required tools

- macOS and Xcode command-line tools;
- Zig 0.16.0 (the repository uses `mise` in examples);
- SwiftLint;
- Nushell for `macos/build.nu`;
- GitHub CLI (`gh`) for publishing;
- Apple `codesign`, `hdiutil`, `ditto`, and `plutil`.

Public releases use **ad-hoc code signatures** (`OMG_SIGNING_IDENTITY=-`).
Apps and DMGs are **not notarized**. Developer ID certificates, Apple developer
account credentials, and notarization profiles are not release prerequisites.

## Environment and secrets

Use placeholders or environment variables. Never commit values, `.p12` files,
API keys, passwords, keychain exports, or local absolute paths.

```bash
export OMG_VERSION="<x.y.z>"
export GHOSTTY_VERSION="<x.y.z-or-x.y.z-dev>"
export GHOSTTY_REVISION="<full-upstream-commit>"
export OMG_BUILD_ROOT="$PWD/.release-build/$OMG_VERSION"
export OMG_SIGNING_IDENTITY=-
```

Release signing uses the literal identity `-`; no certificate lookup or Apple
account authentication is required. Sparkle update signing uses its separate
EdDSA key as described in [Updater and Sparkle signing](#9-updater-and-sparkle-signing).

## 1. Development build

### Preconditions

- dependencies are available;
- `mise` can resolve Zig 0.16.0;
- Xcode and SwiftLint are installed.

When Zig/core/build files changed, rebuild GhosttyKit first. Routine OMG
host/UI/SSH/Agent development and acceptance testing should keep the Swift app
in Debug but use a ReleaseFast GhosttyKit core; this preserves app-layer
debuggability without enabling Debug-only terminal page integrity checks. Build
a Debug GhosttyKit only when intentionally investigating Zig terminal-core,
page, parser, or renderer behavior; never use that artifact for release
packaging.

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Demit-macos-app=false \
    -Dversion-string="$GHOSTTY_VERSION"
```

Build the app:

```bash
macos/build.nu --scheme Ghostty --configuration Debug --action build
```

Output:

```text
macos/build/Debug/OMG.app
```

For a traceable `/Applications/OMG Dev.app` install, use the release skill's
installer instead of the raw build command:

```bash
.agents/skills/omg-release/scripts/install-dev.sh
```

The Dev installer always rebuilds the native ReleaseFast GhosttyKit before
building the Swift app (unless `--skip-build` is explicitly supplied). Xcode
alone can reuse an old core while stamping a new app version. Before replacing
OMG Dev, the signed executable's `+ssh` command is captured with a fake SSH
transport, compared byte-for-byte against current source (except session IDs),
and exercised through Fish/bash/zsh. This offline artifact gate also applies to
`--skip-build`; a version label and `.ReleaseFast` mode alone are insufficient.

The Dev installer requires a persistent code-signing identity so macOS TCC can
recognize replacement builds and retain previously granted folder permissions.
It selects the first valid code-signing identity from the login keychain by
default; set `OMG_DEV_SIGNING_IDENTITY` to a certificate name or SHA-1 hash to
choose one explicitly. The installer fails instead of falling back to ad-hoc
signing when no identity is available. Dev signing keeps
`GhosttyDebug.entitlements`; certificate material and names are never stored in
the repository.

Before using it, the agent must review and validate the intended test changes,
commit them, and confirm that `HEAD` contains those changes with a completely
clean worktree. Generated files, secrets, and unrelated user changes must not be
silently included. Do not stash or discard unrelated changes merely to satisfy
the installer; ask the user how to separate unclear changes. The installer
never creates the commit itself and fails closed when the tree is dirty.

It then derives the local app version `<release>-dev.<8-char-commit>` and creates
the annotated local Git tag
`dev-v<release>-<8-char-commit>` only after the built app has been installed and
verified. The `dev-` namespace does not match the OMG release tag form `vX.Y.Z`;
therefore it is not an OMG release and must not receive a GitHub Release or
Sparkle artifact. The tag stays local by default. Use `--push-tag` only when a
remote issue needs a resolvable tag, and push only that explicit ref. Never tag
a dirty tree or move/force-update an existing Dev tag because either action
would make the installed version misleading.

Success for a routine development or acceptance build means `xcodebuild` exits
zero, this executable exists, and the GhosttyKit core reports ReleaseFast:

```bash
macos/build/Debug/OMG.app/Contents/MacOS/omg --version \
  | grep -F 'build mode    : .ReleaseFast'
```

A deliberately core-debug build may report `.Debug`; label it as such and do
not treat its large-output performance as representative of OMG release
artifacts.

Common failures:

- wrong Zig version;
- dependency downloads affected by local proxy variables;
- stale architecture-only `GhosttyKit.xcframework`;
- invoking Xcode from a Nix environment with injected compiler/linker flags.

## 2. Local Release builds

Release artifacts are separate arm64 and x86_64 apps. Build a universal
GhosttyKit first so Xcode cannot link the wrong static archive:

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy \
  mise exec zig@0.16.0 -- zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Demit-macos-app=false \
    -Dversion-string="$GHOSTTY_VERSION"

lipo -archs \
  macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a
# expected: arm64 x86_64 (order is not significant)
```

Build each app into an isolated root:

```bash
for arch in arm64 x86_64; do
  xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -target Ghostty \
    -configuration Release \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    SYMROOT="$OMG_BUILD_ROOT/$arch" \
    OBJROOT="$OMG_BUILD_ROOT/obj-$arch" \
    build
done
```

Build one additional universal App for the single Sparkle enclosure:

```bash
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -target Ghostty \
  -configuration Release \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  SYMROOT="$OMG_BUILD_ROOT/universal" \
  OBJROOT="$OMG_BUILD_ROOT/obj-universal" \
  build
```

Outputs:

```text
$OMG_BUILD_ROOT/arm64/Release/OMG.app
$OMG_BUILD_ROOT/x86_64/Release/OMG.app
$OMG_BUILD_ROOT/universal/Release/OMG.app
```

Verify architecture and metadata:

```bash
for arch in arm64 x86_64 universal; do
  app="$OMG_BUILD_ROOT/$arch/Release/OMG.app"
  lipo -archs "$app/Contents/MacOS/omg"
  plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist"
  plutil -extract OMGVersion raw "$app/Contents/Info.plist"
  plutil -extract GhosttyBaseVersion raw "$app/Contents/Info.plist"
  plutil -extract GhosttyBaseRevision raw "$app/Contents/Info.plist"
  "$app/Contents/MacOS/omg" --version \
    | grep -F 'build mode    : .ReleaseFast'
done
```

Each architecture-specific binary must contain exactly its named architecture;
the universal updater binary must contain both `arm64` and `x86_64`. An `arm64`
archive in an x86_64 link produces ignored-object warnings followed by undefined
Ghostty symbols; rebuild the universal XCFramework instead of suppressing the
warning.

## 3. Validation gate

Run before signing and again on the commit that will be tagged.

Formatting and resources:

```bash
mise exec swiftlint -- swiftlint lint --strict --config macos/.swiftlint.yml macos
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check
python3 -m json.tool docs/settings/schema.json >/dev/null
python3 dist/check_omg_docs.py
plutil -lint macos/Ghostty-Info.plist
xcrun ibtool --warnings --errors --notices \
  --output-format human-readable-text macos/Sources/App/MainMenu.xib
```

App-hosted Swift selection is based on changed modules and direct dependents,
not on patch/minor/major release size. Use the previous **published OMG tag**, so
all release commits are covered rather than only the version bump:

```bash
macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>" --test-plan-only
macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>"
```

Shared host/core, build/test infrastructure, or unmapped changes fall back to all
routine Swift suites. For an intentional broad sweep, use
`macos/build.nu --action test --test-modules all`. Builds/tests remain serialized.
Affected Zig/Python/shell tests and actual-artifact checks still run separately;
the selector does not claim to run those layers.

Real native desktop interaction suites tagged `.interactiveDesktop` are optional
and excluded by default, with an explicit **NOT RUN** report. After relevant native
tab, drag/drop, focus, or event-routing changes, schedule them explicitly on an
unlocked desktop with a foreground test application:

```bash
macos/build.nu --action test \
  --only-testing GhosttyTests/VerticalTabMouseTests --include-desktop-tests
```

A locked/background test session cannot establish native drag/focus behavior;
record deferred coverage rather than treating it as passed. Pure policy/lifecycle
and routine tab integration tests still run by default. This optional desktop
tier does not automatically block unrelated releases. XCUITest is a separate
permissions-enabled workflow and remains excluded by the wrapper. Full selection
rules, module map, and selector contract tests are in [TESTING.md](TESTING.md).

Success criteria:

- no failures in the selected routine tests, with recorded scope/results;
- optional desktop tests run and their results, or an explicit not-run reason,
  are recorded separately (never called passed if not run);
- SwiftLint has zero violations;
- XIB/JSON/plist checks have no errors;
- Debug and both Release architectures build;
- `OMG.app` contains only `OMG.icns`, uses executable `omg`, and has bundle ID
  `com.jischeng.omg` (`com.jischeng.omg.debug` for Debug);
- official Ghostty and OMG can launch simultaneously;
- no generated build products or local configuration appear in `git status`.

## 4. Signing

Ad-hoc sign every nested Sparkle component, plug-in, and app with identity `-`.
Sign the arm64, x86_64, and universal apps. Hardened runtime must be disabled for
all ad-hoc signatures. The universal app is the Sparkle updater enclosure.

```bash
export OMG_SIGNING_IDENTITY=-

for arch in arm64 x86_64 universal; do
  dist/macos/sign_omg_app.sh \
    "$OMG_BUILD_ROOT/$arch/Release/OMG.app"
done
```

Success:

```bash
codesign --verify --deep --strict --verbose=2 \
  "$OMG_BUILD_ROOT/arm64/Release/OMG.app"
codesign -dv --verbose=4 \
  "$OMG_BUILD_ROOT/arm64/Release/OMG.app"

# Mandatory launch probe; static signature verification alone is insufficient.
"$OMG_BUILD_ROOT/arm64/Release/OMG.app/Contents/MacOS/omg" --version
```

Static code-signature verification and the executable launch probe are both
required. Ad-hoc signing does not replace Sparkle's EdDSA update signature.

## 5. Notarization status

OMG apps and DMGs are not notarized. Notarization submission and ticket stapling
are not release workflow steps. Release notes must state **ad-hoc signed; not
notarized** and disclose that macOS Gatekeeper may block the first launch. Users
who trust the downloaded app can use macOS System Settings > Privacy & Security
to review and allow it. Do not disable Gatekeeper globally.

## 6. Package DMGs

```bash
mkdir -p "$OMG_BUILD_ROOT/artifacts"
for arch in arm64 x86_64 universal; do
  dist/macos/package_omg_dmg.sh \
    "$OMG_VERSION" \
    "$arch" \
    "$OMG_BUILD_ROOT/$arch/Release/OMG.app" \
    "$OMG_BUILD_ROOT/artifacts"
done

for dmg in "$OMG_BUILD_ROOT"/artifacts/*.dmg; do
  hdiutil verify "$dmg"
done

(cd "$OMG_BUILD_ROOT/artifacts" && shasum -a 256 *.dmg > SHA256SUMS.txt)
```

The DMG script verifies bundle ID, OMG version, signature, and either one named
architecture or the exact universal pair; it creates an `Applications` symlink
and names artifacts:

```text
OMG-<version>-macos-arm64.dmg
OMG-<version>-macos-x86_64.dmg
OMG-<version>-macos-universal.dmg
SHA256SUMS.txt
appcast.xml
```

Mount each DMG read-only and launch the contained app before publishing. Test
the Intel build on Intel hardware or under Rosetta 2; record which was used.

## 7. Merge to the default branch

The repository default branch is `main` (not `master`). Never force-push.

```bash
git fetch origin --prune
git status --short --branch
git switch main
git pull --ff-only origin main
git merge --ff-only <release-branch>
```

Re-run the validation gate on `main`, then:

```bash
git push origin main
```

If fast-forward fails, stop and inspect divergence. Do not overwrite remote
commits or resolve release conflicts by force.

## 8. Tag and publish GitHub Release

Ensure no tag/release already exists:

```bash
git tag --list "v$OMG_VERSION"
gh release view "v$OMG_VERSION" -R jischeng/oh-my-ghostty
```

Create and push only the explicit OMG tag:

```bash
git tag -a "v$OMG_VERSION" \
  -m "OMG $OMG_VERSION · Ghostty $GHOSTTY_VERSION"
git push origin "refs/tags/v$OMG_VERSION"
```

Do not use `git push --tags`; local upstream Ghostty tags are synchronization
history, not OMG releases.

Create the release and upload artifacts:

```bash
gh release create "v$OMG_VERSION" \
  -R jischeng/oh-my-ghostty \
  --verify-tag \
  --title "OMG $OMG_VERSION · Ghostty $GHOSTTY_VERSION" \
  --notes-file "<release-notes-file>"

gh release upload "v$OMG_VERSION" \
  -R jischeng/oh-my-ghostty \
  "$OMG_BUILD_ROOT"/artifacts/*.dmg \
  "$OMG_BUILD_ROOT/artifacts/SHA256SUMS.txt" \
  "$OMG_BUILD_ROOT/artifacts/appcast.xml"
```

Release notes must include highlights, OMG version, Ghostty version, full
Ghostty revision, architecture test evidence, and signing/notarization status.

## 9. Updater and Sparkle signing

OMG's Sparkle delegate points only to the OMG-owned GitHub Release appcast URL.
It must never use Ghostty's `1.x` appcast because OMG has independent SemVer.

OMG uses a dedicated EdDSA key stored in the login Keychain under Sparkle
account `com.jischeng.omg`. The public key is the `SUPublicEDKey` value in
`macos/Ghostty-Info.plist`; never commit or print the private key. Generate the
signed appcast from a staging directory that contains the previous appcast and
only the verified universal DMG:

```bash
appcast_work="$OMG_BUILD_ROOT/appcast-work"
rm -rf "$appcast_work"
mkdir -p "$appcast_work"
cp "$OMG_BUILD_ROOT/artifacts/appcast.xml" "$appcast_work/appcast.xml"
cp "$OMG_BUILD_ROOT/artifacts/OMG-$OMG_VERSION-macos-universal.dmg" \
  "$appcast_work/"

generate_appcast \
  --account com.jischeng.omg \
  --download-url-prefix "https://github.com/jischeng/oh-my-ghostty/releases/download/v$OMG_VERSION/" \
  --embed-release-notes \
  "$appcast_work"
cp "$appcast_work/appcast.xml" "$OMG_BUILD_ROOT/artifacts/appcast.xml"
```

Do not put the arm64, x86_64, and universal DMGs in the appcast input together:
they share one bundle version, and Sparkle rejects them as duplicate updates.
The architecture-specific DMGs are manual-download assets; the universal DMG
is the single updater enclosure.

Before generation, copy the currently published `appcast.xml` into the artifacts
directory so Sparkle preserves recent entries. If the asset download is
unavailable, the packaging script can use the previous release's local artifact
cache only after its SHA-256 matches the asset digest returned by GitHub's API. Verify that every new
enclosure has `sparkle:edSignature`, architecture/system requirements, the
expected `sparkle:shortVersionString`, and a strictly larger numeric
`sparkle:version` (`CFBundleVersion`). Upload the generated `appcast.xml` as a
GitHub Release asset alongside the signed enclosures.

Migration limitation: OMG 0.3.0 inherited Ghostty's upstream public key, whose
private key is not owned by OMG. It cannot securely validate an OMG-signed
0.3.1 enclosure. Version 0.3.1 is therefore the one-time manual bridge release;
once manually installed, its new OMG public key supports signed update checks
to later releases. Do not publish an unsigned or mismatched appcast to pretend
0.3.0 can update.

`SUEnableAutomaticChecks` remains false; users can invoke Check for Updates
manually. Enabling automatic periodic checks is a separate product decision.
The inherited `dist/macos/update_appcast_tag.py` targets Ghostty infrastructure
and artifact names; it is not an OMG publishing script.

## 10. Common failures

| Symptom | Cause | Required action |
| --- | --- | --- |
| x86_64 undefined `_ghostty_*` symbols | arm64-only GhosttyKit | rebuild universal XCFramework |
| dyld refuses Sparkle at launch | inconsistent nested signatures or hardened runtime on ad-hoc components | ad-hoc re-sign all nested components and the app without hardened runtime; repeat the launch probe |
| Gatekeeper blocks first launch | app is ad-hoc signed and not notarized | disclose this in release notes; trusted downloads can be reviewed in System Settings > Privacy & Security; do not disable Gatekeeper globally |
| `Ghostty.app` appears in output | stale build or old product settings | clean build; expected product is `OMG.app` |
| Release sorts below same version | tag used prerelease suffix | use plain `vX.Y.Z` OMG tag |
| Update check compares against Ghostty | wrong appcast | use only OMG-owned appcast |
| workflow waits for unavailable runner/secrets | inherited upstream workflow | use this manual process; do not enable upstream job |

## 11. Rollback

Before publishing, delete/rebuild local artifacts freely. After publishing:

- do not move or silently retarget a released tag;
- mark a broken GitHub Release as withdrawn and publish a higher OMG patch;
- remove dangerous binary assets if necessary, but preserve notes explaining
  the withdrawal;
- rotate any credential that may have entered logs or Git history.

## Privacy rule

Release documentation and scripts must contain placeholders only. A change that
adds a real account email, Team ID, certificate, password, token, key, private
URL, internal IP, or user-specific absolute path must not be merged. CI secrets
belong in GitHub/Apple secret stores and should be exposed only to the exact job
that needs them.
