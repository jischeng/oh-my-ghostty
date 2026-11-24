import Combine
import Darwin
import Foundation
import os

// History belongs to the host, not an Agent transcript or a plugin. Surface and
// tab session UUIDs already survive session restoration; optional normalized
// location metadata enables orthogonal same-directory sharing without inferring
// ownership from titles or prompt text.
enum QuickInputHistoryScope: String, CaseIterable, Codable {
    case pane
    case tab
    case global
}

enum QuickInputHistoryDelivery: String, Codable {
    case queued
    case sent
    case cancelled
}

struct QuickInputHistoryLocation: Equatable, Hashable, Sendable {
    private static let normalizedHomeDirectory = normalizeLocalPath(NSHomeDirectory())

    let workingDirectory: String
    let remoteHostKey: String?

    init?(workingDirectory: String?, remoteHostKey: String? = nil) {
        guard let workingDirectory, !workingDirectory.isEmpty, !workingDirectory.contains("\0") else {
            return nil
        }
        let normalizedHost = Self.normalizedHostKey(remoteHostKey)
        let normalizedPath = normalizedHost == nil
            ? Self.normalizeLocalPath(workingDirectory)
            : Self.normalizeRemotePath(workingDirectory)
        guard !normalizedPath.isEmpty else { return nil }
        self.workingDirectory = normalizedPath
        self.remoteHostKey = normalizedHost
    }

    /// Pure in-memory initializer for already-normalized fields stored on
    /// `QuickInputHistoryEntry` so `visibleEntries` never touches the filesystem.
    init?(storedWorkingDirectory: String?, remoteHostKey: String?) {
        guard let storedWorkingDirectory, !storedWorkingDirectory.isEmpty else {
            return nil
        }
        self.workingDirectory = storedWorkingDirectory
        self.remoteHostKey = Self.normalizedHostKey(remoteHostKey)
    }

    static func from(_ context: PaneSessionContext?) -> Self? {
        guard let context else { return nil }
        switch context.state {
        case .local:
            return Self(workingDirectory: context.local.workingDirectory, remoteHostKey: nil)
        case .sshReady(let ssh, workingDirectory: let dir):
            guard let host = [ssh.serverID, ssh.transferTarget, ssh.alias]
                .compactMap(Self.normalizedHostKey)
                .first else {
                return nil
            }
            return Self(workingDirectory: dir, remoteHostKey: host)
        case .sshConnecting:
            return nil
        }
    }

    var displayPath: String {
        if let remoteHostKey {
            return "\(remoteHostKey):\(workingDirectory)"
        }
        let home = Self.normalizedHomeDirectory
        if workingDirectory == home {
            return "~"
        }
        if workingDirectory.hasPrefix(home + "/") {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }

    private static func normalizedHostKey(_ raw: String?) -> String? {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func normalizeLocalPath(_ raw: String) -> String {
        let standardized = URL(fileURLWithPath: raw).standardizedFileURL
        let resolved: String
        if FileManager.default.fileExists(atPath: standardized.path) {
            resolved = standardized.resolvingSymlinksInPath().path
        } else {
            resolved = standardized.path
        }
        return stripTrailingSlashes(resolved)
    }

    private static func normalizeRemotePath(_ raw: String) -> String {
        var segments: [Substring] = []
        let isAbsolute = raw.hasPrefix("/")
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !segments.isEmpty && segments.last != ".." {
                    segments.removeLast()
                } else if !isAbsolute {
                    segments.append(part)
                }
            } else {
                segments.append(part)
            }
        }
        let joined = segments.joined(separator: "/")
        if isAbsolute {
            return joined.isEmpty ? "/" : "/" + joined
        }
        return stripTrailingSlashes(joined)
    }

