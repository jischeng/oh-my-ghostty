import Foundation

/// Rules shared by every place a model ID is stored: routes and provider model lists.
enum AIModelID {
    static let maxBytes = 256

    /// The trimmed ID, or nil when it is empty, too long or carries control characters.
    static func normalized(_ raw: String) -> String? {
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= maxBytes,
              !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return model
    }
}

/// One model of an API connection. Limits are in tokens; nil means "use the default".
struct AIProviderModel: Equatable, Identifiable, Sendable {
    static let limitRange = 1...100_000_000

    var id: String
    var contextWindow: Int?
    var maxOutputTokens: Int?

    init(id: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.id = id
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }

    /// A stored or typed limit, clamped to a sane range. Zero, negatives and junk mean "not set".
    /// Typed text may group digits (`200,000`) or use a `k` / `m` suffix (`128k`, `1m`).
    static func limit(_ value: Any?) -> Int? {
        let number: Double?
        switch value {
        case let value as NSNumber:
            number = value.doubleValue
        case let value as String:
            var text = value.lowercased()
            text.removeAll { $0.isWhitespace || $0 == "," || $0 == "_" }
            var scale = 1.0
            if text.hasSuffix("k") {
                scale = 1_000
                text.removeLast()
            } else if text.hasSuffix("m") {
                scale = 1_000_000
                text.removeLast()
            }
            number = Double(text).map { $0 * scale }
        default:
            number = nil
        }
        guard let number, number.isFinite, number >= Double(limitRange.lowerBound) else { return nil }
        return Int(min(number, Double(limitRange.upperBound)))
    }
}

/// A user-defined API connection. The API key is not part of it: it lives in
/// `AICredentialStore`, keyed by `id`, so `settings.json` never holds a secret.
struct AIProvider: Equatable, Identifiable, Sendable {
    static let maxProviders = 32
    static let maxModels = 500
    static let maxNameLength = 80
    /// Identity given to the provider migrated from the single iteration-1 endpoint.
    /// The credential store files the old single API key under the same identity.
    static let legacyEndpointID = UUID(uuidString: "0A1E0D00-0000-4000-8000-000000000001") ?? UUID()

    var id: UUID
    var name: String
    var kind: AIEndpointProtocol
    var baseURL: String
    var enabled: Bool
    var models: [AIProviderModel]

    init(
        id: UUID = UUID(),
        name: String,
        kind: AIEndpointProtocol = .openAI,
        baseURL: String = "",
        enabled: Bool = true,
        models: [AIProviderModel] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.enabled = enabled
        self.models = models
    }

    func model(_ id: String) -> AIProviderModel? {
        models.first { $0.id == id }
    }

    /// Adds the IDs that are not listed yet and keeps existing entries with their limits.
    /// Returns how many were added; the list never grows past `maxModels`.
    @discardableResult
    mutating func mergeModels(_ ids: [String]) -> Int {
        var added = 0
        for raw in ids {
            guard models.count < Self.maxModels else { break }
            guard let id = AIModelID.normalized(raw), model(id) == nil else { continue }
            models.append(AIProviderModel(id: id))
            added += 1
        }
        return added
    }

