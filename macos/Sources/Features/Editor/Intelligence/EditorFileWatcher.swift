import CryptoKit
import Darwin
import Foundation

/// Snapshot of an external disk modification detected for an open editor document.
struct EditorExternalFileChange: Equatable, Sendable {
    let path: String
    let data: Data
    /// Normalized `\n` UTF-8 text when the file is valid non-binary UTF-8; `nil` for binary/non-UTF-8 data.
    let text: String?
    let encoding: EditorDocumentEncoding?

    static func fromDiskData(_ data: Data, path: String) -> EditorExternalFileChange {
        if let decoded = Self.decodeUTF8Text(data) {
            return EditorExternalFileChange(
                path: path,
                data: data,
                text: decoded.text,
                encoding: decoded.encoding
            )
        }
        return EditorExternalFileChange(path: path, data: data, text: nil, encoding: nil)
    }

    private struct DecodedPayload {
        let text: String
        let encoding: EditorDocumentEncoding
    }

    private static func decodeUTF8Text(_ data: Data) -> DecodedPayload? {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = data.starts(with: bom)
        let content = hasBOM ? data.dropFirst(bom.count) : data[...]
        let containsBinaryControl = content.contains { byte in
            byte == 0 || byte < 0x08 || (byte > 0x0D && byte < 0x20)
        }
        guard !containsBinaryControl, let raw = String(data: content, encoding: .utf8) else {
            return nil
        }
        let newline: EditorDocumentEncoding.Newline
        if raw.contains("\r\n") {
            newline = .carriageReturnLineFeed
        } else if raw.contains("\r") {
            newline = .carriageReturn
        } else {
            newline = .lineFeed
        }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return DecodedPayload(
            text: normalized,
            encoding: EditorDocumentEncoding(hasUTF8ByteOrderMark: hasBOM, newline: newline)
        )
    }
}

/// Atomic-write-safe external file-change watcher for local files plus async focus refresh for SSH/remote files.
///
/// AI coding agents (Claude Code, Codex), `vim`, `sed -i`, and `git` write to a temporary file and `rename()`
/// over the target path, replacing its inode. `EditorFileWatcher` watches both the parent directory and the
/// target file descriptor (`O_EVTONLY`), automatically re-arms on inode replacement, debounces bursts (120ms
/// by default), and hashes disk `Data` off the main thread against the document's persisted snapshot so
/// self-saves never false-trigger.
@MainActor
final class EditorFileWatcher {
    nonisolated static let maximumWatchedFileBytes = 10 * 1_024 * 1_024

    var onExternalChange: ((EditorExternalFileChange) -> Void)?
    /// Optional main-actor hook allowing the host to supply the latest persisted `Data` for a path.
    var expectedDataProvider: ((String) -> Data?)?

    private let core: WatcherCore

    var watchedPaths: Set<String> {
        core.currentWatchedPaths()
    }

    init(
        debounceInterval: TimeInterval = 0.12,
        onExternalChange: ((EditorExternalFileChange) -> Void)? = nil
    ) {
        self.onExternalChange = onExternalChange
        self.core = WatcherCore(debounceInterval: max(0.01, debounceInterval))
        self.core.onCandidateChange = { [weak self] change in
            Task { @MainActor [weak self] in
                self?.deliverCandidate(change)
            }
        }
    }

    deinit {
        core.stopAll()
    }

    /// Starts or updates atomic-write-safe local kqueue watching for `path`.
    /// Only local absolute paths should be passed; SSH documents use `checkExternalChange(...)`.
    func watchLocalFile(path: String, expectedData: Data) {
        guard path.hasPrefix("/"), !path.contains("\0") else { return }
        core.watch(path: path, expectedDigest: Self.sha256(expectedData))
    }

    /// Updates the known persisted snapshot for `path` (e.g. before/after `EditorDocument.save()` or reload)
    /// so self-saves never trigger `onExternalChange`.
    func updateExpectedData(_ data: Data, forPath path: String) {
        core.updateExpectedDigest(Self.sha256(data), forPath: path)
    }

    /// Pre-registers bytes about to be written by OMG's own save pipeline so a fast kernel notification
    /// arriving before `writeFile` returns to `@MainActor` is suppressed.
    func recordPendingSelfSave(_ data: Data, forPath path: String) {
        core.recordAllowedSelfSaveDigest(Self.sha256(data), forPath: path)
    }

    func unwatch(path: String) {
        core.unwatch(path: path)
    }

    func stopAll() {
        core.stopAll()
    }

