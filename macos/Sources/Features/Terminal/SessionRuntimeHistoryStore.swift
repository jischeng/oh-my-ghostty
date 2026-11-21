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

    /// Reconciles VT-reconstructed live `OSC 133` commands (newest-first) against
    /// persisted runtime command metadata so original timestamps/labels survive
    /// reattach and older scrolled-out commands remain visible as archived entries.
    static func reconcile(
        liveNewestFirst: [InspectorHistoryItem],
        with savedNewestFirst: [ShellScrollbackRestoreStore.SavedCommand],
        surfaceID: UUID
    ) -> [InspectorHistoryItem] {
        guard !savedNewestFirst.isEmpty else { return liveNewestFirst }
        if liveNewestFirst.isEmpty {
            return archivedItems(from: savedNewestFirst, startIndex: 0, surfaceID: surfaceID)
        }

        // Find the longest suffix of `liveNewestFirst` (the reconstructed commands
        // predating any newly executed post-attach commands) matching a prefix of `savedNewestFirst`.
        var matchedCount = 0
        var matchedLiveOffset = liveNewestFirst.count
        for offset in 0..<liveNewestFirst.count {
            let candidateCount = liveNewestFirst.count - offset
            guard candidateCount <= savedNewestFirst.count else { continue }
            let liveSlice = liveNewestFirst[offset...]
            let savedSlice = savedNewestFirst.prefix(candidateCount)
            if zip(liveSlice, savedSlice).allSatisfy({ $0.text == $1.text }) {
                matchedCount = candidateCount
                matchedLiveOffset = offset
                break
            }
        }

        var result = liveNewestFirst
        if matchedCount > 0 {
            for idx in 0..<matchedCount {
                let item = result[matchedLiveOffset + idx]
                let saved = savedNewestFirst[idx]
                result[matchedLiveOffset + idx] = InspectorHistoryItem(
                    id: item.id,
                    kind: item.kind,
                    text: item.text,
                    timestamp: saved.timestamp ?? item.timestamp,
                    exitCode: item.exitCode ?? saved.exitCode,
                    duration: item.duration ?? saved.duration,
                    promptIndex: item.promptIndex,
                    location: item.location,
                    sourceLabel: saved.sourceLabel ?? item.sourceLabel,
                    replayKey: item.replayKey ?? saved.occurrenceID
                )
            }
        }

        let remainingSaved = Array(savedNewestFirst.dropFirst(matchedCount))
        let seenIDs = Set(result.compactMap { $0.replayKey ?? $0.id })
        let archived = archivedItems(
            from: remainingSaved,
            startIndex: matchedCount,
            surfaceID: surfaceID
        ).filter { !seenIDs.contains($0.id) }

        return Array((result + archived).prefix(maxCommands))
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
