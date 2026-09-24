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
        #expect(content.contains("──────  Session ended · "))
        #expect(content.contains("  ──────\u{001B}[0m"))
        #expect(!content.contains("---"))
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

    @Test func sshReplayKeepsLocalAndRemoteMetadataAndConsumesSnapshotBeforeTransport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let now = Date()
        let commands: [InspectorHistoryItem] = [
            .init(kind: .command, text: "remote ll", timestamp: now,
                  location: .unavailable(.expired), sourceLabel: "SSH · cloud"),
            .init(kind: .command, text: "local pwd", timestamp: now.addingTimeInterval(-60),
                  location: .unavailable(.expired), sourceLabel: "Local"),
        ]
        #expect(ShellScrollbackRestoreStore.save(surfaceID: id, baseURL: root, commands: commands,
                                                 allowsAnchorReconciliation: false) { file in
            (try? Data("old pane output\r\n".utf8).write(to: file)) != nil &&
            (try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: file.path)) != nil
        })
        let snapshot = try #require(ShellScrollbackRestoreStore.replayFile(
            for: id, baseURL: root, restoreEnabled: true
        ))
        let script = ShellScrollbackRestoreStore.sshReplayCommand("printf 'remote ready\\n'", snapshot: snapshot)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = try #require(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        #expect(process.terminationStatus == 0)
        let old = try #require(text.range(of: "old pane output"))
        let marker = try #require(text.range(of: "──────  Session restored · "))
        let ready = try #require(text.range(of: "remote ready"))
        #expect(old.lowerBound < marker.lowerBound)
        #expect(marker.lowerBound < ready.lowerBound)
        #expect(text.contains("  ──────\u{001B}[0m"))
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(ShellScrollbackRestoreStore.savedCommands(for: id, baseURL: root) == [
            .init(text: "remote ll", timestamp: now, sourceLabel: "SSH · cloud",
                  occurrenceID: commands[0].id),
            .init(text: "local pwd", timestamp: now.addingTimeInterval(-60), sourceLabel: "Local",
                  occurrenceID: commands[1].id),
        ])
        #expect(!ShellScrollbackRestoreStore.allowsAnchorReconciliation(for: id))
        #expect(ShellScrollbackRestoreStore.replayCommands(for: id) == [])
        #expect(ShellScrollbackRestoreStore.sshReplayCommand("printf ok", snapshot: nil) == "printf ok")
        let noSnapshot = ShellScrollbackRestoreStore.sshReplayCommand(
            "printf 'remote ready\\n'", snapshot: snapshot
        )
        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/bin/sh")
        missing.arguments = ["-c", noSnapshot]
        let missingOutput = Pipe()
        missing.standardOutput = missingOutput
        missing.standardError = FileHandle.nullDevice
        try missing.run()
        missing.waitUntilExit()
        let onlyRemote = try #require(String(data: missingOutput.fileHandleForReading.readDataToEndOfFile(),
                                             encoding: .utf8))
        #expect(onlyRemote == "remote ready\n")
    }

    @Test func v3SSHSidecarKeepsDistinctReplayIdentitiesForRepeatedCommands() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-v3-restore-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let epoch = UUID()
        let date = Date()
        let live = (0..<2).map { index in
            InspectorHistoryItem(id: "occurrence-\(index)", kind: .command, text: "ll",
                timestamp: date.addingTimeInterval(Double(index)),
                location: .command(surfaceID: id, executionID: UInt64(index + 1), epoch: epoch),
                sourceLabel: "SSH · cloud")
        }
        let oldLocal = InspectorHistoryItem(id: "old-local", kind: .command, text: "ll",
            timestamp: date.addingTimeInterval(-60), location: .unavailable(.expired), sourceLabel: "Local")
        #expect(ShellScrollbackRestoreStore.save(surfaceID: id, baseURL: root,
            commands: [live[1], live[0], oldLocal], allowsAnchorReconciliation: false) { file in
            (try? Data("snapshot\r\n".utf8).write(to: file)) != nil &&
            (try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: file.path)) != nil
        })
        let snapshot = try #require(ShellScrollbackRestoreStore.replayFile(
            for: id, baseURL: root, restoreEnabled: true
        ))
        try FileManager.default.removeItem(at: snapshot)
        let saved = try #require(ShellScrollbackRestoreStore.savedCommands(for: id, baseURL: root))
        let replay = try #require(ShellScrollbackRestoreStore.replayCommands(for: id))
        #expect(saved.map(\.occurrenceID) == ["occurrence-1", "occurrence-0", "old-local"])
        #expect(replay.map(\.occurrenceID) == ["occurrence-0", "occurrence-1"])
        #expect(!ShellScrollbackRestoreStore.allowsAnchorReconciliation(for: id))
    }

    @Test func v2SSHSnapshotRemainsReadOnlyWithoutOccurrenceMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-v2-restore-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = ShellScrollbackRestoreStore.directory(baseURL: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let snapshot = folder.appendingPathComponent("\(id.uuidString).vt")
        try Data("old output\r\n".utf8).write(to: snapshot)
        let sidecar = folder.appendingPathComponent("\(id.uuidString).json")
        let archive: [String: Any] = [
            "version": 2, "surfaceID": id.uuidString, "allowsAnchorReconciliation": false,
            "commands": [["text": "ll", "sourceLabel": "SSH · cloud"]],
        ]
        try JSONSerialization.data(withJSONObject: archive).write(to: sidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
        #expect(ShellScrollbackRestoreStore.replayFile(for: id, baseURL: root,
                                                       restoreEnabled: true) == snapshot)
        try FileManager.default.removeItem(at: snapshot)
        #expect(ShellScrollbackRestoreStore.savedCommands(for: id, baseURL: root)?.first?.text == "ll")
        #expect(ShellScrollbackRestoreStore.replayCommands(for: id) == nil)
        #expect(!ShellScrollbackRestoreStore.allowsAnchorReconciliation(for: id))
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
        #expect(text.contains("──────  Session restored · "))
        #expect(text.contains("  ──────\u{001B}[0m"))
        #expect(!text.contains("---"))
        #expect(text.contains("new shell ready"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
