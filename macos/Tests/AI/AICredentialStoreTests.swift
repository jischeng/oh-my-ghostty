import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AICredentialStoreTests {
    @Test func roundTripsTheKeyWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("AI").appendingPathComponent("credentials.json")
        let store = AICredentialStore(fileURL: fileURL)

        #expect(store.apiKey() == nil)
        try store.setAPIKey("  sk-test-key  ")
        #expect(store.apiKey() == "sk-test-key")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(saved?["apiKey"] as? String == "sk-test-key")
        #expect(saved?["version"] as? Int == 1)
    }

    @Test func clearingTheKeyRemovesTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("AI").appendingPathComponent("credentials.json")
        let store = AICredentialStore(fileURL: fileURL)

        try store.setAPIKey("sk-test-key")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        try store.setAPIKey("   ")
        #expect(store.apiKey() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func writingThroughASymbolicLinkIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere.json")
        let fileURL = root.appendingPathComponent("AI").appendingPathComponent("credentials.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)

        let store = AICredentialStore(fileURL: fileURL)
        #expect(throws: AICredentialStore.StoreError.unsafePath) {
            try store.setAPIKey("sk-test-key")
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

}
