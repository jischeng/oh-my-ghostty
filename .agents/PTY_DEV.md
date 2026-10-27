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
For the experimental VPS session transport, run `bash session-runtime/test-vps-jump.sh`
after installation. Its single-host runtime and current limitations are documented
in `session-runtime/HOST_RUNTIME.md`.
