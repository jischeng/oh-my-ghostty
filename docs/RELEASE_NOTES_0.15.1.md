# OMG 0.15.1 · Ghostty 1.3.2-dev

OMG 0.15.1 is a bug-fix release for the remote `omg +ssh` bootstrap.

## Changes since 0.15.0

- **Remote SSH bootstrap quoting** — OpenSSH delivers its remote
  command through the user's login shell, and Fish interprets
  backslashes inside single quotes unlike POSIX sh. The generated
  `+ssh` bootstrap now escapes both apostrophes and backslashes
  outside quoted segments so Fish, bash, and zsh login shells deliver
  identical script bytes to `/bin/sh -c`. Regression coverage executes
  the complete generated bootstrap through all three login shells, and
  the dev installer now verifies the linked binary's bootstrap against
  current source before installing.

## Ghostty core

- Version: **1.3.2-dev**
- Revision: `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`

## Signing and notarization

This release is **ad-hoc signed** and has **not been notarized** by Apple.
macOS Gatekeeper will show a warning on first launch; open the app via
System Settings → Privacy & Security or right-click → Open to proceed.

## Installation

Download the DMG for your architecture:

- `OMG-0.15.1-macos-arm64.dmg` — Apple Silicon
- `OMG-0.15.1-macos-x86_64.dmg` — Intel (binary architecture verified;
  launch under Rosetta 2 not tested on the build machine)
- `OMG-0.15.1-macos-universal.dmg` — universal (used by the built-in
  updater)

Verify checksums with `SHA256SUMS.txt` before installing.
