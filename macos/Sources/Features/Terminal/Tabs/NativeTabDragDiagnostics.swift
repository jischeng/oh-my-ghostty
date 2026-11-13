import AppKit

/// Opt-in Dev evidence only. Never records key contents, tab titles or paths.
@MainActor
enum NativeTabDragDiagnostics {
    nonisolated static let maxDiagnosticAge: TimeInterval = 7 * 24 * 60 * 60
    static let enabled = OMGApplicationEnvironment.isDevelopment &&
        ProcessInfo.processInfo.environment["OMG_DEV_TAB_DRAG_DIAGNOSTICS"] == "1"
    private static var remaining = 1024
    private static var started: TimeInterval?
    private static var output: FileHandle?

    nonisolated static func pruneExpired(
        applicationSupportURL: URL? = nil,
        now: Date = Date(),
        maxScan: Int = 512
    ) {
        guard maxScan > 0 else { return }
        let support = applicationSupportURL ?? OMGApplicationEnvironment.applicationSupportURL()
        let directory = support.appendingPathComponent("DragDiagnostics", isDirectory: true)
        guard let dirAttrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
              dirAttrs[.type] as? FileAttributeType == .typeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names.prefix(maxScan) where name.hasSuffix(".jsonl") {
            let fileURL = directory.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > Self.maxDiagnosticAge else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func record(_ phase: String, outline: NativeTabOutline, event: NSEvent? = NSApp.currentEvent) {
        guard enabled, remaining > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if started == nil, event?.type == .leftMouseDown { started = now }
        guard let started, now - started < 120 else { return }
        if output == nil {
            let directory = OMGApplicationEnvironment.applicationSupportURL().appendingPathComponent("DragDiagnostics")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("drag-\(ProcessInfo.processInfo.processIdentifier)-\(UUID()).jsonl")
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { return }
            output = try? FileHandle(forWritingTo: file)
        }
        let row: [String: Any] = [
            "time": now, "phase": phase, "event": event?.type.rawValue ?? 0,
            "buttons": NSEvent.pressedMouseButtons, "dragging": outline.isDraggingTab,
            "windowMatches": event.map { $0.window === outline.window } ?? false,
            "mode": RunLoop.current.currentMode?.rawValue ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        remaining -= 1
        try? output?.write(contentsOf: data + Data([10]))
    }
}
