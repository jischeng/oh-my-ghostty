import Foundation

/// One per terminal surface: at most one active filesystem batch, deduplicated
/// paths, a short positive/negative cache, and one core refresh per completion.
@MainActor
final class TerminalLinkCheckBatcher {
    struct Scope: Hashable {
        let revision: UInt64
        let filesystemID: String
        let directory: String
    }
    private struct Key: Hashable {
        let scope: Scope
        let path: String
    }
    private struct Entry {
        let exists: Bool
        let expires: TimeInterval
    }
    private struct Request {
        let key: Key
        let filesystem: any WorkspaceFilesystem
        let reply: (Bool) -> Void
        let refresh: () -> Void
    }
    private var pending: [Request] = []
    private var cache: [Key: Entry] = [:]
    private var scheduled = false
    private var draining = false
    private let now: () -> TimeInterval
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 3, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ttl = ttl
        self.now = now
    }

    func enqueue(path: String, scope: Scope, filesystem: any WorkspaceFilesystem,
                 reply: @escaping (Bool) -> Void, refresh: @escaping () -> Void) {
        // The core bounds candidates to 256 per press. Coalesce callbacks
        // dispatched in the same run-loop turn rather than launching per path.
        guard pending.count < 512 else { reply(false); return }
        pending.append(.init(key: .init(scope: scope, path: path), filesystem: filesystem,
                             reply: reply, refresh: refresh))
        guard !scheduled, !draining else { return }
        scheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(12))
            await self?.flush()
        }
    }

    /// Exposed internally for deterministic batching tests; the normal entry
    /// point is enqueue. Never run overlapping remote batches for this surface.
    func flush() async {
        scheduled = false
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pending.isEmpty {
            let requests = pending
            pending.removeAll(keepingCapacity: true)
            cache = cache.filter { $0.value.expires > now() }
            if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
            for group in Dictionary(grouping: requests, by: { $0.key.scope }).values {
                guard let first = group.first else { continue }
                let missing = Set(group.filter { cache[$0.key] == nil }.map { $0.key.path }).sorted()
                if !missing.isEmpty {
                    do {
                        let types = try await first.filesystem.itemTypes(at: missing)
                        let expiry = now() + ttl
                        for path in missing {
                            cache[.init(scope: first.key.scope, path: path)] = .init(
                                exists: types[path] != nil, expires: expiry
                            )
                        }
                    } catch {
                        // Transport failure isn't evidence of absence. Don't
                        // negative-cache it; a later Cmd press may retry.
                    }
                }
                for request in group {
                    request.reply(cache[request.key]?.exists ?? false)
                }
            }
            // Every request belongs to the same surface. All cache entries are
            // applied before this single refresh, even when some were misses.
            requests.first?.refresh()
        }
    }
}