    private static func stripTrailingSlashes(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

struct QuickInputHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let paneID: UUID
    var tabID: UUID
    let text: String
    let sentAt: Date
    // Missing in version-1 archives written before queue history was added.
    var delivery: QuickInputHistoryDelivery?
    // Missing in version-1 archives written before directory sharing was added.
    var workingDirectory: String?
    var remoteHostKey: String?

    var deliveryState: QuickInputHistoryDelivery { delivery ?? .sent }
    var location: QuickInputHistoryLocation? {
        QuickInputHistoryLocation(storedWorkingDirectory: workingDirectory, remoteHostKey: remoteHostKey)
    }
}

@MainActor
final class QuickInputHistoryStore: ObservableObject {
    static let shared: QuickInputHistoryStore = {
        let settings = OhMyGhosttySettings.shared
        let store = QuickInputHistoryStore(
            fileURL: OMGApplicationEnvironment.applicationSupportURL()
                .appendingPathComponent("quick-input-history", isDirectory: true)
                .appendingPathComponent("history.json"),
            retentionDays: Int(settings.quickInputHistoryRetentionDays),
            keepsAfterQuit: settings.quickInputHistoryKeepAfterQuit
        )
        store.settingsObserver = settings.$quickInputHistoryRetentionDays
            .combineLatest(settings.$quickInputHistoryKeepAfterQuit)
            .sink { [weak store] days, keep in
                let days = days.isFinite ? Int(min(max(days.rounded(), 1), 365)) : 7
                store?.configure(retentionDays: days, keepsAfterQuit: keep)
            }
        store.cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak store] _ in
            MainActor.assumeIsolated { store?.pruneExpired() }
        }
        return store
    }()

    static let perPaneLimit = 50
    static let totalLimit = 1_000
    static let totalTextByteLimit = 8 * 1_024 * 1_024
    static let maximumEntryBytes = 1_024 * 1_024

    @Published private(set) var entries: [QuickInputHistoryEntry] = []
    @Published private(set) var storageError: String?
    private(set) var retentionDays: Int
    private(set) var keepsAfterQuit: Bool
    private let fileURL: URL?
    private let now: () -> Date
    private let diskQueue = DispatchQueue(label: "omg.quick-input-history.storage", qos: .utility)
    private var settingsObserver: AnyCancellable?
    private var cleanupTimer: Timer?

    private struct Archive: Codable {
        let version: Int
        let entries: [QuickInputHistoryEntry]
    }

    // No file URL means an isolated in-memory store (also used by model tests).
    init(fileURL: URL? = nil, retentionDays: Int = 7,
         keepsAfterQuit: Bool = true, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.retentionDays = min(max(retentionDays, 1), 365)
        self.keepsAfterQuit = keepsAfterQuit
        self.now = now
        if keepsAfterQuit, let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try Self.validatePath(fileURL)
                let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                // JSON can expand a control byte into six ASCII bytes (\u005cu0000).
                // Accept our own worst-case bounded archive, plus metadata.
                let maximumArchiveBytes = Self.totalTextByteLimit * 6 + 1_024 * 1_024
                guard size <= maximumArchiveBytes else { throw HistoryStorageError.invalidArchive }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard archive.version == 1 else { throw HistoryStorageError.invalidArchive }
                entries = bounded(archive.entries.map { entry in
                    var entry = entry
                    // Queues are in-memory pane state. A restored history item
                    // must not claim it is still waiting in a vanished queue.
                    if entry.deliveryState == .queued { entry.delivery = .cancelled }
                    // Normalize persisted location once on load so queries stay pure in-memory.
                    if let normalized = QuickInputHistoryLocation(
                        workingDirectory: entry.workingDirectory,
                        remoteHostKey: entry.remoteHostKey
                    ) {
                        entry.workingDirectory = normalized.workingDirectory
                        entry.remoteHostKey = normalized.remoteHostKey
                    } else {
                        entry.workingDirectory = nil
                        entry.remoteHostKey = nil
                    }
                    return entry
                })
            } catch {
                reportStorageError(error)
                // Do not destroy an unreadable archive just by launching.
                return
            }
        }
        persistSnapshot()
    }

    func configure(retentionDays: Int, keepsAfterQuit: Bool) {
        let days = min(max(retentionDays, 1), 365)
        guard days != self.retentionDays || keepsAfterQuit != self.keepsAfterQuit else { return }
        self.retentionDays = days
        self.keepsAfterQuit = keepsAfterQuit
        entries = bounded(entries)
        // Switching off retention removes the on-disk copy immediately through
        // the same serial writer, while current-process history remains usable.
        persistSnapshot()
    }

    func record(_ text: String, paneID: UUID, tabID: UUID,
                location: QuickInputHistoryLocation? = nil,
                id: UUID? = nil,
                delivery: QuickInputHistoryDelivery = .sent) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumEntryBytes else { return }
        var updated = entries
        var resolvedLocation = location
        if let id {
            if resolvedLocation == nil, let existing = updated.first(where: { $0.id == id }) {
                resolvedLocation = existing.location
            }
            updated.removeAll { $0.id == id }
        } else if let last = updated.lastIndex(where: { $0.paneID == paneID && $0.deliveryState == .sent }),
                  updated[last].text == text {
            if resolvedLocation == nil {
                resolvedLocation = updated[last].location
            }
            updated.remove(at: last)
        }
        updated.append(.init(id: id ?? UUID(), paneID: paneID, tabID: tabID, text: text,
                             sentAt: now(), delivery: delivery,
                             workingDirectory: resolvedLocation?.workingDirectory,
                             remoteHostKey: resolvedLocation?.remoteHostKey))
        entries = bounded(updated)
        persistSnapshot()
    }

    func cancelQueuedEntry(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.deliveryState == .queued }) else { return }
        entries[index].delivery = .cancelled
        persistSnapshot()
    }

    // Pane moves retain their history and join the destination tab's scope.
    func bind(paneIDs: Set<UUID>, to tabID: UUID) {
        guard entries.contains(where: { paneIDs.contains($0.paneID) && $0.tabID != tabID }) else { return }
        entries = entries.map { entry in
            var entry = entry
            if paneIDs.contains(entry.paneID) { entry.tabID = tabID }
            return entry
        }
        persistSnapshot()
    }

    func visibleEntries(paneID: UUID?, tabID: UUID, scope: QuickInputHistoryScope,
                        location: QuickInputHistoryLocation? = nil,
                        shareByDirectory: Bool = false,
                        query: String = "") -> [QuickInputHistoryEntry] {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seenTexts = Set<String>()
        return entries.reversed().filter { entry in
            let matchesDirectory = shareByDirectory && location != nil && entry.location == location
            let visible: Bool
            switch scope {
            case .pane: visible = entry.paneID == paneID || matchesDirectory
            case .tab: visible = entry.tabID == tabID || matchesDirectory
            case .global: visible = true
            }
            guard visible && entry.sentAt > cutoff &&
                (query.isEmpty || entry.text.localizedStandardContains(query)) else {
                return false
            }
            return seenTexts.insert(entry.text).inserted
        }
    }

    func pruneExpired() {
        let updated = bounded(entries)
        guard updated != entries else { return }
        entries = updated
        persistSnapshot()
    }

    func clear() {
        entries = []
        persistSnapshot()
    }

    /// Termination must drain pending atomic writes (or deletes) before exit.
    func flushPendingWrites() {
        diskQueue.sync {}
    }

    private func bounded(_ candidates: [QuickInputHistoryEntry]) -> [QuickInputHistoryEntry] {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        var counts: [UUID: Int] = [:]
        var seenIDs = Set<UUID>()
        var bytes = 0
        var result: [QuickInputHistoryEntry] = []
        for entry in candidates.reversed() {
            let size = entry.text.utf8.count
            guard entry.sentAt > cutoff, entry.sentAt <= now(),
                  !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  size <= Self.maximumEntryBytes, seenIDs.insert(entry.id).inserted,
                  counts[entry.paneID, default: 0] < Self.perPaneLimit,
                  result.count < Self.totalLimit, bytes + size <= Self.totalTextByteLimit else { continue }
            result.append(entry)
            bytes += size
            counts[entry.paneID, default: 0] += 1
        }
        return result.reversed()
    }

    private func persistSnapshot() {
        guard let fileURL else { return }
        let snapshot = entries
        let keep = keepsAfterQuit
        diskQueue.async { [weak self] in
            do {
                if keep && !snapshot.isEmpty {
                    let data = try JSONEncoder().encode(Archive(version: 1, entries: snapshot))
                    try Self.writePrivateArchive(data, to: fileURL)
                } else if FileManager.default.fileExists(atPath: fileURL.path) {
                    try Self.validatePath(fileURL)
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                Task { @MainActor [weak self] in self?.reportStorageError(error) }
            }
        }
    }

    private func reportStorageError(_ error: Error) {
        storageError = "Could not save or load Quick Input history."
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty", category: "quick-input-history")
            .error("History storage failed: \(error.localizedDescription, privacy: .private)")
    }

    private enum HistoryStorageError: Error {
        case invalidArchive
        case unsafePath
        case writeFailed
    }

    nonisolated private static func validatePath(_ fileURL: URL) throws {
        for url in [fileURL.deletingLastPathComponent(), fileURL]
        where FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw HistoryStorageError.unsafePath }
        }
    }

    nonisolated private static func writePrivateArchive(_ data: Data, to fileURL: URL) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try validatePath(fileURL)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw HistoryStorageError.writeFailed
        }
        guard rename(temporary.path, fileURL.path) == 0 else { throw HistoryStorageError.writeFailed }
    }
}
