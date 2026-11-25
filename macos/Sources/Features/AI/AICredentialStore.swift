import Foundation

/// API keys of the AI connections, kept in one private file instead of `settings.json`
/// so they are never synced, exported or printed with the rest of the settings.
/// Keys are filed under the connection's identity.
final class AICredentialStore: @unchecked Sendable {
    static let shared = AICredentialStore()
    static let currentVersion = 2

    enum StoreError: LocalizedError, Equatable {
        case unsafePath
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unsafePath: "Refusing to write the API key through a symbolic link."
            case .writeFailed: "Could not save the API key."
            }
        }
    }

    /// `~/Library/Application Support/OMG/AI/credentials.json` (channel-specific).
    static var defaultFileURL: URL {
        OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL = AICredentialStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func apiKey(for provider: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[provider.uuidString]
    }

    /// Whether a key is stored, for status labels that must not read the value itself.
    func hasAPIKey(for provider: UUID) -> Bool {
        apiKey(for: provider) != nil
    }

    /// Stores the key of one connection. An empty key removes it, and the file goes
    /// away with the last key.
    func setAPIKey(_ key: String?, for provider: UUID) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        lock.lock()
        defer { lock.unlock() }
        var keys = loadLocked()
        guard keys[provider.uuidString] != value else { return }
        keys[provider.uuidString] = value
        try saveLocked(keys)
    }

    func removeAPIKey(for provider: UUID) throws {
        try setAPIKey(nil, for: provider)
    }

    /// Reads the current layout, or the version 1 file that held one key for the
    /// single endpoint. That key belongs to the connection migrated from it.
    private func loadLocked() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var keys: [String: String] = [:]
        for (provider, value) in object["keys"] as? [String: Any] ?? [:] {
            guard let id = UUID(uuidString: provider), let key = value as? String, !key.isEmpty else { continue }
            keys[id.uuidString] = key
        }
        if object["keys"] == nil, let legacy = object["apiKey"] as? String, !legacy.isEmpty {
            keys[AIProvider.legacyEndpointID.uuidString] = legacy
        }
        return keys
    }

    private func saveLocked(_ keys: [String: String]) throws {
        guard !keys.isEmpty else {
            try removeLocked()
            return
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: ["version": Self.currentVersion, "keys": keys],
                options: [.prettyPrinted, .sortedKeys]
            )
            try OMGPrivateFileWriter.writeAtomically(data, to: fileURL)
        } catch OMGPrivateFileWriter.WriteError.unsafePath {
            throw StoreError.unsafePath
        } catch {
            throw StoreError.writeFailed
        }
    }

    private func removeLocked() throws {
        let manager = FileManager.default
        var linkInfo = stat()
        if Darwin.lstat(fileURL.path, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFLNK {
            throw StoreError.unsafePath
        }
        guard manager.fileExists(atPath: fileURL.path) else { return }
        do {
            try manager.removeItem(at: fileURL)
        } catch {
            throw StoreError.writeFailed
        }
    }
}
