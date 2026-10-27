# OMG Dev PTY

Use `/Applications/OMG Dev PTY.app` for Session Runtime development and testing.
After committing intended changes, install with `dist/macos/install-pty-dev.sh`.
The installer builds from a clean HEAD, signs with a persistent development
identity, disables updater/URL registration, and only replaces the PTY app.

- Bundle ID: `com.jischeng.omg.debug.pty`
- Settings: `~/.config/oh-my-ghostty-dev-pty/settings.json`
- Application Support: `~/Library/Application Support/OMG Dev PTY/`
- Session channel: `debug-pty`
- Build output: `macos/build-pty/Debug/OMG.app`

The PTY app is independent from OMG Dev, OMG Dev Workspace and release OMG.
Open the app normally. New windows are local; persistent SSH sessions are created
through Settings → Shell & Sessions → Session Runtime. Never add a fixed-host
launcher or global socket environment override. Current acceptance steps are in
`session-runtime/TEST_RELEASE_PATH.md`.
