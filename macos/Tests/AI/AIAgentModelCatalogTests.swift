import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AIAgentModelCatalogTests {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? { "adapter missing" }
    }

    /// Scripted discovery results, one per call.
    private actor Script {
        private var results: [Result<[String], Error>]
        private(set) var calls: [GitCommitAgent] = []

        init(_ results: [Result<[String], Error>]) {
            self.results = results
        }

        func next(_ agent: GitCommitAgent) throws -> [String] {
            calls.append(agent)
            return try results.removeFirst().get()
        }
    }

    @Test func discoveryIsOnDemandAndKeepsTheLastListAfterAFailure() async {
        let script = Script([.success(["a", "b"]), .failure(Unavailable())])
        let catalog = AIAgentModelCatalog { try await script.next($0) }

        #expect(catalog.entry(.claude) == AIAgentModelCatalog.Entry())
        #expect(await script.calls.isEmpty)

        catalog.refresh(.claude)
        #expect(catalog.entry(.claude).isLoading)
        // A second request while one is running does not start another agent process.
        catalog.refresh(.claude)
        #expect(await waitUntil { await MainActor.run { !catalog.entry(.claude).isLoading } })
        #expect(catalog.entry(.claude).models == ["a", "b"])
        #expect(catalog.entry(.claude).checkedAt != nil)
        #expect(catalog.entry(.claude).error == nil)
        #expect(await script.calls == [.claude])
        #expect(catalog.entry(.codex).models == nil)

        catalog.refresh(.claude)
        #expect(await waitUntil { await MainActor.run { !catalog.entry(.claude).isLoading } })
        #expect(catalog.entry(.claude).models == ["a", "b"])
        #expect(catalog.entry(.claude).error == "adapter missing")
    }

    @Test func theLastDiscoveryIsRememberedAcrossInstances() async throws {
        let name = "AIAgentModelCatalogTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let script = Script([.success(["model-a"])])
        let catalog = AIAgentModelCatalog(defaults: defaults) { try await script.next($0) }
        catalog.refresh(.opencode)
        #expect(await waitUntil { await MainActor.run { catalog.entry(.opencode).models != nil } })

        // A new instance shows the count without starting any discovery.
        let idle = Script([])
        let restored = AIAgentModelCatalog(defaults: defaults) { try await idle.next($0) }
        #expect(restored.entry(.opencode).models == ["model-a"])
        #expect(restored.entry(.opencode).checkedAt != nil)
        #expect(!restored.entry(.opencode).isLoading)
        #expect(restored.entry(.pi).models == nil)
        #expect(await idle.calls.isEmpty)
    }
}