    /// Checks whether `path` on `filesystem` (remote SSH or local focus-regain check) differs from `expectedData`.
    /// Performs read and UTF-8/hash comparison off the main thread; returns `nil` when unchanged or unreadable.
    func checkExternalChange(
        path: String,
        filesystem: any WorkspaceFilesystem,
        expectedData: Data
    ) async -> EditorExternalFileChange? {
        let expectedDigest = Self.sha256(expectedData)
        let diskData: Data
        do {
            diskData = try await filesystem.readFile(at: path)
        } catch {
            return nil
        }
        let change: EditorExternalFileChange? = await Task.detached(priority: .utility) {
            let diskDigest = Self.sha256(diskData)
            guard diskDigest != expectedDigest else { return nil }
            return EditorExternalFileChange.fromDiskData(diskData, path: path)
        }.value

        if let change {
            core.markDeliveredDigest(Self.sha256(change.data), forPath: path)
        }
        return change
    }

    private func deliverCandidate(_ change: EditorExternalFileChange) {
        guard core.isWatching(path: change.path) else { return }
        if let latestExpected = expectedDataProvider?(change.path) {
            let latestDigest = Self.sha256(latestExpected)
            let candidateDigest = Self.sha256(change.data)
            if latestDigest == candidateDigest {
                core.updateExpectedDigest(latestDigest, forPath: change.path)
                return
            }
        }
        onExternalChange?(change)
    }

    nonisolated fileprivate static func sha256(_ data: Data) -> SHA256.Digest {
        SHA256.hash(data: data)
    }
}

// MARK: - Off-Main-Thread DispatchSource Engine

private final class WatcherCore: @unchecked Sendable {
    private struct FileInode: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private final class WatchedEntry {
        let path: String
        let parentDirectoryPath: String
        var expectedDigest: SHA256.Digest
        var allowedSelfSaveDigests: Set<SHA256.Digest> = []
        var lastDeliveredDigest: SHA256.Digest?
        var parentSource: DispatchSourceFileSystemObject?
        var fileSource: DispatchSourceFileSystemObject?
        var fileInode: FileInode?
        var debounceWorkItem: DispatchWorkItem?
        var transientMissingRetries = 0

        init(path: String, parentDirectoryPath: String, expectedDigest: SHA256.Digest) {
            self.path = path
            self.parentDirectoryPath = parentDirectoryPath
            self.expectedDigest = expectedDigest
        }
    }

    var onCandidateChange: (@Sendable (EditorExternalFileChange) -> Void)?

    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.ohmyghostty.editor.file-watcher", qos: .utility)
    private let stateLock = NSLock()
    private var watchedPathSet: Set<String> = []
    private var entries: [String: WatchedEntry] = [:]

    init(debounceInterval: TimeInterval) {
        self.debounceInterval = debounceInterval
    }

