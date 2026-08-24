import AppKit
import Combine
import Foundation

struct PluginSettingDescriptor: Codable, Equatable, Sendable {
    enum ValueType: String, Codable, Sendable {
        case boolean
        case string
        case enumeration
        case number
        case path
        case secret
    }

    let id: String
    let type: ValueType
    let defaultValue: String?
    let allowedValues: [String]?
    let minimum: Double?
    let maximum: Double?
}

struct PluginManifest: Codable, Equatable, Sendable {
    let id: String
    let version: String
    let executable: String
    let capabilities: [PluginCapability]
    let minimumHostVersion: String?
    let settings: [PluginSettingDescriptor]?

    init(
        id: String,
        version: String,
        executable: String,
        capabilities: [PluginCapability],
        minimumHostVersion: String? = nil,
        settings: [PluginSettingDescriptor]? = nil
    ) {
        self.id = id
        self.version = version
        self.executable = executable
        self.capabilities = capabilities
        self.minimumHostVersion = minimumHostVersion
        self.settings = settings
    }
}

enum PluginInstallationError: Error, Equatable {
    case unsupportedSource
    case downloadFailed
    case archiveFailed
    case manifestNotFound
    case invalidManifest
    case invalidExecutable
}

/// Maintains the on-disk package/data boundary for future external plugins.
/// Installation is available before process loading: an installed plugin is
/// still disabled until a supervised runtime is connected.
@MainActor
final class PluginInstallationManager: ObservableObject {
    static let shared = PluginInstallationManager()

    @Published private(set) var installed: [PluginManifest] = []
    @Published private(set) var disabledIDs: Set<String> = []

    let pluginsDirectory: URL
    let dataDirectory: URL

    init(applicationSupport: URL? = nil) {
        let support = applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OMG", isDirectory: true)
        self.pluginsDirectory = support.appendingPathComponent("Plugins", isDirectory: true)
        self.dataDirectory = support.appendingPathComponent("PluginData", isDirectory: true)
        reload()
    }

    func reload() {
        installed = (try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { Self.readManifest(at: $0) } ?? []
        disabledIDs = Set(
            (try? JSONDecoder().decode(
                [String].self,
                from: Data(contentsOf: pluginsDirectory.appendingPathComponent("disabled.json"))
            )) ?? []
        )
    }

    func install(from repositoryURL: URL) async throws -> PluginManifest {
        guard repositoryURL.scheme == "https",
              repositoryURL.host == "github.com" else {
            throw PluginInstallationError.unsupportedSource
        }
        let components = repositoryURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { throw PluginInstallationError.unsupportedSource }
        let archiveURL = URL(string: "https://github.com/\(components[0])/\(components[1])/archive/refs/heads/main.tar.gz")!
        let (data, _) = try await URLSession.shared.data(from: archiveURL)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("plugin.tar.gz")
        try data.write(to: archive, options: .atomic)
        try Self.extract(archive: archive, into: temporary)

        guard let manifestURL = Self.findManifest(in: temporary),
              let manifest = Self.readManifest(at: manifestURL.deletingLastPathComponent()) else {
            throw PluginInstallationError.manifestNotFound
        }
        guard Self.valid(manifest) else { throw PluginInstallationError.invalidManifest }
        let packageDirectory = manifestURL.deletingLastPathComponent()
        let destination = pluginsDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: packageDirectory, to: destination)
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent(manifest.id), withIntermediateDirectories: true)
        reload()
        return manifest
    }

    func update(_ manifest: PluginManifest, from repositoryURL: URL) async throws {
        _ = try await install(from: repositoryURL)
    }

    func disable(_ pluginID: String) throws {
        disabledIDs.insert(pluginID)
        try persistDisabled()
    }

    func enable(_ pluginID: String) throws {
        disabledIDs.remove(pluginID)
        try persistDisabled()
    }

    func uninstall(_ pluginID: String, removeData: Bool = false) throws {
        try FileManager.default.removeItem(at: pluginsDirectory.appendingPathComponent(pluginID))
        if removeData {
            try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(pluginID))
        }
        disabledIDs.remove(pluginID)
        try persistDisabled()
        reload()
    }

    func dataURL(for pluginID: String) -> URL {
        dataDirectory.appendingPathComponent(pluginID, isDirectory: true)
    }

    private func persistDisabled() throws {
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(disabledIDs.sorted())
        try data.write(to: pluginsDirectory.appendingPathComponent("disabled.json"), options: .atomic)
    }

    private static func readManifest(at directory: URL) -> PluginManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    private static func findManifest(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return enumerator?.compactMap { $0 as? URL }.first {
            $0.lastPathComponent == "manifest.json"
        }
    }

    private static func extract(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PluginInstallationError.archiveFailed }
    }

    private static func valid(_ manifest: PluginManifest) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !manifest.id.isEmpty, manifest.id.count <= 128,
              manifest.id.unicodeScalars.allSatisfy(allowed.contains),
              !manifest.version.isEmpty,
              !manifest.executable.isEmpty,
              !manifest.executable.hasPrefix("/"),
              !manifest.executable.split(separator: "/").contains("..") else {
            return false
        }
        return true
    }
}

