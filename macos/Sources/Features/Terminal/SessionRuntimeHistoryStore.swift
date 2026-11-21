import CryptoKit
import Darwin
import Foundation
import GhosttyKit

/// Bounded owner-only (`0600`) JSON sidecar preserving recent `OSC 133` command
/// metadata and `OSC 7` working directories across `omgd` session detach/reattach.
enum SessionRuntimeHistoryStore {
    static let maximumBytes = 256 * 1024
    static let maxCommands = 100
    static let maxDirectories = 64
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    struct DirectoryEntry: Codable, Equatable, Sendable {
        let path: String
        let updatedAt: Date
    }

    struct Record: Codable, Equatable {
        let version: Int
        let paneID: UUID
        let runtimeIdentity: String
        let updatedAt: Date
        var commands: [ShellScrollbackRestoreStore.SavedCommand]
        var directories: [DirectoryEntry]
    }

    static func directory(baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()) -> URL {
        baseURL.appendingPathComponent("session-runtime-history", isDirectory: true)
    }

    static func storageKey(runtimeIdentity: String, paneID: UUID) -> String {
        let input = "\(runtimeIdentity)\0\(paneID.uuidString.lowercased())"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func fileURL(
        for descriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) -> URL {
        let key = storageKey(runtimeIdentity: descriptor.identity, paneID: paneID)
        return directory(baseURL: baseURL).appendingPathComponent("\(key).json")
    }

    @discardableResult
    static func save(
        commands: [InspectorHistoryItem],
        workingDirectory: String?,
        for descriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL(),
        now: Date = Date()
    ) -> Bool {
        let root = directory(baseURL: baseURL)
        guard ensurePrivateDirectory(root) else { return false }

        let existing = load(for: descriptor, paneID: paneID, baseURL: baseURL, now: now)
        let savedCommands: [ShellScrollbackRestoreStore.SavedCommand]
        if commands.isEmpty, let previousCommands = existing?.commands, !previousCommands.isEmpty {
            savedCommands = Array(previousCommands.prefix(maxCommands))
        } else {
            savedCommands = Array(commands.prefix(maxCommands))
                .map(ShellScrollbackRestoreStore.SavedCommand.init)
        }

        var directories = existing?.directories ?? []
        if let cwd = normalizedDirectory(workingDirectory) {
            if directories.last?.path != cwd {
                directories.removeAll { $0.path == cwd }
                directories.append(DirectoryEntry(path: cwd, updatedAt: now))
                if directories.count > maxDirectories {
                    directories.removeFirst(directories.count - maxDirectories)
                }
            }
        }

        guard !savedCommands.isEmpty || !directories.isEmpty else { return false }

        let record = Record(
            version: 1,
            paneID: paneID,
            runtimeIdentity: descriptor.identity,
            updatedAt: now,
            commands: savedCommands,
            directories: directories
        )
        guard let payload = try? JSONEncoder().encode(record),
              payload.count <= maximumBytes else {
            return false
        }

        let target = fileURL(for: descriptor, paneID: paneID, baseURL: baseURL)
        let staging = root.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try SessionRuntimeBridgeStorage.writePrivateFile(at: staging, data: payload, permissions: 0o600)
            guard rename(staging.path, target.path) == 0 else { return false }
            return true
        } catch {
            return false
        }
    }