    /// A one-line display name: trimmed, without control characters, bounded.
    static func normalizedName(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    /// The host of the base URL, used when the user has not named the connection.
    static func suggestedName(baseURL: String) -> String {
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        return host.flatMap { $0.isEmpty ? nil : $0 } ?? "API"
    }

    /// The request target for `model`, or nil while the base URL is missing or invalid.
    func endpoint(model: String, apiKey: String?) -> AIEndpoint? {
        guard let id = AIModelID.normalized(model) else { return nil }
        let limits = self.model(id)
        return AIEndpoint.configured(
            kind: kind,
            baseURL: baseURL,
            model: id,
            apiKey: apiKey,
            maxOutputTokens: limits?.maxOutputTokens.map { UInt($0) },
            contextWindow: limits?.contextWindow
        )
    }

    /// The target of the model-list call. Throws the reason the base URL is not usable.
    func listEndpoint(apiKey: String?) throws -> AIEndpoint {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIEndpoint(kind: kind, baseURL: try AIEndpoint.validatedBaseURL(baseURL), model: "",
                          apiKey: key?.isEmpty == false ? key : nil)
    }

    // MARK: Persistence (`ai.providers`)

    /// Reads the stored array. Hand-edited entries are repaired or dropped one by one,
    /// so a single bad entry never discards the other connections.
    static func decode(_ value: Any?) -> [AIProvider] {
        guard let entries = value as? [Any] else { return [] }
        var result: [AIProvider] = []
        for case let entry as [String: Any] in entries {
            guard result.count < maxProviders,
                  let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)),
                  !result.contains(where: { $0.id == id }),
                  let kind = (entry["kind"] as? String).flatMap(AIEndpointProtocol.init(rawValue:)) else {
                continue
            }
            let baseURL = (entry["baseURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = normalizedName(entry["name"] as? String ?? "")
            var provider = AIProvider(
                id: id,
                name: name.isEmpty ? suggestedName(baseURL: baseURL) : name,
                kind: kind,
                baseURL: String(baseURL.prefix(2_048)),
                enabled: entry["enabled"] as? Bool ?? true
            )
            for model in entry["models"] as? [Any] ?? [] {
                guard provider.models.count < maxModels else { break }
                let object = model as? [String: Any]
                guard let modelID = (object?["id"] as? String ?? model as? String).flatMap(AIModelID.normalized),
                      provider.model(modelID) == nil else { continue }
                provider.models.append(AIProviderModel(
                    id: modelID,
                    contextWindow: AIProviderModel.limit(object?["contextWindow"]),
                    maxOutputTokens: AIProviderModel.limit(object?["maxOutputTokens"])
                ))
            }
            result.append(provider)
        }
        return result
    }

    static func encode(_ providers: [AIProvider]) -> [[String: Any]] {
        providers.map { provider in
            [
                "id": provider.id.uuidString,
                "name": provider.name,
                "kind": provider.kind.rawValue,
                "baseURL": provider.baseURL,
                "enabled": provider.enabled,
                "models": provider.models.map { model -> [String: Any] in
                    var object: [String: Any] = ["id": model.id]
                    if let contextWindow = model.contextWindow { object["contextWindow"] = contextWindow }
                    if let maxOutputTokens = model.maxOutputTokens { object["maxOutputTokens"] = maxOutputTokens }
                    return object
                },
            ]
        }
    }

    /// The provider that replaces the iteration-1 `ai.endpoint.*` keys, or nil when
    /// no base URL was stored. A stored model becomes its only model.
    static func migratingLegacyEndpoint(kind: Any?, baseURL: Any?, model: Any?) -> AIProvider? {
        let url = (baseURL as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        var provider = AIProvider(
            id: legacyEndpointID,
            name: suggestedName(baseURL: url),
            kind: (kind as? String).flatMap(AIEndpointProtocol.init(rawValue:)) ?? .openAI,
            baseURL: url
        )
        provider.mergeModels([model as? String ?? ""])
        return provider
    }
}

/// The model that names agent conversations (`ai.routes.title`): either an API service
/// model (HTTP) or a logged-in local CLI model (ACP), sharing the same target model as Git.
struct AITitleRoute: Equatable, Sendable {
    let target: GitCommitAIRoute.Target
    let model: String

    init(target: GitCommitAIRoute.Target, model: String) {
        self.target = target
        self.model = model
    }

    init(provider: UUID, model: String) {
        self.init(target: .provider(provider), model: model)
    }

    init(agent: GitCommitAgent, model: String) {
        self.init(target: .agent(agent), model: model)
    }

    var provider: UUID? {
        if case .provider(let provider) = target { return provider }
        return nil
    }

    var agent: GitCommitAgent? {
        if case .agent(let agent) = target { return agent }
        return nil
    }

    /// Reads both the unified `{kind, provider | agent, model}` object and the legacy
    /// `{provider, model}` shape from `ai.routes.title`.
    static func decode(_ value: Any?) -> AITitleRoute? {
        guard let object = value as? [String: Any],
              let model = (object["model"] as? String).flatMap(AIModelID.normalized) else { return nil }
        switch object["kind"] as? String {
        case "agent":
            guard let agent = (object["agent"] as? String).flatMap(GitCommitAgent.init(rawValue:)) else {
                return nil
            }
            return AITitleRoute(agent: agent, model: model)
        case "provider":
            guard let provider = (object["provider"] as? String).flatMap(UUID.init(uuidString:)) else {
                return nil
            }
            return AITitleRoute(provider: provider, model: model)
        case nil:
            if let provider = (object["provider"] as? String).flatMap(UUID.init(uuidString:)) {
                return AITitleRoute(provider: provider, model: model)
            }
            if let agent = (object["agent"] as? String).flatMap(GitCommitAgent.init(rawValue:)) {
                return AITitleRoute(agent: agent, model: model)
            }
            return nil
        default:
            return nil
        }
    }

    var encoded: [String: Any] {
        switch target {
        case .provider(let provider):
            ["kind": "provider", "provider": provider.uuidString, "model": model]
        case .agent(let agent):
            ["kind": "agent", "agent": agent.rawValue, "model": model]
        }
    }
}

/// Why an API connection cannot serve a request right now. Shown in the Git UI, so
/// every case names something the user can change in AI settings.
enum AIProviderResolutionError: Error, Equatable, Sendable {
    case removed
    case disabled(name: String)
    case invalidBaseURL(name: String)
}

/// The API connections as they were when a request started, with a way to read each
/// key at the moment it is needed. Value type so it can leave the main actor.
struct AIProviderDirectory: Sendable {
    let providers: [AIProvider]
    private let apiKey: @Sendable (UUID) -> String?

    static let empty = AIProviderDirectory(providers: [], apiKey: { _ in nil })

    init(providers: [AIProvider], apiKey: @escaping @Sendable (UUID) -> String?) {
        self.providers = providers
        self.apiKey = apiKey
    }

    init(providers: [AIProvider], credentials: AICredentialStore) {
        self.init(providers: providers, apiKey: { credentials.apiKey(for: $0) })
    }

    func provider(_ id: UUID) -> AIProvider? {
        providers.first { $0.id == id }
    }

    /// The request target for a model of an enabled connection.
    func endpoint(provider id: UUID, model: String) throws -> AIEndpoint {
        guard let provider = provider(id) else { throw AIProviderResolutionError.removed }
        guard provider.enabled else { throw AIProviderResolutionError.disabled(name: provider.name) }
        guard let endpoint = provider.endpoint(model: model, apiKey: apiKey(id)) else {
            throw AIProviderResolutionError.invalidBaseURL(name: provider.name)
        }
        return endpoint
    }

    /// The HTTP endpoint behind an API-service tab-title route, or nil for none / CLI routes.
    func titleEndpoint(_ route: AITitleRoute?) -> AIEndpoint? {
        guard let provider = route?.provider, let model = route?.model else { return nil }
        return try? endpoint(provider: provider, model: model)
    }
}
