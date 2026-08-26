# OMG 0.3.0

OMG 0.3.0 builds on Ghostty 1.3.2-dev (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and supersedes 0.2.1.

## Highlights

- Adds English and Simplified Chinese Settings localization with a live language picker that defaults to the macOS preferred language; app-owned static macOS menus switch with the same setting.
- Expands manifest-driven Agent integration to Codex, Claude Code, Pi, Qoder CLI, Reasonix, OMP, OpenCode, Amp, Antigravity, Cline, Copilot, Crush, Cursor Agent, Droid, Grok, Hermes, Kimi, and Qwen Code.
- Gives every Agent explicit Install, Update, and Remove controls. Detector-only Agents use bounded Host-owned markers rather than pretending unsupported vendor hooks exist.
- Upgrades Agent hooks to v5 with a `/dev/tty` fallback for more reliable remote hook delivery while preserving unrelated user hooks and configuration.
- Keeps Agent identity on the focused pane and background attention/error/done in the trailing slot. Normal completion remains visible on the currently focused Tab; an unexpected process loss while working becomes an error instead of disappearing. Only mouse click or keyboard input in the owning focused terminal clears done/error.
- Restores active local and SSH Agent sessions using validated, allowlisted conversation IDs and exact original OpenSSH argv when the Agent supports it.
- Generalizes typed SSH lifecycle, cloud identity, remote cwd, Files, and split replay to Fish, bash, and zsh, including ProxyJump/custom-port aliases such as multi-hop hosts.
- Keeps command-D SSH splits alive after network disconnect by returning the split to the user's local shell rather than terminating the pane.
- Pastes an image-only clipboard as a private temporary PNG path for Agent tools. The directory is mode 0700, files are mode 0600, symlink redirects are rejected, and files older than seven days are pruned.
- Refines Vertical Tabs and Inspector interaction: focused-pane identity, full-row hover/click hit targets, smooth frame-boundary Sidebar resizing, and correctly centered collapsed Inspector controls.
- Separates stable and development mutable state so local development only replaces `OMG Dev.app` and does not rewrite stable settings, plugins, restoration, or SSH replay data.

## Compatibility

- Horizontal Tabs remain Ghostty's native implementation and share the canonical `NSWindowTabGroup` order and lifecycle with Vertical Tabs.
- Existing Terminal restoration states v5-v8 remain readable; v9 carries optional typed Agent resume descriptors.
- Existing v3/v4 Agent hooks are reported as Update Required. Re-run the exported SSH installer in remote accounts to install v5 hooks.
- Agent hooks, detector markers, SSH replay descriptors, and image paste files remain bounded and owner-scoped; no private keys, passwords, tokens, or arbitrary remote commands are stored.
- SSH/Pi long-scrollback performance tracing remains a follow-up investigation; this release does not claim to solve remote output burst or CAMetalLayer frame-pacing issues.

## Verification

- The macOS app-hosted suite covers focused completion/error acknowledgement, Agent interruption, hook v5 upgrade, SSH replay, image paste security, full-row tabs, restoration, and local/SSH/Pi scroll-dispatch benchmarks.
- SwiftLint, OMG documentation/schema checks, Zig formatting/tests, app architecture/signature checks, native arm64 execution, Rosetta x86_64 execution, and mounted-DMG launch checks are release gates.

## Distribution status

The attached architecture-specific DMGs are locally ad-hoc signed and are not Apple-notarized unless the Release assets explicitly state otherwise. They are not represented as Developer ID/notarized builds without successful `codesign`, `notarytool`, and stapler evidence.
