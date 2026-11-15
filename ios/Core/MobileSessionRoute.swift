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

    public struct CatalogCandidate: Equatable, Sendable {
        public let id: String
        public let generation: String
        public let ended: String?

        public init(id: String, generation: String, ended: String?) {
            self.id = id
            self.generation = generation
            self.ended = ended
        }
    }

    public enum AttachmentResolution: Equatable, Sendable {
        case alreadyAttached
        case keepInFlight
        case open(index: Int, adoptedGeneration: String?)
        case notRunning
    }

    /// Resolves how `OMGSession.onSessions` should react to a fresh `'L'` session catalogue:
    /// - Ignores `'L'` once a snapshot `'S'` is already applied (`isAttached == true`).
    /// - Keeps an in-flight `'U'` untouched when `inFlightOpenGeneration` already matches
    ///   the current attachable generation on normal reconnects.
    /// - Adopts a newer valid generation for the same `endpoint + sessionID` while
    ///   `!isAttached` so a socket drop after `omgd` resurrects a `"lost"` session on disk
    ///   (before `'J'` reaches iOS) attaches cleanly instead of failing with stale `oldGen`.
    public func resolveAttachment(
        currentGeneration: String,
        isAttached: Bool,
        inFlightOpenGeneration: String?,
        candidates: [CatalogCandidate]
    ) -> AttachmentResolution {
        guard !isAttached else { return .alreadyAttached }
        if let exactIndex = candidates.firstIndex(where: {
            $0.id == sessionID
                && $0.generation == currentGeneration
                && Self.isAttachableEndedState($0.ended)
        }) {
            if inFlightOpenGeneration == currentGeneration {
                return .keepInFlight
            }
            return .open(index: exactIndex, adoptedGeneration: nil)
        }
        if let resurrectedIndex = candidates.firstIndex(where: {
            $0.id == sessionID
                && Self.isAttachableEndedState($0.ended)
                && MobileSessionRoute(replacingGeneration($0.generation)) != nil
        }) {
            let nextGeneration = candidates[resurrectedIndex].generation
            if inFlightOpenGeneration == nextGeneration {
                return .keepInFlight
            }
            return .open(
                index: resurrectedIndex,
                adoptedGeneration: nextGeneration == currentGeneration ? nil : nextGeneration
            )
        }
        return .notRunning
    }
}

/// Bounded LRU keep-alive cache for parked terminal screens keyed by session route,
/// supporting in-place route re-keying when a paused session resurrects with a new generation.
public struct MobileRecentTerminalCache<Screen: AnyObject> {
    public let maxCount: Int
    private var screensByKey: [String: Screen] = [:]
    private var orderedKeys: [String] = []

    public init(maxCount: Int = 2) {
        self.maxCount = max(1, maxCount)
    }

    public var isEmpty: Bool {
        screensByKey.isEmpty
    }

    public var keys: [String] {
        orderedKeys
    }

    public var entries: [(key: String, screen: Screen)] {
        orderedKeys.compactMap { key in
            screensByKey[key].map { (key, $0) }
        }
    }

    public func screen(forKey key: String) -> Screen? {
        screensByKey[key]
    }

    public func key(for screen: Screen) -> String? {
        orderedKeys.first { screensByKey[$0] === screen }
    }

    public func contains(_ screen: Screen) -> Bool {
        screensByKey.values.contains { $0 === screen }
    }

    @discardableResult
    public mutating func recordOpen(_ screen: Screen, forKey key: String) -> [Screen] {
        var evicted: [Screen] = []
        if let previous = screensByKey[key], previous !== screen {
            evicted.append(previous)
        }
        // Ensure a single screen instance is never indexed under two distinct keys.
        for existingKey in orderedKeys where existingKey != key && screensByKey[existingKey] === screen {
            screensByKey.removeValue(forKey: existingKey)
        }
        orderedKeys.removeAll { $0 == key || screensByKey[$0] == nil }
        screensByKey[key] = screen
        orderedKeys.append(key)
        while orderedKeys.count > maxCount {
            let coldestKey = orderedKeys.removeFirst()
            if let cold = screensByKey.removeValue(forKey: coldestKey), cold !== screen {
                evicted.append(cold)
            }
        }
        return evicted
    }

    public mutating func adoptResurrectedGeneration(
        from oldKey: String,
        to newKey: String,
        activeScreen: Screen?
    ) -> (rekeyed: Screen?, evicted: [Screen]) {
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else {
            return (screensByKey[newKey], [])
        }
        guard let migrated = screensByKey.removeValue(forKey: oldKey) else {
            return (screensByKey[newKey], [])
        }
        var evicted: [Screen] = []
        if let existingNew = screensByKey[newKey], existingNew !== migrated {
            if existingNew === activeScreen {
                orderedKeys.removeAll { $0 == oldKey }
                evicted.append(migrated)
                return (existingNew, evicted)
            }
            evicted.append(existingNew)
            orderedKeys.removeAll { $0 == newKey }
        }
        screensByKey[newKey] = migrated
        if let oldIndex = orderedKeys.firstIndex(of: oldKey) {
            orderedKeys[oldIndex] = newKey
            var seen = false
            orderedKeys.removeAll { candidate in
                guard candidate == newKey else { return false }
                if !seen {
                    seen = true
                    return false
                }
                return true
            }
        } else {
            orderedKeys.removeAll { $0 == newKey }
            orderedKeys.append(newKey)
        }
        return (migrated, evicted)
    }

    public mutating func remove(screen: Screen) {
        let matchingKeys = orderedKeys.filter { screensByKey[$0] === screen }
        for key in matchingKeys {
            screensByKey.removeValue(forKey: key)
        }
        orderedKeys.removeAll { matchingKeys.contains($0) }
    }

    public mutating func removeAll() -> [Screen] {
        let screens = orderedKeys.compactMap { screensByKey[$0] }
        screensByKey.removeAll()
        orderedKeys.removeAll()
        return screens
    }

    public mutating func evictInactive(keeping activeScreen: Screen?) -> [Screen] {
        let survivorKey = activeScreen.flatMap { active in
            orderedKeys.first { screensByKey[$0] === active }
        }
        var evicted: [Screen] = []
        for key in orderedKeys where key != survivorKey {
            if let screen = screensByKey.removeValue(forKey: key) {
                evicted.append(screen)
            }
        }
        orderedKeys = survivorKey.map { [$0] } ?? []
        return evicted
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
