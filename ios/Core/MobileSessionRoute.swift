import Foundation

/// Opaque roster identities bind a UI row to one endpoint and one generation.
public struct MobileSessionRoute: Equatable {
    public let endpointID: String
    public let sessionID: String
    public let generation: String

    public init?(_ value: String) {
        let fields = value.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 3, Self.hex(fields[0], count: 64),
              UUID(uuidString: String(fields[1])) != nil,
              Self.hex(fields[2], count: 32) else { return nil }
        endpointID = String(fields[0])
        sessionID = String(fields[1])
        generation = String(fields[2])
    }

    private static func hex(_ text: Substring, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    /// Post-reboot paused local sessions (`ended == "lost"`) remain attachable because
    /// `omgd` resurrects them transparently when `b'U'` connects.
    public static func isAttachableEndedState(_ ended: String?) -> Bool {
        ended == nil || ended == "lost"
    }

    public func replacingGeneration(_ nextGeneration: String) -> String {
        "\(endpointID)/\(sessionID)/\(nextGeneration)"
    }
}

/// Canonical mobile agent metadata matching `session-runtime/src/agents.rs`.
public struct MobileAgentDescriptor: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let vectorIcon: String?
    public let assetIcon: String?
    public let aliases: [String]

    public init(
        id: String,
        displayName: String,
        vectorIcon: String? = nil,
        assetIcon: String? = nil,
        aliases: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.vectorIcon = vectorIcon
        self.assetIcon = assetIcon
        self.aliases = aliases
    }
}

/// Resolves iOS session and project icons so SSH shells and SSH project folders
/// display the cloud mark matching macOS `PaneSessionContext.tabIconSystemName`,
/// and all 19 OMG coding agents resolve their canonical display names and marks.
public enum MobileSessionIcon {
    /// All 18 manifest-backed OMG coding agents plus `aider`.
    public static let allAgents: [MobileAgentDescriptor] = [
        .init(id: "codex", displayName: "Codex", vectorIcon: "codex", aliases: ["openai-codex"]),
        .init(id: "claude", displayName: "Claude Code", vectorIcon: "claude", aliases: ["claude-code"]),
        .init(id: "pi", displayName: "Pi", assetIcon: "pi-favicon", aliases: ["pi-coding-agent"]),
        .init(
            id: "antigravity",
            displayName: "Antigravity",
            assetIcon: "antigravity-favicon",
            aliases: ["agy", "jetski", "jetski-cli", "antigravity-cli", "gemini"]
        ),
        .init(id: "opencode", displayName: "OpenCode", assetIcon: "opencode-favicon"),
        .init(id: "cursor", displayName: "Cursor Agent", assetIcon: "cursor-favicon", aliases: ["cursor-agent"]),
        .init(
            id: "copilot",
            displayName: "Copilot",
            assetIcon: "copilot-favicon",
            aliases: ["github-copilot-cli", "gh-copilot"]
        ),
        .init(id: "droid", displayName: "Droid", assetIcon: "droid-favicon"),
        .init(id: "grok", displayName: "Grok", vectorIcon: "grok"),
        .init(id: "qwen", displayName: "Qwen Code", assetIcon: "qwen-favicon", aliases: ["qwen-code"]),
        .init(id: "amp", displayName: "Amp", assetIcon: "amp-favicon"),
        .init(id: "cline", displayName: "Cline", assetIcon: "cline-favicon"),
        .init(id: "kimi", displayName: "Kimi", assetIcon: "kimi-favicon", aliases: ["kimi-code"]),
        .init(id: "hermes", displayName: "Hermes", assetIcon: "hermes-favicon"),
        .init(id: "crush", displayName: "Crush", assetIcon: "crush-favicon"),
        .init(id: "qoder", displayName: "Qoder CLI", vectorIcon: "qoder", aliases: ["qodercli"]),
        .init(id: "reasonix", displayName: "Reasonix", vectorIcon: "reasonix"),
        .init(id: "omp", displayName: "OMP", assetIcon: "omp-favicon", aliases: ["oh-my-pi"]),
        .init(id: "aider", displayName: "Aider", vectorIcon: "aider", aliases: ["aider-chat"]),
    ]

    public static func agentDescriptor(for raw: String) -> MobileAgentDescriptor? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return allAgents.first { $0.id == normalized || $0.aliases.contains(normalized) }
    }

    public static func normalizeAgentID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let descriptor = agentDescriptor(for: trimmed) {
            return descriptor.id
        }
        let lowered = trimmed.lowercased()
        guard lowered.utf8.count <= 32,
              lowered.utf8.allSatisfy({
                  (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46
              }) else { return nil }
        return lowered
    }

    public static func fallbackSystemSymbol(agent: String, remoteHost: String?) -> String {
        guard agent == "terminal" else { return "sparkles" }
        let isRemote = !(remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return isRemote ? "cloud" : "terminal"
    }

    public static func isRemoteSSHProject(deviceAlias: String?, sessionRemoteHosts: [String?]) -> Bool {
        if let alias = deviceAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return true
        }
        guard !sessionRemoteHosts.isEmpty else { return false }
        return sessionRemoteHosts.allSatisfy {
            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}
