# OMG 0.5.2

OMG 0.5.2 builds on the unchanged Ghostty 1.3.2-dev base (`9ae02a326f62bd88f7f5508cf1807c67e7775cb5`) and fixes local shell initialization after an SSH replay split disconnects.

## Highlights

- Starts the local survival shell as a login shell after a replayed SSH connection exits.
- Restores login-only fish and zsh prompt setup, including Starship configurations that were previously missing after returning from SSH.
- Keeps the existing validated SSH argv replay, remote cwd restoration, and post-disconnect pane survival behavior unchanged.
- Documents and tests the login-shell transition in the SSH replay lifecycle.

## Verification

- The macOS app-hosted test suite passes, including the SSH split survival and version metadata coverage.
- SwiftLint and `python3 dist/check_omg_docs.py` pass.
- Release artifacts target arm64, x86_64, and universal macOS applications, with the x86_64 path validated under Rosetta 2.
- The universal Sparkle enclosure advances to bundle version `9`.

## Distribution status

The attached arm64, x86_64, and universal DMGs are locally ad-hoc signed and are not Apple-notarized. Sparkle enclosure integrity uses the dedicated OMG EdDSA signature; this does not replace Apple Developer ID signing or notarization.
