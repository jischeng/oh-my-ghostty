---
name: omg-release
description: Builds, validates, installs, and publishes Oh My Ghostty macOS development and patch releases. Use when asked to install or replace OMG Dev, prepare a release, bump OMG versions, build arm64/x86_64/universal DMGs, generate the Sparkle appcast, tag, push, or publish a GitHub Release.
compatibility: macOS, Xcode, Zig 0.16.0 via mise, Nushell, SwiftLint, GitHub CLI, and Sparkle tools.
---

# OMG Build and Release

Authoritative docs: `docs/RELEASING.md`, `AGENTS.md`, `macos/AGENTS.md`.
Use this skill in the `oh-my-ghostty` repo. Never open the Xcode GUI. Never touch `/Applications/OMG.app`.

---

## Fast Rules for AI Agents (Avoid Common Pitfalls)

1. **Never run builds/tests concurrently**:
   - Concurrent `xcodebuild` or `macos/build.nu` calls fail with `build.db: database is locked`. Run tests and builds strictly serially.
2. **Handle environment-sensitive tests rationally**:
   - `VerticalTabMouseTests` and `VerticalTabsIntegrationTests` simulate real mouse events/drag-and-drop on AppKit windows. In headless or non-GUI-focused agent sessions, `mouseSelectionKeepsWorkingAcrossNativeWindows` may fail because `pasteboard.changeCount` requires active window focus.
   - If only UI mouse/drag tests fail while all unit/logic tests pass, run targeted tests on changed modules. Do not block a release or spin in circles trying to rewrite unaffected core UI tests.
3. **Always run transitive tests when modifying core helpers**:
   - When touching `OMGThemeBackground.swift` or `TerminalController.swift`, test both `OMGThemeBackgroundTests` AND `TerminalChromeBackgroundTests` + `OhMyGhosttySettingsTests`.
4. **Shell compatibility**:
   - Pi default shell may be Fish. Wrap multiline bash scripts with `/bin/bash -lc '...'`.
5. **Always specify `--repo jischeng/oh-my-ghostty` for `gh release`**:
   - The git remote `upstream` points to `ghostty-org/ghostty`. Default `gh release create` may target upstream and fail. Always pass `--repo jischeng/oh-my-ghostty`.
6. **Local signing environment**:
   - If Keychain lacks `Developer ID Application` identity, use `OMG_SIGNING_IDENTITY=-` (ad-hoc). State clearly in release notes that the release is ad-hoc signed and unnotarized.
   - If Rosetta 2 is not installed on the build machine (`arch -x86_64` fails), the packaging script will verify the x86_64 Mach-O slice and `.ReleaseFast` marker without launching it. Document this in release notes.

---

## Workflow 1: Install OMG Dev (Local Testing)

```bash
.agents/skills/omg-release/scripts/install-dev.sh
```

**Prerequisites**:
- Working tree **MUST BE CLEAN**. Commit all changes first with `writing-commit-messages`.
- To skip recompilation if just built: `install-dev.sh --skip-build`.

---

## Workflow 2: Publish OMG Release

### Step 1: Version & Metadata
1. Ensure on `main` branch, synced with `origin/main`.
2. Determine new version `<OMG_VERSION>` (e.g. `0.15.2`).
3. Update version in `macos/Ghostty.xcodeproj/project.pbxproj` (all 3 configs: `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`).
4. Update `macos/Tests/Helpers/OhMyGhosttyVersionTests.swift` expected version strings.
5. Create `docs/RELEASE_NOTES_<OMG_VERSION>.md`.

### Step 2: Quality Gates
Run sequentially:
```bash
# 1. Lint & Docs
swiftlint lint --strict --config macos/.swiftlint.yml macos
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check
python3 -m json.tool docs/settings/schema.json >/dev/null
python3 dist/check_omg_docs.py
plutil -lint macos/Ghostty-Info.plist
xcrun ibtool --warnings --errors --notices --output-format human-readable-text macos/Sources/App/MainMenu.xib
rm -f default.profraw

# 2. Test targeted suites related to changes (or full suite if confident)
macos/build.nu --action test --only-testing GhosttyTests/<ChangedSuites>
```

### Step 3: Build Release Binaries
```bash
.agents/skills/omg-release/scripts/build-release.sh <OMG_VERSION>
```
Output placed under `.release-build/<OMG_VERSION>/`.

### Step 4: Sign & Package DMGs
Check signing identity: `security find-identity -v -p codesigning`.
- If no Developer ID identity exists, use `OMG_SIGNING_IDENTITY=-`.

```bash
OMG_SIGNING_IDENTITY=- \
PREVIOUS_TAG=v<PREVIOUS_VERSION> \
.agents/skills/omg-release/scripts/package-release.sh <OMG_VERSION>
```
Produces:
- `OMG-<version>-macos-arm64.dmg`
- `OMG-<version>-macos-x86_64.dmg`
- `OMG-<version>-macos-universal.dmg`
- `SHA256SUMS.txt`
- `appcast.xml`

### Step 5: Commit, Tag & Push
```bash
git add macos/Ghostty.xcodeproj/project.pbxproj macos/Tests/Helpers/OhMyGhosttyVersionTests.swift docs/RELEASE_NOTES_<OMG_VERSION>.md
git commit -m "release: prepare OMG <OMG_VERSION>"
git push origin main

git tag -a "v<OMG_VERSION>" -m "OMG <OMG_VERSION> · Ghostty 1.3.2-dev"
git push origin "refs/tags/v<OMG_VERSION>"
```
*Note: Never run `git push --tags`.*

### Step 6: Publish GitHub Release
```bash
gh release create "v<OMG_VERSION>" \
  .release-build/<OMG_VERSION>/artifacts/OMG-<OMG_VERSION>-macos-arm64.dmg \
  .release-build/<OMG_VERSION>/artifacts/OMG-<OMG_VERSION>-macos-x86_64.dmg \
  .release-build/<OMG_VERSION>/artifacts/OMG-<OMG_VERSION>-macos-universal.dmg \
  .release-build/<OMG_VERSION>/artifacts/SHA256SUMS.txt \
  .release-build/<OMG_VERSION>/artifacts/appcast.xml \
  --repo jischeng/oh-my-ghostty \
  --title "OMG <OMG_VERSION>" \
  --notes-file docs/RELEASE_NOTES_<OMG_VERSION>.md
```

---

## Completion Report Checklist
- Commit SHAs and tag name (`vX.Y.Z`).
- Target architectures built (`arm64`, `x86_64`, `universal`).
- Signing (`ad-hoc` or `Developer ID`) & notarization status.
- GitHub Release URL and list of 5 uploaded assets.