    func currentWatchedPaths() -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return watchedPathSet
    }

    func isWatching(path: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return watchedPathSet.contains(path)
    }

    func watch(path: String, expectedDigest: SHA256.Digest) {
        stateLock.lock()
        watchedPathSet.insert(path)
        stateLock.unlock()

        queue.async { [weak self] in
            self?.installOrUpdateWatchOnQueue(path: path, expectedDigest: expectedDigest)
        }
    }

    func updateExpectedDigest(_ digest: SHA256.Digest, forPath path: String) {
        queue.async { [weak self] in
            guard let entry = self?.entries[path] else { return }
            entry.expectedDigest = digest
            entry.allowedSelfSaveDigests.insert(digest)
            if entry.allowedSelfSaveDigests.count > 8 {
                entry.allowedSelfSaveDigests.removeAll()
                entry.allowedSelfSaveDigests.insert(digest)
            }
            entry.lastDeliveredDigest = nil
        }
    }

    func recordAllowedSelfSaveDigest(_ digest: SHA256.Digest, forPath path: String) {
        queue.async { [weak self] in
            guard let entry = self?.entries[path] else { return }
            entry.allowedSelfSaveDigests.insert(digest)
        }
    }

    func markDeliveredDigest(_ digest: SHA256.Digest, forPath path: String) {
        queue.async { [weak self] in
            guard let entry = self?.entries[path] else { return }
            entry.lastDeliveredDigest = digest
        }
    }

    func unwatch(path: String) {
        stateLock.lock()
        watchedPathSet.remove(path)
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self, let entry = self.entries.removeValue(forKey: path) else { return }
            self.teardownEntryOnQueue(entry)
        }
    }

    func stopAll() {
        stateLock.lock()
        watchedPathSet.removeAll()
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let allEntries = Array(self.entries.values)
            self.entries.removeAll()
            for entry in allEntries {
                self.teardownEntryOnQueue(entry)
            }
        }
    }

    // MARK: - Queue-Confined Operations

    private func installOrUpdateWatchOnQueue(path: String, expectedDigest: SHA256.Digest) {
        guard isWatching(path: path) else { return }

        if let existing = entries[path] {
            existing.expectedDigest = expectedDigest
            existing.lastDeliveredDigest = nil
            rearmFileSourceIfNeededOnQueue(for: existing)
            return
        }

        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
        let entry = WatchedEntry(
            path: path,
            parentDirectoryPath: parentURL.path,
            expectedDigest: expectedDigest
        )
        entries[path] = entry
        armParentSourceOnQueue(for: entry)
        rearmFileSourceIfNeededOnQueue(for: entry)
    }

    private func armParentSourceOnQueue(for entry: WatchedEntry) {
        guard entry.parentSource == nil else { return }
        let fd = Darwin.open(entry.parentDirectoryPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .link],
            queue: queue
        )
        let watchedPath = entry.path
        source.setEventHandler { [weak self] in
            guard let self, let current = self.entries[watchedPath] else { return }
            self.rearmFileSourceIfNeededOnQueue(for: current)
            self.scheduleEvaluationOnQueue(for: current, delay: self.debounceInterval)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        entry.parentSource = source
        source.resume()
    }

    private func rearmFileSourceIfNeededOnQueue(for entry: WatchedEntry) {
        let resolvedFilePath = Self.resolvedTargetPath(for: entry.path)
        let currentStat = Self.statInode(atPath: resolvedFilePath)

        if let existingInode = entry.fileInode,
           entry.fileSource != nil,
           existingInode == currentStat {
            return
        }

        if let oldSource = entry.fileSource {
            entry.fileSource = nil
            entry.fileInode = nil
            oldSource.cancel()
        }

        guard currentStat != nil else { return }
        let fd = Darwin.open(resolvedFilePath, O_EVTONLY)
        guard fd >= 0 else { return }
        guard let openedInode = Self.fstatInode(fd: fd) else {
            Darwin.close(fd)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .link, .revoke],
            queue: queue
        )
        let watchedPath = entry.path
        source.setEventHandler { [weak self, weak source] in
            guard let self, let current = self.entries[watchedPath] else { return }
            let flags = source?.data ?? []
            if !flags.isDisjoint(with: [.delete, .rename, .link, .revoke]) {
                if let stale = current.fileSource {
                    current.fileSource = nil
                    current.fileInode = nil
                    stale.cancel()
                }
                self.rearmFileSourceIfNeededOnQueue(for: current)
            }
            self.scheduleEvaluationOnQueue(for: current, delay: self.debounceInterval)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        entry.fileSource = source
        entry.fileInode = openedInode
        source.resume()
    }

    private func scheduleEvaluationOnQueue(for entry: WatchedEntry, delay: TimeInterval) {
        entry.debounceWorkItem?.cancel()
        let watchedPath = entry.path
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let current = self.entries[watchedPath] else { return }
            self.evaluateDiskStateOnQueue(for: current)
        }
        entry.debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func evaluateDiskStateOnQueue(for entry: WatchedEntry) {
        guard isWatching(path: entry.path) else { return }
        rearmFileSourceIfNeededOnQueue(for: entry)

        let resolvedPath = Self.resolvedTargetPath(for: entry.path)
        guard let diskData = Self.readBoundedFileData(
            atPath: resolvedPath,
            maxBytes: EditorFileWatcher.maximumWatchedFileBytes
        ) else {
            // If an atomic write unlinked the target microseconds ago and hasn't finished rename(),
            // retry once shortly after.
            if entry.transientMissingRetries < 2 {
                entry.transientMissingRetries += 1
                scheduleEvaluationOnQueue(for: entry, delay: 0.06)
            }
            return
        }
        entry.transientMissingRetries = 0

        let diskDigest = EditorFileWatcher.sha256(diskData)
        if diskDigest == entry.expectedDigest || entry.allowedSelfSaveDigests.contains(diskDigest) {
            entry.expectedDigest = diskDigest
            entry.lastDeliveredDigest = nil
            return
        }
        if diskDigest == entry.lastDeliveredDigest {
            return
        }

        entry.lastDeliveredDigest = diskDigest
        let change = EditorExternalFileChange.fromDiskData(diskData, path: entry.path)
        onCandidateChange?(change)
    }

    private func teardownEntryOnQueue(_ entry: WatchedEntry) {
        entry.debounceWorkItem?.cancel()
        entry.debounceWorkItem = nil
        if let fileSource = entry.fileSource {
            entry.fileSource = nil
            entry.fileInode = nil
            fileSource.cancel()
        }
        if let parentSource = entry.parentSource {
            entry.parentSource = nil
            parentSource.cancel()
        }
    }

    private static func resolvedTargetPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath().path
    }

    private static func statInode(atPath path: String) -> FileInode? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileInode(device: info.st_dev, inode: info.st_ino)
    }

    private static func fstatInode(fd: Int32) -> FileInode? {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileInode(device: info.st_dev, inode: info.st_ino)
    }

    private static func readBoundedFileData(atPath path: String, maxBytes: Int) -> Data? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maxBytes) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1),
              data.count <= maxBytes else {
            return nil
        }
        return data
    }
}
