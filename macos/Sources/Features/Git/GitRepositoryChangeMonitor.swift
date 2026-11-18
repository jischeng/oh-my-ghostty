import CoreServices
import Foundation

/// Recursive filesystem events gate local Git polling. A periodic full read
/// remains necessary for missed events and changes on unusual filesystems.
@MainActor
final class GitRepositoryChangeMonitor {
    private final class CallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private let ignoredPaths: [String]
        private weak var owner: GitRepositoryChangeMonitor?
        private var suppressing = false
        private var generation: UInt64 = 0

        init(ignoredPaths: [String]) {
            self.ignoredPaths = ignoredPaths
        }

        func bind(owner: GitRepositoryChangeMonitor) {
            lock.lock()
            self.owner = owner
            lock.unlock()
        }

        func beginAcknowledge() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            suppressing = true
            generation &+= 1
            return generation
        }

        func endAcknowledge() {
            lock.lock()
            suppressing = false
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            owner = nil
            suppressing = true
            generation &+= 1
            lock.unlock()
        }

        func handleEvents(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
            let capturedGeneration: UInt64? = {
                lock.lock()
                defer { lock.unlock() }
                guard !suppressing, owner != nil else { return nil }
                return generation
            }()
            guard let capturedGeneration else { return }

            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let mustRescan = (0..<count).contains {
                flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            }
            let hasRelevantChange = mustRescan || names.contains { path in
                !ignoredPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            guard hasRelevantChange else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let targetOwner: GitRepositoryChangeMonitor? = {
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    guard !self.suppressing, self.generation == capturedGeneration else { return nil }
                    return self.owner
                }()
                targetOwner?.markDirty()
            }
        }
    }

    private let streamQueue = DispatchQueue(label: "com.jischeng.omg.git-change-monitor", qos: .utility)
    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?
    private var dirty = true
    private var lastRefresh = Date.distantPast
    private let onChange: () -> Void
    private var notificationTask: Task<Void, Never>?

    init?(paths: [String], gitDirectories: [String] = [], onChange: @escaping () -> Void = {}) {
        self.onChange = onChange
        let ignoredPaths = gitDirectories.flatMap { directory in
            ["fsmonitor--daemon", "fsmonitor--daemon.ipc", "fsmonitor--daemon.ipc.lock"].map {
                URL(fileURLWithPath: directory).appendingPathComponent($0).resolvingSymlinksInPath().path
            }
        }
        let box = CallbackBox(ignoredPaths: ignoredPaths)
        self.callbackBox = box
        box.bind(owner: self)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(pointer).retain()
                return UnsafeRawPointer(pointer)
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<CallbackBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                box.handleEvents(count: count, paths: paths, flags: flags)
            }, &context, Array(Set(paths)) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            box.invalidate()
            return nil
        }
        // Schedule FSEvents on a dedicated background serial queue rather than DispatchQueue.main:
        // calling FSEventStreamFlushSync from @MainActor deadlocks when the stream itself delivers on .main.
        FSEventStreamSetDispatchQueue(stream, streamQueue)
        guard FSEventStreamStart(stream) else {
            box.invalidate()
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
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

    func acknowledgeRefresh(now: Date = Date()) {
        _ = callbackBox.beginAcknowledge()
        if let stream {
            FSEventStreamFlushSync(stream)
        }
        callbackBox.endAcknowledge()
        notificationTask?.cancel()
        notificationTask = nil
        dirty = false
        lastRefresh = now
    }

    func needsRefresh(now: Date = Date()) -> Bool {
        guard dirty || now.timeIntervalSince(lastRefresh) >= 30 else { return false }
        dirty = false
        lastRefresh = now
        return true
    }

    deinit {
        callbackBox.invalidate()
        notificationTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
