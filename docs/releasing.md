# Releasing Oh My Ghostty

Oh My Ghostty (OMG) and Ghostty have independent version lifecycles.

## Version model

- **OMG version** uses SemVer (`MAJOR.MINOR.PATCH`) and describes OMG-owned UI,
  settings, plugin, Inspector, and integration changes.
- **Ghostty base version** records the upstream Ghostty version represented by
  the vendored source tree.
- **Ghostty base revision** records the exact upstream commit. A development
  baseline must include both its development version and full revision.

The macOS application exposes these values independently as `OMGVersion`,
`GhosttyBaseVersion`, and `GhosttyBaseRevision` in `Info.plist`. The About view
reads them through `OhMyGhosttyVersion`.

For the initial release:

```text
OMG_VERSION=0.1.0
GHOSTTY_VERSION=1.3.2-dev
GHOSTTY_REVISION=9ae02a326f62bd88f7f5508cf1807c67e7775cb5
```

The nearest stable Ghostty release to this base is
`v1.3.1-2142-g9ae02a326f62`; the exact revision remains authoritative.

## Tags and ordering

OMG tags always use plain SemVer:

```text
v0.1.0
v0.1.1
v0.2.0
```

`CFBundleShortVersionString`, Sparkle short-version ordering, and release tags
contain only the OMG version. Ghostty metadata never participates in update
precedence. The Zig `version-string` remains the Ghostty core/base version; an
OMG build pipeline must not pass the OMG tag to that Zig option.

Do not append `-ghostty.x.y.z`: SemVer treats it as a prerelease. Do not rely on
`+ghostty.x.y.z` for identity or ordering: SemVer ignores build metadata when
comparing precedence. Instead, use a release title such as:

```text
OMG 0.4.3 · Ghostty 1.4.0
```

A Ghostty synchronization is still a normal OMG SemVer release. Increment the
OMG version according to the user-visible OMG change, update the two Ghostty
base fields, and call out the new base in the title and release notes.

## Source of truth

Before a release, update and verify:

1. The Ghostty app target `MARKETING_VERSION` in
   `macos/Ghostty.xcodeproj/project.pbxproj` (OMG version).
2. `OMGVersion`, `GhosttyBaseVersion`, and `GhosttyBaseRevision` in
   `macos/Ghostty-Info.plist`.
3. `build.zig.zon` still identifies the same Ghostty source version recorded in
   `GhosttyBaseVersion`.
4. The recorded Ghostty revision is the actual upstream base commit.

Upstream Ghostty tags are present locally for synchronization history. Never
push them with `git push --tags`; push only the explicit OMG release tag.

## Release checklist

1. Confirm the default branch is clean and tests/builds pass.
2. Create an annotated `vX.Y.Z` tag on the verified default-branch commit.
3. Push the default branch and only that explicit tag.
4. Publish a GitHub Release titled `OMG X.Y.Z · Ghostty A.B.C`.
5. Include OMG version, Ghostty base version, exact base revision, and verified
   highlights in the notes.

The inherited upstream Ghostty workflows reference Ghostty-owned runners,
signing credentials, R2 storage, and appcast infrastructure. They are not a
valid OMG binary-release pipeline and are guarded from running in the fork.
OMG builds point Sparkle only at the OMG-owned GitHub release appcast URL, never
at the upstream Ghostty feed. Until OMG has its own signing key and publishes
that `appcast.xml` asset, GitHub Releases are source releases and automatic
updates are unavailable rather than incorrectly crossing into Ghostty's
version stream. Do not attach ad-hoc or unsigned macOS binaries.
