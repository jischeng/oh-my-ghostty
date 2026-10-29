# This checkout's development application

Development from the `omg-workspace` checkout installs to and replaces
**/Applications/OMG Dev.app**. Use:

```sh
.agents/skills/omg-release/scripts/install-dev.sh
```

The installer builds a Debug Swift app with ReleaseFast core, signs with a
persistent development identity, validates it, replaces OMG Dev, and launches it.
Commit intended changes first. No remote push or release is implied.

- Bundle ID: `com.jischeng.omg.debug`
- Build: `macos/build/Debug/OMG.app`
- Settings: `~/.config/oh-my-ghostty-dev/settings.json`
- Application Support: `~/Library/Application Support/OMG Dev/`
- Core session channel: `debug`

Keep `/Applications/OMG.app` untouched. Existing OMG Dev Workspace data remains
separate and is not automatically migrated into OMG Dev.
