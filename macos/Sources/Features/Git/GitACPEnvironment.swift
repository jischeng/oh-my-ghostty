import Foundation

/// Agent-owned session databases live beneath OMG's 30-day directory. Only known
/// credential/provider files are linked from the user's home, never history trees.
struct GitACPEnvironment {
    static func prepare(agent: GitCommitAgent, directory: URL, base: [String: String]) throws -> [String: String] {
        let manager = FileManager.default
        let realHome = URL(fileURLWithPath: base["HOME"] ?? manager.homeDirectoryForCurrentUser.path)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func link(_ source: URL, _ relative: String) throws {
            guard manager.fileExists(atPath: source.path) else { return }
            let target = home.appendingPathComponent(relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.createSymbolicLink(at: target, withDestinationURL: source)
        }
        var env: [String: String] = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path, "NO_COLOR": "1"]
        switch agent {
        case .pi:
            let original = URL(fileURLWithPath: base["PI_CODING_AGENT_DIR"] ?? realHome.appendingPathComponent(".pi/agent").path)
            for name in ["auth.json", "models.json"] { try link(original.appendingPathComponent(name), ".pi/agent/" + name) }
            env["PI_CODING_AGENT_DIR"] = home.appendingPathComponent(".pi/agent").path
            env["PI_CODING_AGENT_SESSION_DIR"] = directory.appendingPathComponent("pi-sessions").path
            env["PI_OFFLINE"] = "1"
            // pi-acp only exposes a Pi executable override, not extra argv.
            let wrapper = directory.appendingPathComponent("pi-commit")
            try "#!/bin/sh\nexec pi --no-tools --no-extensions --no-skills --no-context-files --no-prompt-templates --no-approve \"$@\"\n"
                .write(to: wrapper, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            env["PI_ACP_PI_COMMAND"] = wrapper.path
        case .claude:
            let original = URL(fileURLWithPath: base["CLAUDE_CONFIG_DIR"] ?? realHome.appendingPathComponent(".claude").path)
            for name in [".credentials.json", "settings.json"] { try link(original.appendingPathComponent(name), ".claude/" + name) }
            try link(realHome.appendingPathComponent(".claude.json"), ".claude.json")
            env["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude").path
            env["CLAUDE_AGENT_LOGS"] = directory.appendingPathComponent("logs").path
        case .codex:
            let original = URL(fileURLWithPath: base["CODEX_HOME"] ?? realHome.appendingPathComponent(".codex").path)
            for name in ["auth.json", "config.toml"] { try link(original.appendingPathComponent(name), ".codex/" + name) }
            env["CODEX_HOME"] = home.appendingPathComponent(".codex").path
            env["INITIAL_AGENT_MODE"] = "read-only"
            env["CODEX_CONFIG"] = "{\"approval_policy\":\"never\",\"sandbox_mode\":\"read-only\",\"features\":{\"shell_tool\":false,\"unified_exec\":false,\"multi_agent\":false},\"web_search\":\"disabled\"}"
        case .opencode:
            let data = URL(fileURLWithPath: base["XDG_DATA_HOME"] ?? realHome.appendingPathComponent(".local/share").path)
            try link(data.appendingPathComponent("opencode/auth.json"), ".local/share/opencode/auth.json")
            // Provider credentials remain available, but do not load user plugins:
            // a fresh config home can otherwise bootstrap npm dependencies on every session.
            let configDirectory = home.appendingPathComponent(".config/opencode")
            try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            env["OPENCODE_CONFIG_DIR"] = configDirectory.path
            env["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
            env["OPENCODE_DISABLE_DEFAULT_PLUGINS"] = "true"
            env["OPENCODE_DISABLE_CLAUDE_CODE"] = "true"
            env["OPENCODE_CONFIG_CONTENT"] = "{\"permission\":\"deny\",\"share\":\"disabled\",\"autoupdate\":false}"
        }
        return env
    }
}