struct PluginAuthorizationPolicy: Sendable {
    let manifests: [String: PluginManifest]

    func authorize(
        _ hello: PluginHello,
        expectedPluginID: String,
        expectedNonce: String,
        hostVersion: String
    ) -> Result<PluginWelcome, PluginProtocolFailure> {
        guard hello.pluginID == expectedPluginID,
              hello.nonce == expectedNonce,
              let manifest = manifests[hello.pluginID],
              manifest.version == hello.pluginVersion else {
            return .failure(.init(code: .permissionDenied, message: "Plugin identity did not match"))
        }

        guard hello.supportedProtocolVersions.contains(PluginProtocolContract.currentVersion) else {
            return .failure(.init(code: .incompatibleVersion, message: "No supported protocol version"))
        }

        let allowed = Set(manifest.capabilities)
        let requested = Set(hello.requestedCapabilities)
        let granted = PluginCapability.allCases.filter {
            allowed.contains($0) && requested.contains($0)
        }
        return .success(.init(
            selectedProtocolVersion: PluginProtocolContract.currentVersion,
            grantedCapabilities: granted,
            hostVersion: hostVersion
        ))
    }
}

@MainActor
final class TabActivityStore: ObservableObject {
    struct Entry: Equatable, Sendable {
        let pluginID: String
        let revision: UInt64
        let status: PluginSessionStatus
        let expiresAt: Date?
    }

    private struct RevisionKey: Hashable {
        let pluginID: String
        let sessionID: UUID
    }

    static let maximumTTLMilliseconds: UInt64 = 86_400_000

    @Published private(set) var entries: [UUID: Entry] = [:]

    private var lastRevisions: [RevisionKey: UInt64] = [:]
    private var expirationWorkItems: [UUID: DispatchWorkItem] = [:]

    func status(for sessionID: UUID) -> PluginSessionStatus? {
        entries[sessionID]?.status
    }

    func activity(for sessionID: UUID) -> TabActivity? {
        entries[sessionID]?.status.activity
    }

    func set(
        _ command: PluginSetSessionStatus,
        pluginID: String,
        sessionExists: (UUID) -> Bool,
        now: Date = Date()
    ) -> PluginProtocolFailure? {
        guard sessionExists(command.sessionID) else {
            return .init(code: .sessionNotFound, message: "Session does not exist")
        }
        guard validate(command.status, ttlMilliseconds: command.ttlMilliseconds) else {
            return .init(code: .invalidMessage, message: "Invalid session status")
        }
        if let current = entries[command.sessionID], current.pluginID != pluginID {
            return .init(code: .permissionDenied, message: "Session status is owned by another plugin")
        }

        let revisionKey = RevisionKey(pluginID: pluginID, sessionID: command.sessionID)
        guard command.revision > (lastRevisions[revisionKey] ?? 0) else {
            return .init(code: .staleRevision, message: "Status revision is stale")
        }

        let expiresAt = command.ttlMilliseconds.map {
            now.addingTimeInterval(TimeInterval($0) / 1_000)
        }
        lastRevisions[revisionKey] = command.revision
        entries[command.sessionID] = .init(
            pluginID: pluginID,
            revision: command.revision,
            status: command.status,
            expiresAt: expiresAt
        )
        scheduleExpiration(for: command.sessionID, entry: entries[command.sessionID])
        return nil
    }

    func clear(
        _ command: PluginClearSessionStatus,
        pluginID: String
    ) -> PluginProtocolFailure? {
        if let current = entries[command.sessionID], current.pluginID != pluginID {
            return .init(code: .permissionDenied, message: "Session status is owned by another plugin")
        }

        let revisionKey = RevisionKey(pluginID: pluginID, sessionID: command.sessionID)
        guard command.revision > (lastRevisions[revisionKey] ?? 0) else {
            return .init(code: .staleRevision, message: "Status revision is stale")
        }

        lastRevisions[revisionKey] = command.revision
        removeEntry(for: command.sessionID)
        return nil
    }

