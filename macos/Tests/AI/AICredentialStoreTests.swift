import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AICredentialStoreTests {
    private static func temporaryStore() -> (store: AICredentialStore, fileURL: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("AI").appendingPathComponent("credentials.json")
        return (AICredentialStore(fileURL: fileURL), fileURL, root)
    }

    @Test func roundTripsKeysPerProviderWithPrivatePermissions() throws {
        let (store, fileURL, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID()
        let second = UUID()

        #expect(store.apiKey(for: first) == nil)
        #expect(!store.hasAPIKey(for: first))
        try store.setAPIKey("  first-test-key  ", for: first)
        try store.setAPIKey("second-test-key", for: second)
        #expect(store.apiKey(for: first) == "first-test-key")
        #expect(store.apiKey(for: second) == "second-test-key")
        #expect(store.hasAPIKey(for: second))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(saved?["version"] as? Int == AICredentialStore.currentVersion)
        let keys = saved?["keys"] as? [String: String]
        #expect(keys == [first.uuidString: "first-test-key", second.uuidString: "second-test-key"])
        #expect(saved?["apiKey"] == nil)

        // Another instance on the same file sees the same keys.
        #expect(AICredentialStore(fileURL: fileURL).apiKey(for: first) == "first-test-key")
    }

    @Test func removingAProviderKeyKeepsTheOthersAndTheLastRemovalDeletesTheFile() throws {
        let (store, fileURL, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID()
        let second = UUID()
        try store.setAPIKey("first-test-key", for: first)
        try store.setAPIKey("second-test-key", for: second)

        try store.removeAPIKey(for: first)
        #expect(store.apiKey(for: first) == nil)
        #expect(store.apiKey(for: second) == "second-test-key")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try store.setAPIKey("   ", for: second)
        #expect(store.apiKey(for: second) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        // Removing a key that is not stored is not an error.
        try store.removeAPIKey(for: UUID())
    }

    @Test func theSingleKeyOfTheFirstFormatBelongsToTheMigratedConnection() throws {
        let (store, fileURL, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"version":1,"apiKey":"legacy-test-key"}"#.utf8).write(to: fileURL)

        #expect(store.apiKey(for: AIProvider.legacyEndpointID) == "legacy-test-key")
        #expect(store.apiKey(for: UUID()) == nil)

        // The next write keeps it under the connection id in the current layout.
        let other = UUID()
        try store.setAPIKey("other-test-key", for: other)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(saved?["apiKey"] == nil)
        #expect(saved?["keys"] as? [String: String] == [
            AIProvider.legacyEndpointID.uuidString: "legacy-test-key",
            other.uuidString: "other-test-key",
        ])
    }

    @Test func malformedFilesAndEntriesReadAsNoKey() throws {
        let (store, fileURL, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let id = UUID()
        try Data("not json".utf8).write(to: fileURL)
        #expect(store.apiKey(for: id) == nil)
        let lowercase = id.uuidString.lowercased()
        try Data(#"{"version":2,"keys":{"not-a-uuid":"x","\#(lowercase)":"kept-test-key","\#(UUID().uuidString)":5}}"#.utf8)
            .write(to: fileURL)
        #expect(store.apiKey(for: id) == "kept-test-key")
    }

    @Test func writingThroughASymbolicLinkIsRefused() throws {
        let (store, fileURL, root) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)

        #expect(throws: AICredentialStore.StoreError.unsafePath) {
            try store.setAPIKey("test-key", for: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
