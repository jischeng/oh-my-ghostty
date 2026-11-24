import Foundation

/// The AI endpoint API key, kept in a private file instead of `settings.json` so it is
/// never synced, exported or printed with the rest of the settings.
final class AICredentialStore: @unchecked Sendable {
    static let shared = AICredentialStore()

    struct Credentials: Codable, Equatable, Sendable {
        var version = 1
        var apiKey: String?

        init(apiKey: String? = nil) {
            self.apiKey = apiKey
        }
    }

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

    func apiKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()?.apiKey
    }

    func setAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        lock.lock()
        defer { lock.unlock() }
        if value == loadLocked()?.apiKey { return }
        guard let value else {
            try removeLocked()
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Credentials(apiKey: value))
            try OMGPrivateFileWriter.writeAtomically(data, to: fileURL)
        } catch OMGPrivateFileWriter.WriteError.unsafePath {
            throw StoreError.unsafePath
        } catch {
            throw StoreError.writeFailed
        }
    }

    private func loadLocked() -> Credentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
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
