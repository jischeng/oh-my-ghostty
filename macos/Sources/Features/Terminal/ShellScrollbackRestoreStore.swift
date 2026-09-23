import Darwin
import Foundation
import GhosttyKit
import OSLog

/// Bounded scrollback and OSC-anchored command metadata for restored local Shell panes.
/// Restored PTYs are new processes; this store never attempts to resume a job.
@MainActor
enum ShellScrollbackRestoreStore {
    static let environmentKey = "OH_MY_GHOSTTY_RESTORE_SCROLLBACK_FILE"
    static let maximumBytes = 2 * 1_024 * 1_024
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private static var restoredSurfaceIDs = Set<UUID>()
    private static var savedCommandCache: [UUID: [SavedCommand]] = [:]

    struct SavedCommand: Codable, Equatable {
        let text: String
        let timestamp: Date?
    }

    private struct CommandArchive: Codable {
        let version: Int
        let surfaceID: UUID
        let commands: [SavedCommand]
    }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
                                       category: "shell-scrollback-restore")

    static func directory(baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()) -> URL {
        baseURL.appendingPathComponent("shell-scrollback", isDirectory: true)
    }

    static func captureOpenSurfaces(
        controllers: [TerminalController] = TerminalController.all,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) {
        guard OhMyGhosttySettings.shared.restoreSessionsOnLaunch else { return }
        let root = directory(baseURL: baseURL)
        guard secureDirectory(root) else { return }
        removeExpired(in: root)

        for controller in controllers where controller.window?.isRestorable == true {
            for view in controller.surfaceTree {
                guard view.agentResumeDescriptor == nil, view.sshResumeDescriptor == nil,
                      controller.agentActivity(for: view) == nil,
                      let context = controller.paneSessionContext(for: view),
                      case .local = context.state,
                      let surface = view.surface else { continue }
                let commands = TerminalHistoryService.shared.commands(for: view.id)
                if !save(surfaceID: view.id, baseURL: baseURL, commands: commands, export: { temporary in
                    temporary.path.withCString {
                        ghostty_surface_omg_export_scrollback_vt(surface, $0, maximumBytes - 256)
                    }
                }) {
                    logger.warning("failed to capture shell scrollback for surface \(view.id.uuidString, privacy: .public)")
                }
            }
        }
    }

    @discardableResult
    static func save(
        surfaceID: UUID,
        baseURL: URL,
        commands: [InspectorHistoryItem] = [],
        export: (URL) -> Bool
    ) -> Bool {
        let root = directory(baseURL: baseURL)
        guard secureDirectory(root) else { return false }
        let temporary = root.appendingPathComponent("\(UUID().uuidString).partial")
        let metadata = root.appendingPathComponent("\(UUID().uuidString).partial")
        let target = root.appendingPathComponent("\(surfaceID.uuidString).vt")
        let metadataTarget = root.appendingPathComponent("\(surfaceID.uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: metadata)
        }
        // A failed new capture must not replay an older snapshot for the same
        // restored UUID on the next launch.
        func invalidateOldCapture() {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: metadataTarget)
        }
        guard export(temporary), appendQuitMarker(to: temporary), validFile(temporary) else {
            invalidateOldCapture()
            return false
        }
        let archive = CommandArchive(version: 1, surfaceID: surfaceID, commands: commands.map {
            .init(text: $0.text, timestamp: $0.timestamp)
        })
        guard let data = try? JSONEncoder().encode(archive),
              data.count <= maximumBytes,
              FileManager.default.createFile(atPath: metadata.path, contents: data,
                  attributes: [.posixPermissions: 0o600]), validFile(metadata) else {
            invalidateOldCapture()
            return false
        }
        guard rename(temporary.path, target.path) == 0 else {
            invalidateOldCapture()
            return false
        }
        guard rename(metadata.path, metadataTarget.path) == 0 else {
            invalidateOldCapture()
            return false
        }
        return true
    }

    /// A restored Surface UUID is the only key. Do not accept a caller-supplied
    /// path, symlink, directory, oversized file, or stale snapshot.
    static func replayFile(
        for surfaceID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL(),
        now: Date = Date(),
        restoreEnabled: Bool? = nil
    ) -> URL? {
        guard restoreEnabled ?? OhMyGhosttySettings.shared.restoreSessionsOnLaunch else { return nil }
        let root = directory(baseURL: baseURL)
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let file = root.appendingPathComponent("\(surfaceID.uuidString).vt")
        guard validFile(file, now: now) else { return nil }
        restoredSurfaceIDs.insert(surfaceID)
        return file
    }

    /// An old timestamp is attached only when the command text and occurrence
    /// order exactly match the replayed OSC 133 records on this same Surface.
    static func savedCommands(
        for surfaceID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) -> [SavedCommand]? {
        guard restoredSurfaceIDs.contains(surfaceID) else { return nil }
        if let cached = savedCommandCache[surfaceID] { return cached }
        let root = directory(baseURL: baseURL)
        // The shell removes the VT file only after replay. A missing shell
        // integration must never make later, coincidentally equal commands
        // inherit old timestamps or identities.
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "\(surfaceID.uuidString).vt").path) else { return nil }
        let file = root.appendingPathComponent("\(surfaceID.uuidString).json")
        guard validFile(file), let data = try? Data(contentsOf: file),
              let archive = try? JSONDecoder().decode(CommandArchive.self, from: data),
              archive.version == 1, archive.surfaceID == surfaceID,
              archive.commands.count <= 100,
              archive.commands.allSatisfy({ $0.text.utf8.count <= 16_384 }) else { return nil }
        savedCommandCache[surfaceID] = archive.commands
        return archive.commands
    }

    private static func appendQuitMarker(to file: URL) -> Bool {
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let marker = "\u{001B}]8;;\u{001B}\\\u{001B}[0m\r\n--- Quitted at \(formatter.string(from: Date())) ---\r\n"
            try handle.write(contentsOf: Data(marker.utf8))
            return true
        } catch {
            return false
        }
    }

    private static func validFile(_ file: URL, now: Date = Date()) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size > 0, size <= maximumBytes,
            let modified = values.contentModificationDate,
            now.timeIntervalSince(modified) >= -60,
            now.timeIntervalSince(modified) <= lifetime,
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let mode = attributes[.posixPermissions] as? NSNumber,
            mode.intValue & 0o077 == 0,
            let owner = attributes[.ownerAccountID] as? NSNumber,
            owner.uint32Value == geteuid() else { return false }
        return true
    }

    private static func secureDirectory(_ root: URL) -> Bool {
        let files = FileManager.default
        do {
            if !files.fileExists(atPath: root.path) {
                try files.createDirectory(at: root, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
            }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            return true
        } catch {
            logger.error("unable to prepare scrollback directory: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func removeExpired(in root: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for file in files where ["vt", "json", "partial"].contains(file.pathExtension) {
            if file.pathExtension == "partial" || !validFile(file) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