    static func load(
        for descriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL(),
        now: Date = Date()
    ) -> Record? {
        let target = fileURL(for: descriptor, paneID: paneID, baseURL: baseURL)
        guard let data = try? SessionRuntimeBridgeStorage.readPrivateFile(
            at: target,
            maximumSize: maximumBytes
        ),
        let record = try? JSONDecoder().decode(Record.self, from: data),
        record.version == 1,
        record.paneID == paneID,
        record.runtimeIdentity == descriptor.identity else {
            return nil
        }
        if now.timeIntervalSince(record.updatedAt) > lifetime {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        return record
    }

    static func remove(
        for descriptor: SessionRuntimeDescriptor,
        paneID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) {
        let target = fileURL(for: descriptor, paneID: paneID, baseURL: baseURL)
        try? FileManager.default.removeItem(at: target)
    }

    /// The runtime's own restore banner. Earlier builds rebuilt it from a
    /// snapshot as if it were a command and then saved it; it never was one.
    static let restoreBannerMarker = "Session resurrected after system restart · "

    /// Reconciles VT-reconstructed live `OSC 133` commands (newest-first) against
    /// persisted runtime command metadata so original timestamps, outcomes and
    /// labels survive reattach and older scrolled-out commands remain visible as
    /// archived entries.
    ///
    /// Rows are aligned in order rather than required to match as one unbroken
    /// run: a single row present on only one side (a command the terminal no
    /// longer shows, or one typed since the last save) must not discard every
    /// other row's metadata and list the saved rows a second time.
    static func reconcile(
        liveNewestFirst: [InspectorHistoryItem],
        with savedNewestFirst: [ShellScrollbackRestoreStore.SavedCommand],
        surfaceID: UUID
    ) -> [InspectorHistoryItem] {
        let saved = savedNewestFirst.filter { !$0.text.contains(restoreBannerMarker) }
        guard !saved.isEmpty else { return liveNewestFirst }
        if liveNewestFirst.isEmpty {
            return archivedItems(from: saved, startIndex: 0, surfaceID: surfaceID)
        }

        let pairs = alignment(liveNewestFirst.map(\.text), saved.map(\.text))
        var result = liveNewestFirst
        var matchedSaved = Set<Int>()
        for (liveIndex, savedIndex) in pairs {
            let item = result[liveIndex]
            let record = saved[savedIndex]
            matchedSaved.insert(savedIndex)
            result[liveIndex] = InspectorHistoryItem(
                id: item.id,
                kind: item.kind,
                text: item.text,
                timestamp: record.timestamp ?? item.timestamp,
                exitCode: item.exitCode ?? record.exitCode,
                duration: item.duration ?? record.duration,
                promptIndex: item.promptIndex,
                location: item.location,
                sourceLabel: record.sourceLabel ?? item.sourceLabel,
                replayKey: item.replayKey ?? record.occurrenceID
            )
        }

        let seenIDs = Set(result.compactMap { $0.replayKey ?? $0.id })
        let archived = saved.indices.filter { !matchedSaved.contains($0) }.map { index in
            archivedItems(from: [saved[index]], startIndex: index, surfaceID: surfaceID)[0]
        }.filter { !seenIDs.contains($0.id) }

        return Array((result + archived).prefix(maxCommands))
    }

    /// Longest in-order pairing of equal texts. Among equally long pairings it
    /// keeps the oldest live rows and the newest saved rows, which is where a
    /// reattached terminal and its saved record overlap: commands typed since
    /// the save lead the live list, and scrolled-out ones trail the saved list.
    static func alignment(_ live: [String], _ saved: [String]) -> [(live: Int, saved: Int)] {
        guard !live.isEmpty, !saved.isEmpty else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: saved.count + 1), count: live.count + 1)
        for i in 1...live.count {
            for j in 1...saved.count {
                lengths[i][j] = live[i - 1] == saved[j - 1]
                    ? lengths[i - 1][j - 1] + 1
                    : max(lengths[i - 1][j], lengths[i][j - 1])
            }
        }
        var pairs: [(live: Int, saved: Int)] = []
        var i = live.count
        var j = saved.count
        while i > 0, j > 0 {
            if live[i - 1] == saved[j - 1] {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if lengths[i][j - 1] >= lengths[i - 1][j] {
                j -= 1
            } else {
                i -= 1
            }
        }
        return pairs.reversed()
    }

    @MainActor
    static func seedRestoredWorkingDirectoryIfNeeded(
        on surfaceView: Ghostty.SurfaceView,
        descriptor: SessionRuntimeDescriptor,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) -> String? {
        guard let record = load(for: descriptor, paneID: surfaceView.id, baseURL: baseURL),
              let latest = record.directories.last?.path,
              let valid = normalizedDirectory(latest) else {
            return nil
        }
        if surfaceView.pwd == nil || surfaceView.pwd?.isEmpty == true {
            surfaceView.pwd = valid
        }
        if let rawSurface = surfaceView.surface {
            valid.withCString { ptr in
                _ = ghostty_surface_omg_seed_cwd_if_empty(rawSurface, ptr, UInt(valid.utf8.count))
            }
        }
        return valid
    }

    private static func archivedItems(
        from saved: [ShellScrollbackRestoreStore.SavedCommand],
        startIndex: Int,
        surfaceID: UUID
    ) -> [InspectorHistoryItem] {
        saved.enumerated().map { idx, command in
            InspectorHistoryItem(
                id: command.occurrenceID ?? "runtime-archived:\(surfaceID.uuidString):\(startIndex + idx)",
                kind: .command,
                text: command.text,
                timestamp: command.timestamp,
                exitCode: command.exitCode,
                duration: command.duration,
                location: .unavailable(.expired),
                sourceLabel: command.sourceLabel
            )
        }
    }

    private static func normalizedDirectory(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.contains("\0"), value.utf8.count <= 4096 else {
            return nil
        }
        if value.hasPrefix("file:") {
            guard let path = URL(string: value)?.path, path.hasPrefix("/") else { return nil }
            return path
        }
        guard value.hasPrefix("/") else { return nil }
        return value
    }

    private static func ensurePrivateDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return false }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}
