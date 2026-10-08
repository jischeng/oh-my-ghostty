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

1. **Testing strategy by changed modules, not release type**:
   - For patch/minor/major releases, preview then execute `macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>"`. This includes all release commits and worktree changes, plus direct module dependents and version smoke coverage.
   - Shared host/core, build/test infrastructure, or unmapped changes conservatively select all routine Swift suites. Explicit broad sweeps remain available with `--test-modules all`; do not force them solely because of a minor bump.
   - `.interactiveDesktop` native drag/focus tests are optional, excluded by default, and reported **NOT RUN**, not passed. After relevant native tab/drag/focus/event changes, schedule them explicitly with `--include-desktop-tests` on an unlocked foreground desktop. XCUITest stays excluded.
   - Swift selection does not replace affected Zig/Python/shell or artifact checks. See `docs/TESTING.md`.
2. **Build and test strictly serially**: Never run multiple builds or tests concurrently (`build.db: database is locked`).
3. **Shell compatibility**: Pi shell may be Fish. Wrap multiline shell commands with `/bin/bash -lc '...'`.
4. **GitHub CLI target**: Always pass `--repo jischeng/oh-my-ghostty` when running `gh release create` (`upstream` points to `ghostty-org/ghostty`).
5. **Release signing**: Use persistent self-signing (`OMG_SIGNING_MODE=self-signed`) with the same pinned certificate on every release. Source the private `signing.env`; initialize it once with `python3 dist/macos/omg_signing.py create <private-directory>`. Never regenerate an existing identity or fall back to ad-hoc for public releases. Apps and DMGs are not notarized; Developer ID, paid membership, and notarization profiles are not prerequisites. Record persistent self-signing, no notarization, first-launch Gatekeeper behavior, and the possible one-time authorization on migration. Full TCC upgrade experiments are not a release prerequisite and must be reported NOT RUN when omitted. Sparkle EdDSA signing remains required.
6. **Rosetta**: If Rosetta 2 is not installed, the script verifies the `x86_64` Mach-O slice without launching it. Record the actual architecture checks and any unperformed launch checks in release notes.

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

# Signing policy contracts (separate from app-hosted Swift tests)
python3 -m unittest discover -s dist -p 'test_omg_signing.py'
python3 -m unittest discover -s dist -p 'test_omg_keychain.py'

# 2. Swift tests for all commits since the previous published OMG version
macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>" --test-plan-only
macos/build.nu --action test --changed-since "v<PREVIOUS_VERSION>"

# Explicit modules or an intentional broad routine sweep
# macos/build.nu --action test --test-modules git,editor
# macos/build.nu --action test --test-modules all

# Optional real native drag regression after relevant changes; desktop must be unlocked
# macos/build.nu --action test --only-testing GhosttyTests/VerticalTabMouseTests --include-desktop-tests

# Selector changes need offline contract tests too
python3 -m unittest discover -s dist -p 'test_omg_test_plan.py'
```

### Step 3: Build Release Binaries
```bash
.agents/skills/omg-release/scripts/build-release.sh <OMG_VERSION>
```
Output placed under `.release-build/<OMG_VERSION>/`.

### Step 4: Sign & Package DMGs
```bash
source "<private-signing-directory>/signing.env"
# One-time interactive setup (not required on every release):
# python3 dist/macos/omg_signing.py store-password
# The signing script automatically unlocks from the dedicated login-Keychain item.
# If access fails, stop; never read/print credentials or fall back to ad-hoc.
# After the first persistent release, preserve its app and set:
# export OMG_PREVIOUS_SIGNED_APP="<previous-persistent-release>/OMG.app"
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
- Persistent certificate/DR verification, launch-probe evidence, and explicit not-notarized status.
- Prior persistent app compatibility if supplied; report migration/omitted desktop TCC verification honestly.
- GitHub Release URL and list of 5 uploaded assets.