    func removeSession(_ sessionID: UUID) {
        removeEntry(for: sessionID)
        lastRevisions = lastRevisions.filter { $0.key.sessionID != sessionID }
    }

    func disconnect(pluginID: String) {
        for sessionID in entries.compactMap({ $0.value.pluginID == pluginID ? $0.key : nil }) {
            removeEntry(for: sessionID)
        }
        lastRevisions = lastRevisions.filter { $0.key.pluginID != pluginID }
    }

    func removeExpired(at date: Date = Date()) {
        for (sessionID, entry) in entries where entry.expiresAt.map({ $0 <= date }) == true {
            removeEntry(for: sessionID)
        }
    }

    private func validate(_ status: PluginSessionStatus, ttlMilliseconds: UInt64?) -> Bool {
        let agent = status.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty, agent.count <= 64 else { return false }
        guard status.title?.count ?? 0 <= 256 else { return false }
        guard status.message?.count ?? 0 <= 512 else { return false }
        guard status.detail?.count ?? 0 <= 2_048 else { return false }
        guard status.progress.map({ (0...1).contains($0) }) ?? true else { return false }
        guard status.icon.map(validate) ?? true else { return false }
        guard ttlMilliseconds.map({ $0 > 0 && $0 <= Self.maximumTTLMilliseconds }) ?? true else {
            return false
        }
        return true
    }

    private func validate(_ icon: PluginTabIcon) -> Bool {
        let name = icon.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else { return false }
        guard name.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
                .contains($0)
        }) else {
            return false
        }
        if icon.kind == .bundledAsset {
            return Bundle.main.image(forResource: name) != nil
        }
        return true
    }

    private func scheduleExpiration(for sessionID: UUID, entry: Entry?) {
        expirationWorkItems.removeValue(forKey: sessionID)?.cancel()
        guard let entry, let expiresAt = entry.expiresAt else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.entries[sessionID] == entry else { return }
            self.removeExpired()
        }
        expirationWorkItems[sessionID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, expiresAt.timeIntervalSinceNow),
            execute: workItem
        )
    }

    private func removeEntry(for sessionID: UUID) {
        expirationWorkItems.removeValue(forKey: sessionID)?.cancel()
        entries.removeValue(forKey: sessionID)
    }
}

@MainActor
final class PluginMessageRouter {
    let pluginID: String
    let grantedCapabilities: Set<PluginCapability>

    private let statusStore: TabActivityStore
    private let sessionExists: (UUID) -> Bool
    private var nextSequence: UInt64 = 1

    init(
        pluginID: String,
        grantedCapabilities: Set<PluginCapability>,
        statusStore: TabActivityStore,
        sessionExists: @escaping (UUID) -> Bool
    ) {
        self.pluginID = pluginID
        self.grantedCapabilities = grantedCapabilities
        self.statusStore = statusStore
        self.sessionExists = sessionExists
    }

    func handle(_ message: PluginWireMessage) -> PluginWireMessage {
        guard message.version == PluginProtocolContract.currentVersion else {
            return response(
                to: message,
                body: .failure(.init(code: .incompatibleVersion, message: "Unsupported protocol version"))
            )
        }

        let failure: PluginProtocolFailure?
        switch message.body {
        case .setSessionStatus(let command):
            let iconFailure = command.status.icon == nil ? nil : require(.tabIcon)
            failure = require(.sessionStatus) ?? iconFailure ?? statusStore.set(
                command,
                pluginID: pluginID,
                sessionExists: sessionExists
            )
        case .clearSessionStatus(let command):
            failure = require(.sessionStatus) ?? statusStore.clear(command, pluginID: pluginID)
        default:
            failure = .init(code: .invalidMessage, message: "Message is not a plugin command")
        }

        if let failure {
            return response(to: message, body: .failure(failure))
        }
        return response(
            to: message,
            body: .acknowledgement(.init(acceptedSequence: message.sequence))
        )
    }

    func disconnect() {
        statusStore.disconnect(pluginID: pluginID)
    }

    private func require(_ capability: PluginCapability) -> PluginProtocolFailure? {
        guard grantedCapabilities.contains(capability) else {
            return .init(code: .permissionDenied, message: "Capability was not granted")
        }
        return nil
    }

    private func response(to request: PluginWireMessage, body: PluginWireMessage.Body) -> PluginWireMessage {
        defer { nextSequence += 1 }
        return .init(sequence: nextSequence, correlationID: request.sequence, body: body)
    }
}
