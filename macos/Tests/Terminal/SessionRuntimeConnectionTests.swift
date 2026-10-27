import Foundation
import Testing
@testable import Ghostty

struct SessionRuntimeConnectionTests {
    @Test func hostIdentityIncludesExactRoutingAndRuntimeRevision() throws {
        let a = try GitSSHConnection(destination: "devbox", options: ["-p", "2222", "-J", "jump"])
        let b = try GitSSHConnection(destination: "devbox", options: ["-p", "2223", "-J", "jump"])
        let first = SessionRuntimeDescriptor(connection: a, revision: "abc", policy: .init())
        let second = SessionRuntimeDescriptor(connection: b, revision: "abc", policy: .init())
        #expect(first.identity != second.identity)
        #expect(first.identity != SessionRuntimeDescriptor(connection: a, revision: "def", policy: .init()).identity)
        let decoded = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
    }

    @Test func restoredPaneCannotSilentlyCreateANewRemoteProcess() throws {
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "devbox"), revision: "abc", policy: .init())
        let id = UUID()
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, restoring: false).utf8)) as? [String: Any])
        let restored = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, restoring: true).utf8)) as? [String: Any])
        #expect(fresh["id"] as? String == id.uuidString.lowercased())
        #expect(fresh["create"] as? Bool == true)
        #expect(restored["create"] as? Bool == false)
        #expect((restored["policy"] as? [String: Any])?["detached_ttl_seconds"] as? Int == 86400)
    }

    @MainActor
    @Test func lifetimeSettingsPersistAndRemainBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.runtimePolicy.detachedTTLSeconds == 86400)
        settings.runtimeDetachedHours = 2
        settings.runtimeCloseOnAgentDone = true
        settings.runtimeDoneGraceSeconds = 15
        settings.runtimeExpiration = "2030-01-01T00:00:00Z"
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.runtimePolicy.detachedTTLSeconds == 7200)
        #expect(restored.runtimePolicy.closeOnAgentDone)
        #expect(restored.runtimePolicy.agentDoneGraceSeconds == 15)
        #expect(restored.runtimePolicy.expiresAt == 1_893_456_000)
        settings.runtimeDetachedHours = -1
        #expect(settings.runtimePolicy.detachedTTLSeconds == 0)
    }
}
