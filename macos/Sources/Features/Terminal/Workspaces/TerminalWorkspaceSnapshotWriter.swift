import Foundation

/// Serial, coalescing writer for a complete generation. No AppKit objects cross
/// this boundary. A previous valid generation survives a damaged latest file.
final class TerminalWorkspaceSnapshotWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jischeng.omg.workspaces.checkpoint", qos: .utility)
    private let lock = NSLock()
    private struct Request {
        var snapshot: TerminalWorkspaceSessionStore.Snapshot
        var descriptors: [UUID: TerminalWorkspaceSessionState]
    }
    private var pending: Request?
    @MainActor var onCompletion: ((String?) -> Void)?
    private var scheduled = false
    private var writes = 0
    private var error: String?
    let url: URL

    init(url: URL) { self.url = url }

    func submit(_ snapshot: TerminalWorkspaceSessionStore.Snapshot,
                descriptors: [UUID: TerminalWorkspaceSessionState]) {
        lock.lock()
        pending = Request(snapshot: snapshot, descriptors: descriptors)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { self.drain() } }
    }

    func flush() { queue.sync {} }
    var writeCount: Int { queue.sync { writes } }
    var lastError: String? { queue.sync { error } }

    private func drain() {
        while true {
            lock.lock()
            let value = pending
            pending = nil
            if value == nil { scheduled = false }
            lock.unlock()
            guard let request = value else { return }
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var snapshot = request.snapshot
                for index in snapshot.tabs.indices {
                    guard let descriptor = request.descriptors[snapshot.tabs[index].id] else { throw CocoaError(.coderInvalidValue) }
                    snapshot.tabs[index].state = try encoder.encode(descriptor)
                }
                let data = try encoder.encode(snapshot)
                guard data.count <= 32 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
                let staging = directory.appendingPathComponent(".checkpoint-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staging) }
                FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: staging)
                do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() } catch {
                    try? handle.close()
                    throw error
                }
                // Preserve only a decodable complete generation. Never replace
                // the backup with the corrupted file we just recovered from.
                if let old = try? Data(contentsOf: url),
                   let snapshot = try? JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: old),
                   snapshot.isComplete {
                    let backup = url.appendingPathExtension("previous")
                    try old.write(to: backup, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
                // POSIX rename replaces the complete file atomically, preserving
                // the staging file's private permissions from the first byte.
                guard rename(staging.path, url.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                writes += 1
                error = nil
            } catch { self.error = error.localizedDescription }
            let message = error
            DispatchQueue.main.async { [weak self] in self?.onCompletion?(message) }
        }
    }
}
