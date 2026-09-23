import Foundation
import Testing
@testable import Ghostty

@MainActor
struct ShellScrollbackRestoreStoreTests {
    @Test func preservesOnlyOwnerReadableSnapshotsBoundToSurfaceUUID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-restore-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let surfaceID = UUID()
        let sample = "\u{001B}[31mold colored output\u{001B}[0m\r\n"
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let command = InspectorHistoryItem(kind: .command, text: "ll", timestamp: oldDate)
        #expect(ShellScrollbackRestoreStore.save(surfaceID: surfaceID, baseURL: root,
                                                commands: [command]) { file in
            (try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)) != nil &&
            (try? Data(sample.utf8).write(to: file)) != nil &&
            (try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: file.path)) != nil
        })
        let saved = try #require(ShellScrollbackRestoreStore.replayFile(
            for: surfaceID, baseURL: root, restoreEnabled: true
        ))
        let content = try String(contentsOf: saved, encoding: .utf8)
        #expect(content.contains(sample))
        #expect(content.contains("--- Quitted at "))
        #expect(ShellScrollbackRestoreStore.replayFile(for: UUID(), baseURL: root, restoreEnabled: true) == nil)
        #expect(ShellScrollbackRestoreStore.replayFile(for: surfaceID, baseURL: root,
                                                      restoreEnabled: false) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: saved.deletingLastPathComponent().path)
        let dirMode = dirAttributes[.posixPermissions] as? NSNumber
        #expect(dirMode?.intValue == 0o700)
        #expect(ShellScrollbackRestoreStore.savedCommands(for: surfaceID, baseURL: root) == nil)
        try FileManager.default.removeItem(at: saved)
        #expect(ShellScrollbackRestoreStore.savedCommands(for: surfaceID, baseURL: root) == [
            .init(text: "ll", timestamp: oldDate),
        ])
    }

    @Test func failedCaptureInvalidatesPreviousSnapshotAndRejectsUnsafeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-restore-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let surfaceID = UUID()
        let snapshot = ShellScrollbackRestoreStore.directory(baseURL: root)
            .appendingPathComponent("\(surfaceID.uuidString).vt")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("old".utf8).write(to: snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        #expect(!ShellScrollbackRestoreStore.save(surfaceID: surfaceID, baseURL: root) { _ in false })
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        try Data("old".utf8).write(to: snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        #expect(ShellScrollbackRestoreStore.replayFile(for: surfaceID, baseURL: root,
            now: Date().addingTimeInterval(8 * 24 * 60 * 60), restoreEnabled: true) == nil)
        try FileManager.default.removeItem(at: snapshot)
        try Data(repeating: 120, count: ShellScrollbackRestoreStore.maximumBytes + 1).write(to: snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        #expect(ShellScrollbackRestoreStore.replayFile(for: surfaceID, baseURL: root,
                                                      restoreEnabled: true) == nil)
        try FileManager.default.removeItem(at: snapshot)
        try Data("readable".utf8).write(to: snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: snapshot.path)
        #expect(ShellScrollbackRestoreStore.replayFile(for: surfaceID, baseURL: root,
                                                      restoreEnabled: true) == nil)
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: root)
        #expect(ShellScrollbackRestoreStore.replayFile(for: surfaceID, baseURL: root,
                                                      restoreEnabled: true) == nil)
    }

    @Test func replayShellScriptIsOneShotAndDoesNotChangeTheRunningShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-restore-script-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("record.vt")
        try Data("old shell output\r\n".utf8).write(to: file)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("src/shell-integration/omg/restore.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ". \"$1\"; printf 'new shell ready\\n'", "omg-test", script.path]
        process.environment = [ShellScrollbackRestoreStore.environmentKey: file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = try #require(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        #expect(process.terminationStatus == 0)
        #expect(text.contains("old shell output"))
        #expect(text.contains("--- Restored at "))
        #expect(text.contains("new shell ready"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
