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

struct GitCommitAIRoute: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    let agent: GitCommitAgent
    let model: String
    var title: String { "\(agent.title) · \(model)" }

    static func adding(agent: GitCommitAgent, models: [String], to existing: [Self]) -> [Self] {
        var result = existing
        for raw in models {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, model.utf8.count <= 256,
                  !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !result.contains(where: { $0.agent == agent && $0.model == model }) else { continue }
            result.append(Self(agent: agent, model: model))
        }
        return result
    }

    static func decode(_ value: Any?) -> [Self] {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let routes = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return routes.reduce(into: []) { result, route in
            let added = adding(agent: route.agent, models: [route.model], to: result)
            if added.count > result.count {
                result.append(Self(id: result.contains(where: { $0.id == route.id }) ? UUID() : route.id,
                                   agent: route.agent, model: added.last!.model))
            }
        }
    }

    static func encode(_ routes: [Self]) -> Any {
        guard let data = try? JSONEncoder().encode(routes),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return object
    }
}
