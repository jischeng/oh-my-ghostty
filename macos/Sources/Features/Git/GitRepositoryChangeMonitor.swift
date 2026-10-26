import CoreServices
import Foundation

/// Recursive filesystem events gate local Git polling. A periodic full read
/// remains necessary for missed events and changes on unusual filesystems.
@MainActor
final class GitRepositoryChangeMonitor {
    private var stream: FSEventStreamRef?
    private var dirty = true
    private var lastRefresh = Date.distantPast
    private let ignoredPaths: [String]
    private let onChange: () -> Void
    private var notificationTask: Task<Void, Never>?

    init?(paths: [String], gitDirectories: [String] = [], onChange: @escaping () -> Void = {}) {
        self.onChange = onChange
        ignoredPaths = gitDirectories.flatMap { directory in
            ["fsmonitor--daemon", "fsmonitor--daemon.ipc", "fsmonitor--daemon.ipc.lock"].map {
                URL(fileURLWithPath: directory).appendingPathComponent($0).resolvingSymlinksInPath().path
            }
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let monitor = Unmanaged<GitRepositoryChangeMonitor>.fromOpaque(info).takeUnretainedValue()
                let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let mustRescan = (0..<count).contains {
                    flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                }
                Task { @MainActor in
                    if mustRescan || names.contains(where: { path in
                        !monitor.ignoredPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
                    }) { monitor.markDirty() }
                }
            }, &context, Array(Set(paths)) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { return nil }
    }

    private func markDirty() {
        dirty = true
        // Coalesce bursts without postponing indefinitely during continuous writes.
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.notificationTask = nil
            self.onChange()
        }
    }

    func needsRefresh(now: Date = Date()) -> Bool {
        guard dirty || now.timeIntervalSince(lastRefresh) >= 30 else { return false }
        dirty = false
        lastRefresh = now
        return true
    }

    deinit {
        notificationTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
