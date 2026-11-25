import Foundation
import Testing
@testable import Ghostty

struct AIProviderTests {
    private static func provider(
        id: UUID = UUID(),
        name: String = "Work proxy",
        kind: AIEndpointProtocol = .openAI,
        baseURL: String = "https://api.example.com",
        enabled: Bool = true,
        models: [AIProviderModel] = [AIProviderModel(id: "small", contextWindow: 8_000, maxOutputTokens: 512)]
    ) -> AIProvider {
        AIProvider(id: id, name: name, kind: kind, baseURL: baseURL, enabled: enabled, models: models)
    }

    @Test func providersRoundTripThroughTheSettingsShape() throws {
        let providers = [
            Self.provider(models: [AIProviderModel(id: "small", contextWindow: 8_000, maxOutputTokens: 512),
                                   AIProviderModel(id: "plain")]),
            Self.provider(name: "Claude API", kind: .anthropic, baseURL: "https://api.anthropic.com",
                          enabled: false, models: []),
        ]
        let encoded = AIProvider.encode(providers)
        #expect(JSONSerialization.isValidJSONObject(encoded))
        #expect(AIProvider.decode(encoded) == providers)

        let first = try #require(encoded.first)
        #expect(Set(first.keys) == ["id", "name", "kind", "baseURL", "enabled", "models"])
        #expect(first["id"] as? String == providers[0].id.uuidString)
        #expect(first["kind"] as? String == "openai")
        let models = try #require(first["models"] as? [[String: Any]])
        #expect(models[0]["contextWindow"] as? Int == 8_000)
        #expect(models[0]["maxOutputTokens"] as? Int == 512)
        // Unset limits are left out instead of being written as null or zero.
        #expect(Set(models[1].keys) == ["id"])
        #expect(encoded[1]["kind"] as? String == "anthropic")
        #expect(encoded[1]["enabled"] as? Bool == false)
    }

    @Test func decodingRepairsOrDropsHandEditedEntriesOneByOne() {
        let id = UUID()
        let models: [Any] = [
            "bare-id",
            ["id": " spaced "],
            ["id": "bare-id"],
            ["id": ""],
            ["id": "bad\u{0}id"],
            ["id": "limits", "contextWindow": -5, "maxOutputTokens": "2k"] as [String: Any],
            7,
        ]
        let tidy: [String: Any] = [
            "id": id.uuidString.lowercased(), "name": "  Tidy\nme  ", "kind": "openai",
            "baseURL": "  https://api.example.com/v1  ", "models": models,
        ]
        let unnamed: [String: Any] = [
            "id": UUID().uuidString, "kind": "anthropic", "baseURL": "https://api.anthropic.com",
        ]
        let entries: [Any] = [
            tidy,
            ["id": id.uuidString, "name": "Duplicate id", "kind": "openai"],
            ["id": "not-a-uuid", "name": "No id", "kind": "openai"],
            ["id": UUID().uuidString, "name": "Unknown kind", "kind": "gemini"],
            "junk",
            unnamed,
        ]
        let decoded = AIProvider.decode(entries)

        #expect(decoded.count == 2)
        #expect(decoded[0].id == id)
        #expect(decoded[0].name == "Tidyme")
        #expect(decoded[0].baseURL == "https://api.example.com/v1")
        #expect(decoded[0].enabled)
        #expect(decoded[0].models.map(\.id) == ["bare-id", "spaced", "limits"])
        #expect(decoded[0].models[2].contextWindow == nil)
        #expect(decoded[0].models[2].maxOutputTokens == 2_000)
        // A connection without a name is named after its host.
        #expect(decoded[1].name == "api.anthropic.com")
        #expect(decoded[1].kind == .anthropic)

        #expect(AIProvider.decode(nil).isEmpty)
        #expect(AIProvider.decode("invalid").isEmpty)
        #expect(AIProvider.decode(["id": id.uuidString]).isEmpty)
    }

