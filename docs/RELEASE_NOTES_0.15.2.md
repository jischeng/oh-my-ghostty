# OMG 0.15.2 · Ghostty 1.3.2-dev

OMG 0.15.2 brings AI-generated commit messages, Git branch
integration operations, annotated tags, and a theme-consistent
Settings window and Git dialogs to the terminal.

## Version policy note

`docs/RELEASING.md` reserves a patch bump for bug fixes only and
requires a minor bump when a release contains new user-visible
features. This release ships features under a patch number by
explicit maintainer decision. The deviation is recorded here so
update ordering, the tag, and the changelog stay unambiguous;
`CURRENT_PROJECT_VERSION` still advances monotonically (`30` → `31`)
for Sparkle.

## New features

- **AI commit messages over ACP** — the changes composer's Generate
  button now offers four agents (Claude Code, Pi, Codex, OpenCode),
  all driven through the Agent Client Protocol instead of
  non-interactive CLI calls. Routes are an ordered
  `git.commitAI.routes` list tried top to bottom until one
  succeeds, with an optional shared instruction in
  `git.commitAI.prompt`. Generation reads only the staged patch,
  runs in a throwaway non-repository working directory with tools
  and permissions denied, never overwrites a draft you edited while
  it ran, and keeps agent state in OMG-owned session directories that
  expire after 30 days instead of touching your global agent history.
  Requires the corresponding ACP adapters to be installed and signed
  in; a missing adapter fails that route rather than silently
  substituting a default model.
- **Branch integration operations** — Merge, Rebase, and Cherry-pick
  with a target-branch picker (merge commits also ask for a mainline
  parent), plus **Merge into…** in the pull/push menu for PR/MR
  creation. Plans capture the source and target commits, revalidate
  before mutating, require a clean worktree, and refuse an
  in-progress operation. These actions never stash, reset, force-push,
  or auto-resolve conflicts, and the target stays checked out after
  success or failure. Merge and Cherry-pick dialogs can generate their
  message from the exact operation diff.
- **Annotated tags and source pushes** — commit context menus gain
  **New Tag…**, which suggests the next minor version from the
  branch's merged tag history (falling back to a deterministic bump),
  validates the name against Git's rules, and rejects duplicates before
  writing. Tags travel with `--follow-tags` on push, push-to, and
  PR/MR source pushes. **Merge into…** remembers the target branch per
  repository and can push an out-of-date source branch — never the
  target — only after explicit confirmation.
- **Forge browser links** — commit and file context menus expose
  Open in Browser for GitHub and GitLab-compatible remotes,
  normalizing HTTPS, SSH, and SCP origins without embedding
  credentials. PR/MR creation shells out to local `gh`/`glab` with
  explicit branches and only after both tips match `ls-remote`.
- **Split settings panes** — Git, SSH, and Agent Integration each get
  their own sidebar entry instead of sharing one General page.

## Fixes

- **Settings, dialogs, and chrome follow the terminal theme** —
  auxiliary windows previously mixed system window, titlebar, and
  grouped-form backgrounds with the theme, and on translucent windows
  inherited a near-invisible blur backing that rendered them as a
  transparent wash. They now derive one palette from the configured
  theme (background, foreground, and a blended sidebar tone), stay
  opaque regardless of terminal translucency, and re-derive live when
  the configuration changes. Themed auxiliary windows keep their controls
  on the terminal palette through the SwiftUI color-scheme environment
  instead of claiming the window appearance, so the explicit window-theme
  override keeps working as before.
  Translucent chrome keeps the configured opacity on the raw theme
  color, unchanged from 0.15.1. Text and controls
  keep semantic primary and accent colors so secondary and disabled
  contrast survive; system-owned alerts and file choosers stay native.
- **Appearance feedback loop** — a reported appearance change could
  synchronously reload a conditional theme and write the appearance
  back again, saturating the main thread while Settings was open.
  Duplicate light/dark reports are now filtered before reaching
  libghostty.
- **Stale agent indicator** — switching a pane from one agent to
  another (for example Pi to Antigravity) could keep showing the
  exited agent because its interruption activity stayed current. A newly
  detected agent now supersedes older terminated activity on the same
  surface.
- **SSH working directory on Fish hosts** — restoring a session with a
  remote working directory corrupted the command line through nested
  single-quote escaping when the login shell was Fish. The directory
  now passes as `OMG_REMOTE_CWD`, so Fish, bash, and zsh deliver
  identical bytes to `/bin/sh -c`.
- **Large-patch message generation** — when an operation's diff
  exceeded the 200 KB context budget, generation failed outright. It
  now degrades to Git's bounded diffstat and then shortstat, states
  that the patch was omitted, and instructs the model not to infer
  details from file names or line counts. Other Git errors still
  surface.

## Ghostty core

Unchanged since 0.15.1.

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by
Apple — no Developer ID Application identity or notarization profile is
configured on the build machine. macOS Gatekeeper will warn on first
launch; open the app via System Settings → Privacy & Security or
right-click → Open to proceed.

## Validation

- SwiftLint `--strict` over `macos` with zero violations.
- `zig fmt --check`, `docs/settings/schema.json`, `dist/check_omg_docs.py`,
  `plutil -lint`, and `ibtool` on `MainMenu.xib`.
- Full app-hosted `GhosttyTests` suite via `macos/build.nu --action test`
  (`GhosttyUITests` are skipped by the CLI wrapper, which requires
  interactive automation permissions).
- Intel evidence is limited: Rosetta 2 is **not installed** on the build
  machine, so each `x86_64` binary was verified by its Mach-O slice and
  `.ReleaseFast` marker only. It was **not launched**, on hardware or
  under emulation.

## Installation

Download the DMG for your architecture:

- `OMG-0.15.2-macos-arm64.dmg` — Apple Silicon
- `OMG-0.15.2-macos-x86_64.dmg` — Intel (architecture and `.ReleaseFast`
  verified; **not launched** — Rosetta 2 is unavailable on the build
  machine, so Intel behavior is untested here)
- `OMG-0.15.2-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
