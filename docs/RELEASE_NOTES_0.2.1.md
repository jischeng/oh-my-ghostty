# OMG 0.2.1

OMG 0.2.1 builds on Ghostty 1.3.2-dev (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and supersedes 0.2.0.

## Fix

- Forces existing Agent hook integrations to upgrade to v4 so question prompts and permission approvals carry their distinct attention subtype instead of remaining on an older generic-attention command.

## Highlights

- Restores open windows, canonical tab order, split layouts, working directories, and active local or SSH Agent sessions with validated conversation IDs.
- Adds manifest-driven Agent integration for Codex, Claude Code, Pi, Qoder CLI, Reasonix, OMP, OpenCode, Amp, Antigravity, Cline, Copilot, Crush, Cursor Agent, Droid, Grok, Hermes, Kimi, and Qwen Code.
- Supports nested/flat JSON hooks, Pi-compatible and OpenCode/Amp plugins, marker-delimited Kimi TOML, Cline event scripts, and bounded screen-status fallback without removing unrelated user hooks.
- Makes Vertical Tab identity follow the focused pane while preserving background attention, error, and completion indicators at the row edge; question prompts and permission approvals use distinct icons.
- Uses correctly sized brand icons and a time-driven indeterminate working spinner.
- Defaults Tab path presentation to Current Folder and keeps local/SSH Agent titles consistent (`folder` vs `host folder`).
- Keeps the Inspector titlebar toggle aligned with macOS traffic lights in both expanded and collapsed states.
- Replays original OpenSSH argv and cwd for SSH splits/restoration; remote Agent resume accepts only typed allowlisted Agent/session options.

## Compatibility

- Horizontal Tabs remain Ghostty's native implementation.
- Existing Terminal restoration states v5-v8 remain readable; v9 adds optional typed Agent resume descriptors.
- Exact conversation resume is used when the Agent exposes a verified resume mechanism. Agents without one restart fresh in the same working directory.
- Agent hooks remain opt-in through Settings and preserve non-OMG entries.

## Distribution status

The attached architecture-specific DMGs are local ad-hoc builds unless the Release assets explicitly state that Developer ID signing and Apple notarization were performed. They are not represented as notarized builds without successful `codesign`, `notarytool`, and stapler evidence.