    @Test func providerAndModelCountsAreBounded() {
        let many = (0..<(AIProvider.maxProviders + 5)).map { index in
            ["id": UUID().uuidString, "name": "P\(index)", "kind": "openai"] as [String: Any]
        }
        #expect(AIProvider.decode(many).count == AIProvider.maxProviders)

        var provider = Self.provider(models: [])
        let added = provider.mergeModels((0..<(AIProvider.maxModels + 20)).map { "model-\($0)" })
        #expect(added == AIProvider.maxModels)
        #expect(provider.models.count == AIProvider.maxModels)
        #expect(provider.mergeModels(["one-more"]) == 0)
    }

    @Test func mergingModelsKeepsExistingLimitsAndSkipsDuplicates() {
        var provider = Self.provider()
        let added = provider.mergeModels(["small", " large ", "large", "", "bad\nid"])
        #expect(added == 1)
        #expect(provider.models == [
            AIProviderModel(id: "small", contextWindow: 8_000, maxOutputTokens: 512),
            AIProviderModel(id: "large"),
        ])
    }

    @Test func typedLimitsAcceptGroupingAndSuffixes() {
        #expect(AIProviderModel.limit("200000") == 200_000)
        #expect(AIProviderModel.limit(" 200,000 ") == 200_000)
        #expect(AIProviderModel.limit("128k") == 128_000)
        #expect(AIProviderModel.limit("1M") == 1_000_000)
        #expect(AIProviderModel.limit("1.5k") == 1_500)
        #expect(AIProviderModel.limit(NSNumber(value: 4096)) == 4_096)
        #expect(AIProviderModel.limit("") == nil)
        #expect(AIProviderModel.limit("0") == nil)
        #expect(AIProviderModel.limit("-3") == nil)
        #expect(AIProviderModel.limit("lots") == nil)
        #expect(AIProviderModel.limit(nil) == nil)
        #expect(AIProviderModel.limit("999999999999") == AIProviderModel.limitRange.upperBound)
    }

    @Test func theFirstBuildEndpointBecomesAConnectionWithItsModel() throws {
        let migrated = try #require(AIProvider.migratingLegacyEndpoint(
            kind: "anthropic", baseURL: "  https://proxy.example.com/v1 ", model: " claude-test "
        ))
        #expect(migrated.id == AIProvider.legacyEndpointID)
        #expect(migrated.name == "proxy.example.com")
        #expect(migrated.kind == .anthropic)
        #expect(migrated.baseURL == "https://proxy.example.com/v1")
        #expect(migrated.enabled)
        #expect(migrated.models == [AIProviderModel(id: "claude-test")])

        let noModel = try #require(AIProvider.migratingLegacyEndpoint(
            kind: nil, baseURL: "https://api.example.com", model: nil
        ))
        #expect(noModel.kind == .openAI)
        #expect(noModel.models.isEmpty)
        #expect(AIProvider.migratingLegacyEndpoint(kind: "openai", baseURL: "  ", model: "gpt") == nil)
        #expect(AIProvider.migratingLegacyEndpoint(kind: "openai", baseURL: 5, model: "gpt") == nil)
    }

    @Test func titleRouteRoundTripsAndRejectsBrokenShapes() {
        let providerID = UUID()
        let route = AITitleRoute(provider: providerID, model: "small")
        #expect(AITitleRoute.decode(route.encoded) == route)
        #expect(AITitleRoute.decode(["provider": providerID.uuidString, "model": "small"]) == route)
        #expect(JSONSerialization.isValidJSONObject(route.encoded))

        let agentRoute = AITitleRoute(agent: .codex, model: "gpt-5-codex")
        #expect(AITitleRoute.decode(agentRoute.encoded) == agentRoute)
        #expect(JSONSerialization.isValidJSONObject(agentRoute.encoded))

        #expect(AITitleRoute.decode(nil) == nil)
        #expect(AITitleRoute.decode(["provider": "nope", "model": "small"]) == nil)
        #expect(AITitleRoute.decode(["kind": "agent", "agent": "nope", "model": "small"]) == nil)
        #expect(AITitleRoute.decode(["kind": "other", "provider": providerID.uuidString, "model": "small"]) == nil)
        #expect(AITitleRoute.decode(["provider": providerID.uuidString, "model": "  "]) == nil)
        #expect(AITitleRoute.decode(["provider": providerID.uuidString]) == nil)
    }

    @Test func anEndpointCarriesTheModelLimitsAndTheProvidersKey() throws {
        let provider = Self.provider()
        let endpoint = try #require(provider.endpoint(model: " small ", apiKey: "  test-key  "))
        #expect(endpoint.kind == .openAI)
        #expect(endpoint.baseURL.absoluteString == "https://api.example.com")
        #expect(endpoint.model == "small")
        #expect(endpoint.apiKey == "test-key")
        #expect(endpoint.maxOutputTokens == 512)
        #expect(endpoint.contextWindow == 8_000)

        // A model that is not listed still resolves, without limits.
        let unlisted = try #require(provider.endpoint(model: "other", apiKey: nil))
        #expect(unlisted.maxOutputTokens == nil)
        #expect(unlisted.contextWindow == nil)
        #expect(unlisted.apiKey == nil)

        #expect(Self.provider(baseURL: "").endpoint(model: "small", apiKey: nil) == nil)
        #expect(Self.provider(baseURL: "http://api.example.com").endpoint(model: "small", apiKey: nil) == nil)
        #expect(provider.endpoint(model: "  ", apiKey: nil) == nil)
        #expect(throws: AIEndpointError.empty) { try Self.provider(baseURL: " ").listEndpoint(apiKey: nil) }
        #expect(try provider.listEndpoint(apiKey: " key ").apiKey == "key")
    }

    @Test func theDirectoryResolvesEnabledConnectionsAndNamesWhyOthersFail() throws {
        let enabled = Self.provider()
        let disabled = Self.provider(name: "Paused", enabled: false)
        let broken = Self.provider(name: "Broken", baseURL: "ftp://example.com")
        let directory = AIProviderDirectory(providers: [enabled, disabled, broken]) { id in
            id == enabled.id ? "test-key" : nil
        }

        let endpoint = try directory.endpoint(provider: enabled.id, model: "small")
        #expect(endpoint.apiKey == "test-key")
        #expect(endpoint.maxOutputTokens == 512)
        #expect(throws: AIProviderResolutionError.removed) {
            try directory.endpoint(provider: UUID(), model: "small")
        }
        #expect(throws: AIProviderResolutionError.disabled(name: "Paused")) {
            try directory.endpoint(provider: disabled.id, model: "small")
        }
        #expect(throws: AIProviderResolutionError.invalidBaseURL(name: "Broken")) {
            try directory.endpoint(provider: broken.id, model: "small")
        }

        #expect(directory.titleEndpoint(AITitleRoute(provider: enabled.id, model: "small")) == endpoint)
        #expect(directory.titleEndpoint(AITitleRoute(provider: disabled.id, model: "small")) == nil)
        #expect(directory.titleEndpoint(AITitleRoute(provider: UUID(), model: "small")) == nil)
        #expect(directory.titleEndpoint(nil) == nil)
        #expect(AIProviderDirectory.empty.titleEndpoint(AITitleRoute(provider: enabled.id, model: "small")) == nil)
    }

    @Test func theDirectoryReadsKeysFromTheCredentialStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AICredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let provider = Self.provider()
        let directory = AIProviderDirectory(providers: [provider], credentials: store)
        #expect(try directory.endpoint(provider: provider.id, model: "small").apiKey == nil)
        // The key is read when the endpoint is resolved, not when the directory is made.
        try store.setAPIKey("late-test-key", for: provider.id)
        #expect(try directory.endpoint(provider: provider.id, model: "small").apiKey == "late-test-key")
    }
}
