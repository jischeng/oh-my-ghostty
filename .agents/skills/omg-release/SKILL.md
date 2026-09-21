---
name: omg-release
description: Builds, validates, installs, and publishes Oh My Ghostty macOS development and patch releases. Use when asked to install or replace OMG Dev, prepare a release, bump OMG versions, build arm64/x86_64/universal DMGs, generate the Sparkle appcast, tag, push, or publish a GitHub Release.
compatibility: macOS, Xcode, Zig 0.16.0 via mise, Nushell, SwiftLint, GitHub CLI, and Sparkle tools.
---

# OMG Build and Release

Authoritative docs: `docs/RELEASING.md`.
Use this skill in the `oh-my-ghostty` repo. Never open the Xcode GUI. Never touch `/Applications/OMG.app`.

---

## Core Rules

1. **Testing strategy by release type**:
   - **Patch releases (`0.x.Y`)**: Run **only targeted tests** for changed modules and their direct dependents (`--only-testing GhosttyTests/<Suites>`). Do NOT run the full test suite.
   - **Minor/Major releases (`0.X.0`)**: Run the **full test suite** (`macos/build.nu --action test`).
2. **Build and test strictly serially**: Never run multiple builds or tests concurrently (`build.db: database is locked`).
3. **Shell compatibility**: Pi shell may be Fish. Wrap multiline shell commands with `/bin/bash -lc '...'`.
4. **GitHub CLI target**: Always pass `--repo jischeng/oh-my-ghostty` when running `gh release create` (`upstream` points to `ghostty-org/ghostty`).
5. **Signing & Rosetta**: If Keychain lacks `Developer ID Application`, set `OMG_SIGNING_IDENTITY=-` (ad-hoc). If Rosetta 2 is not installed, the script verifies the `x86_64` Mach-O slice without launching it. Document both in release notes.

---

## Workflow 1: Install OMG Dev (Local Testing)

```bash
.agents/skills/omg-release/scripts/install-dev.sh
```

**Prerequisites**:
- Working tree **must be clean** (commit changes first).
- Use `--skip-build` if the app was just compiled.

---

## Workflow 2: Publish OMG Release

### Step 1: Version & Release Notes
1. Ensure on `main` branch, synced with `origin/main`.
2. Update version in `macos/Ghostty.xcodeproj/project.pbxproj` (all 3 configs: update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION`).
3. Update `macos/Tests/Helpers/OhMyGhosttyVersionTests.swift` with expected version strings.
4. Create `docs/RELEASE_NOTES_<OMG_VERSION>.md`.

### Step 2: Quality Gates
Run sequentially:
```bash
# 1. Lint, schema & docs
swiftlint lint --strict --config macos/.swiftlint.yml macos
git ls-files -z '*.zig' | xargs -0 mise exec zig@0.16.0 -- zig fmt --check
python3 -m json.tool docs/settings/schema.json >/dev/null
python3 dist/check_omg_docs.py
plutil -lint macos/Ghostty-Info.plist
xcrun ibtool --warnings --errors --notices --output-format human-readable-text macos/Sources/App/MainMenu.xib
rm -f default.profraw

# 2. Tests
# Patch release (0.x.Y): targeted only
macos/build.nu --action test --only-testing GhosttyTests/<ChangedSuites>

# Minor/Major release (0.X.0): full suite
# macos/build.nu --action test
```

### Step 3: Build Release Binaries
```bash
.agents/skills/omg-release/scripts/build-release.sh <OMG_VERSION>
```
Output placed under `.release-build/<OMG_VERSION>/`.

### Step 4: Sign & Package DMGs
```bash
OMG_SIGNING_IDENTITY=- \
PREVIOUS_TAG=v<PREVIOUS_VERSION> \
.agents/skills/omg-release/scripts/package-release.sh <OMG_VERSION>
```
Produces `arm64`, `x86_64`, and `universal` DMGs, `SHA256SUMS.txt`, and `appcast.xml`.

### Step 5: Commit, Tag & Push
```bash
git add macos/Ghostty.xcodeproj/project.pbxproj macos/Tests/Helpers/OhMyGhosttyVersionTests.swift docs/RELEASE_NOTES_<OMG_VERSION>.md
git commit -m "release: prepare OMG <OMG_VERSION>"
git push origin main

git tag -a "v<OMG_VERSION>" -m "OMG <OMG_VERSION> · Ghostty 1.3.2-dev"
git push origin "refs/tags/v<OMG_VERSION>"
```

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
- Architectures built (`arm64`, `x86_64`, `universal`).
- Signing (`ad-hoc` or `Developer ID`) and notarization status.
- GitHub Release URL and list of 5 uploaded assets.
