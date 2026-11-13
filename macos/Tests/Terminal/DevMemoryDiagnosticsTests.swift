import Foundation
import Testing
@testable import Ghostty

@MainActor
struct DevMemoryDiagnosticsTests {
    @Test func fixedSchemaRejectsContentAndUsesPrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-memory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DevMemoryLog(directory: root)
        log.append(event: "secret terminal command", surfaces: 1, tabs: 1, windows: 1)
        log.append(event: "sample", surfaces: 2, tabs: 1, windows: 1)
        let file = root.appendingPathComponent("events.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["time", "event", "surfaces", "tabs", "windows"])
        #expect(object["event"] as? String == "sample")
        #expect(object["surfaces"] as? Int == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func actionMarkersKeepTheSameMetadataOnlySchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-memory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DevMemoryLog(directory: root)
        let actions = ["tab_closed", "split_added", "split_removed",
                       "window_focused", "window_closing"]
        for action in actions {
            log.append(event: action, surfaces: 2, tabs: 1, windows: 1)
        }
        let file = root.appendingPathComponent("events.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == actions.count)
        for (line, action) in zip(lines, actions) {
            let fields = try #require(JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any])
            #expect(Set(fields.keys) == ["time", "event", "surfaces", "tabs", "windows"])
            #expect(fields["event"] as? String == action)
        }
    }

    @Test func rotatesWithoutExceedingTwoMegabytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-memory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DevMemoryLog(directory: root)
        for _ in 0..<25_000 {
            log.append(event: "sample", surfaces: 1, tabs: 1, windows: 1)
        }
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.fileSizeKey])
        #expect(Set(files.map(\.lastPathComponent)) == ["events.jsonl", "events.previous.jsonl"])
        for file in files {
            let size = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(size <= DevMemoryLog.maxBytes)
        }
    }

    @Test func debugBundleMatcherAcceptsAllDebugChannelsAndUsesChannelAppSupport() {
        #expect(DevMemoryDiagnostics.isSupportedDebugBundle("com.jischeng.omg.debug"))
        #expect(DevMemoryDiagnostics.isSupportedDebugBundle("com.jischeng.omg.debug.workspace"))
        #expect(DevMemoryDiagnostics.isSupportedDebugBundle("com.jischeng.omg.debug.pty"))
        #expect(!DevMemoryDiagnostics.isSupportedDebugBundle("com.jischeng.omg"))
        #expect(!DevMemoryDiagnostics.isSupportedDebugBundle(nil))

        let customSupport = URL(fileURLWithPath: "/tmp/Application Support/OMG Workspace Dev", isDirectory: true)
        let diagnosticsDir = DevMemoryDiagnostics.diagnosticsDirectory(applicationSupportURL: customSupport)
        #expect(diagnosticsDir.path == "/tmp/Application Support/OMG Workspace Dev/MemoryDiagnostics")
        #expect(!diagnosticsDir.path.contains("/Application Support/OMG/MemoryDiagnostics"))
    }

    @Test func dragDiagnosticsPruneRemovesOnlyJsonlOlderThanSevenDays() throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-drag-gc-\(UUID().uuidString)", isDirectory: true)
        let diagDir = supportDir.appendingPathComponent("DragDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: diagDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let expiredFile = diagDir.appendingPathComponent("drag-old.jsonl")
        let recentFile = diagDir.appendingPathComponent("drag-recent.jsonl")
        try Data("{\"phase\":\"down\"}\n".utf8).write(to: expiredFile)
        try Data("{\"phase\":\"up\"}\n".utf8).write(to: recentFile)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(8 * 24 * 60 * 60))],
            ofItemAtPath: expiredFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(2 * 24 * 60 * 60))],
            ofItemAtPath: recentFile.path
        )

        NativeTabDragDiagnostics.pruneExpired(applicationSupportURL: supportDir, now: now)
        #expect(!FileManager.default.fileExists(atPath: expiredFile.path))
        #expect(FileManager.default.fileExists(atPath: recentFile.path))
    }
}
