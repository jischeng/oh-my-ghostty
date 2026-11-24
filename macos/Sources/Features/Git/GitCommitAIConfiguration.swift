import Foundation

/// All four agents use the same ACP transport; adapters must already be installed.
enum GitCommitAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, pi, codex, opencode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .pi: "Pi"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
    var canDiscoverModels: Bool { true }
    var acpCommand: [String] {
        switch self {
        case .claude: ["claude-agent-acp"]
        case .pi: ["pi-acp"]
        case .codex: ["codex-acp"]
        case .opencode: ["opencode", "acp"]
        }
    }
}

/// One entry of the ordered fallback list for commit, tag and PR text: a model of an
/// installed agent (reached over ACP) or of an API connection (reached over HTTP).
struct GitCommitAIRoute: Equatable, Identifiable, Sendable {
    enum Target: Equatable, Sendable {
        case agent(GitCommitAgent)
        case provider(UUID)
    }

    var id: UUID = UUID()
    let target: Target
    let model: String

    init(id: UUID = UUID(), target: Target, model: String) {
        self.id = id
        self.target = target
        self.model = model
    }

    init(id: UUID = UUID(), agent: GitCommitAgent, model: String) {
        self.init(id: id, target: .agent(agent), model: model)
    }

    init(id: UUID = UUID(), provider: UUID, model: String) {
        self.init(id: id, target: .provider(provider), model: model)
    }

    /// The agent of an ACP route; nil for a route through an API connection.
    var agent: GitCommitAgent? {
        if case .agent(let agent) = target { return agent }
        return nil
    }

    /// The API connection of an HTTP route; nil for an agent route.
    var provider: UUID? {
        if case .provider(let provider) = target { return provider }
        return nil
    }

    /// Display name without the settings at hand; an API connection shows as "API".
    var title: String { title(providers: []) }

    func title(providers: [AIProvider]) -> String {
        "\(sourceTitle(providers: providers)) · \(model)"
    }

    func sourceTitle(providers: [AIProvider]) -> String {
        switch target {
        case .agent(let agent): agent.title
        case .provider(let id): providers.first { $0.id == id }?.name ?? "API"
        }
    }

    static func adding(agent: GitCommitAgent, models: [String], to existing: [Self]) -> [Self] {
        adding(target: .agent(agent), models: models, to: existing)
    }

    static func adding(provider: UUID, models: [String], to existing: [Self]) -> [Self] {
        adding(target: .provider(provider), models: models, to: existing)
    }

    static func adding(target: Target, models: [String], to existing: [Self]) -> [Self] {
        var result = existing
        for raw in models {
            guard let model = AIModelID.normalized(raw),
                  !result.contains(where: { $0.target == target && $0.model == model }) else { continue }
            result.append(Self(target: target, model: model))
        }
        return result
    }

    /// Reads `ai.routes.commit` (`{id, kind, agent | provider, model}`) and the older
    /// `git.commitAI.routes` (`{id, agent, model}`). Invalid entries and duplicates are dropped.
    static func decode(_ value: Any?) -> [Self] {
        guard let entries = value as? [Any] else { return [] }
        var result: [Self] = []
        for case let entry as [String: Any] in entries {
            let target: Target?
            switch entry["kind"] as? String {
            case "provider":
                target = (entry["provider"] as? String).flatMap(UUID.init(uuidString:)).map(Target.provider)
            case "agent", nil:
                target = (entry["agent"] as? String).flatMap(GitCommitAgent.init(rawValue:)).map(Target.agent)
            default:
                target = nil
            }
            guard let target, let model = entry["model"] as? String else { continue }
            let added = adding(target: target, models: [model], to: result)
            guard added.count > result.count, let route = added.last else { continue }
            let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:))
                .flatMap { id in result.contains(where: { $0.id == id }) ? nil : id } ?? UUID()
            result.append(Self(id: id, target: target, model: route.model))
        }
        return result
    }

    static func encode(_ routes: [Self]) -> [[String: Any]] {
        routes.map { route in
            switch route.target {
            case .agent(let agent):
                ["id": route.id.uuidString, "kind": "agent", "agent": agent.rawValue, "model": route.model]
            case .provider(let provider):
                ["id": route.id.uuidString, "kind": "provider", "provider": provider.uuidString,
                 "model": route.model]
            }
        }
    }

    /// The agent routes in the shape builds before the AI page read (`git.commitAI.routes`).
    static func encodeLegacy(_ routes: [Self]) -> [[String: Any]] {
        routes.compactMap { route in
            route.agent.map { ["id": route.id.uuidString, "agent": $0.rawValue, "model": route.model] }
        }
    }
}
