# OMG 0.5.1

OMG 0.5.1 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and fixes Pi/OMP Agent restoration regressions found in the 0.5.0 SSH resume work.

## Highlights

- Records Pi-compatible session project directories in typed OSC 3008 Agent signals via `omg_cwd`, sourced from `sessionManager.getCwd()`.
- Restores local and SSH Pi/OMP sessions from the directory that owns the conversation instead of the pane shell's last cwd, avoiding wrong-project `pi --session-id` lookups that create empty replacement sessions.
- Keeps older Agent hooks compatible by falling back to the pane cwd when `omg_cwd` is absent.
- Documents and tests the new Agent status wire metadata.
- Documents that release artifacts must verify a ReleaseFast GhosttyKit core, while Debug GhosttyKit remains available for explicit Zig terminal-core debugging rather than routine acceptance testing.

## Verification

- `AgentStatusPluginTests`, `VerticalTabsTests`, `TerminalRestorableTests`, and `OhMyGhosttyVersionTests` pass under the Debug macOS app scheme.
- `python3 dist/check_omg_docs.py` passes.
- `/Applications/OMG Dev.app` was rebuilt, ad-hoc signed, launch-verified, and reports GhosttyKit build mode `.ReleaseFast`; `/Applications/OMG.app` 0.5.0 was confirmed to have seen the same stall because that local install also reported `.Debug`.
- A live SSH restore of the `cloud` Pi session in `/home/chengjisheng/code/trading/quant-research-platform` resumed the intended session with low CPU instead of hanging the app.
- The universal Sparkle enclosure advances to bundle version `8`.

## Distribution status

The 0.5.1 patch release is prepared as source metadata and an installed local development build. Public DMG artifacts still require the normal signing, packaging, notarization, and ReleaseFast-core verification gate before distribution.
