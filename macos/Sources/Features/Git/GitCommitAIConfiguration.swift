import Foundation

/// Only adapters with an explicit tool-free, non-interactive invocation belong here.
enum GitCommitAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, pi
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Pi" }

    var isolationArguments: [String] {
        switch self {
        case .claude:
            ["--bare", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
             "--no-session-persistence"]
        case .pi:
            ["--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates",
             "--no-themes", "--no-context-files", "--no-session", "--no-approve"]
        }
    }

    func arguments(model: String) -> [String] {
        isolationArguments + (self == .claude
            ? ["--print", "--output-format", "json", "--model", model]
            : ["--print", "--mode", "json", "--model", model])
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
        // Normalize hand-edited settings and regenerate duplicate identities.
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
