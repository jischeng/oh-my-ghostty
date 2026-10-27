# This checkout's development application

User instruction: development from the `omg-workspace` checkout installs to and
subsequently replaces **/Applications/OMG Dev Workspace.app**. Use:

```sh
bash dist/macos/install-workspace-dev.sh
```

Do not use the ordinary `install-dev.sh` for this checkout. The dedicated installer
builds a Debug Swift app with ReleaseFast core, signs with a persistent development
identity, validates it, replaces only this app, and launches it. Commit intended
changes first. No remote push or release is implied.

- Bundle ID: `com.jischeng.omg.debug.workspace`
- Build: `macos/build-workspace/Debug/OMG.app`
- Settings: `~/.config/oh-my-ghostty-dev-workspace/settings.json`
- Application Support: `~/Library/Application Support/OMG Dev Workspace/`
- Core session channel: `debug-workspace`

Keep `/Applications/OMG.app` and `/Applications/OMG Dev.app` untouched.
