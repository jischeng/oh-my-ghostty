import AppKit

/// Opt-in, metadata-only diagnostics for the Debug (OMG Dev) app. No terminal
/// contents, titles, paths, commands, process IDs or allocation stacks are read.
@MainActor
enum DevMemoryDiagnostics {
#if DEBUG
    private static let enabled = Bundle.main.bundleIdentifier == "com.jischeng.omg.debug" &&
        ProcessInfo.processInfo.environment["OMG_DEV_MEMORY_DIAGNOSTICS"] == "1"
    private static var writer: DevMemoryLog?
    private static var timer: Timer?
    private static var liveSurfaces = 0

    static func start() {
        guard enabled, timer == nil else { return }
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OMG/MemoryDiagnostics", isDirectory: true)
        writer = DevMemoryLog(directory: directory)
        record("start")
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { record("sample") }
        }
    }

    static func surfaceCreated() {
        guard enabled else { return }
        liveSurfaces += 1
        record("surface_created")
    }

    static func surfaceDestroyed() {
        guard enabled else { return }
        liveSurfaces = max(0, liveSurfaces - 1)
        record("surface_destroyed")
    }

    static func tabCreated() { record("tab_created") }
    static func tabClosed() { record("tab_closed") }
    static func splitTreeChanged(from oldTree: SplitTree<Ghostty.SurfaceView>,
                                 to newTree: SplitTree<Ghostty.SurfaceView>) {
        guard enabled, writer != nil else { return }
        let previous = oldTree.reduce(0) { count, _ in count + 1 }
        let current = newTree.reduce(0) { count, _ in count + 1 }
        if previous > 0 && current > previous { record("split_added") }
        if current > 0 && current < previous { record("split_removed") }
    }
    static func windowOpened() { record("window_opened") }
    static func windowFocused() { record("window_focused") }
    static func windowClosing() { record("window_closing") }

    private static func record(_ event: String) {
        guard enabled, let writer else { return }
        let controllers = NSApp.windows.compactMap { $0.windowController as? TerminalController }
        let windows = Set(controllers.compactMap { $0.window?.tabGroup?.windows.first ?? $0.window })
        writer.append(event: event, surfaces: liveSurfaces,
                      tabs: controllers.count, windows: windows.count)
    }
#else
    static func start() {}
    static func surfaceCreated() {}
    static func surfaceDestroyed() {}
    static func tabCreated() {}
    static func tabClosed() {}
    static func splitTreeChanged(from: SplitTree<Ghostty.SurfaceView>,
                                 to: SplitTree<Ghostty.SurfaceView>) {}
    static func windowOpened() {}
    static func windowFocused() {}
    static func windowClosing() {}
#endif
}

/// Two 1 MiB files at most. Deliberately uses a fixed schema, not arbitrary
/// messages, so callers cannot accidentally log sensitive terminal data.
@MainActor
final class DevMemoryLog {
    static let maxBytes = 1_048_576
    private let current: URL
    private let previous: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        current = directory.appendingPathComponent("events.jsonl")
        previous = directory.appendingPathComponent("events.previous.jsonl")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func append(event: String, surfaces: Int, tabs: Int, windows: Int) {
        // Only known event names are accepted, even if a future call site passes
        // a title or other dynamic string by mistake.
        guard Self.events.contains(event) else { return }
        let fields: [String: Any] = [
            "time": Self.timestamp.string(from: Date()),
            "event": event,
            "surfaces": surfaces,
            "tabs": tabs,
            "windows": windows
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              data.count + 1 <= Self.maxBytes else { return }
        var line = data
        line.append(0x0A)
        let size = (try? fileManager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + line.count > Self.maxBytes {
            try? fileManager.removeItem(at: previous)
            if fileManager.fileExists(atPath: current.path) {
                do {
                    try fileManager.moveItem(at: current, to: previous)
                } catch {
                    return // Never exceed the cap if rotation fails.
                }
            }
        }
        if !fileManager.fileExists(atPath: current.path) {
            _ = fileManager.createFile(atPath: current.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: current) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostic failures must never affect the terminal.
        }
    }

    private static let events: Set<String> = [
        "start", "sample", "surface_created", "surface_destroyed", "tab_created",
        "tab_closed", "split_added", "split_removed", "window_opened",
        "window_focused", "window_closing"
    ]
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
