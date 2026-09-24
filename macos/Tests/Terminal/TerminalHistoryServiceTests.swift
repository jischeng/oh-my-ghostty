import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalHistoryServiceTests {
    @Test func connectionEpochsRejectOldAndForeignAnchors() {
        let service = TerminalHistoryService()
        let pane = UUID()
        var cleared = 0
        let local = service.synchronizeSession(surfaceID: pane, connectionID: nil) { cleared += 1 }
        #expect(cleared == 0)
        let anchor = HistoryLocation.command(surfaceID: pane, executionID: 1, epoch: local)
        #expect(service.validate(anchor, surfaceID: pane) == nil)
        #expect(service.validate(anchor, surfaceID: UUID()) == .wrongSession)
        let remote = service.synchronizeSession(surfaceID: pane, connectionID: "ssh-A") { cleared += 1 }
        #expect(cleared == 1)
        #expect(remote != local)
        #expect(service.validate(anchor, surfaceID: pane) == .wrongSession)
        #expect(service.synchronizeSession(surfaceID: pane, connectionID: "ssh-A") { cleared += 1 } == remote)
        #expect(cleared == 1) // CWD and connecting -> ready do not change the connection ID.
        service.synchronizeSession(surfaceID: pane, connectionID: "ssh-B") { cleared += 1 }
        service.synchronizeSession(surfaceID: pane, connectionID: nil) { cleared += 1 }
        #expect(cleared == 3)
        #expect(service.validate(anchor, surfaceID: pane) == .wrongSession)
        #expect(service.validate(.unavailable(.transcriptOnly), surfaceID: pane) == .unavailable)
        service.removeSurface(pane)
        #expect(service.validate(anchor, surfaceID: pane) == .wrongSession)
    }

    @Test func transitionsArchivePreviousLocalAndSSHExecutionsWithoutSharingAnchors() {
        let service = TerminalHistoryService()
        let id = UUID()
        let date = Date()
        let localEpoch = service.synchronizeSession(surfaceID: id, connectionID: nil) {}
        let local = InspectorHistoryItem(id: "local-ll", kind: .command, text: "ll", timestamp: date,
            location: .command(surfaceID: id, executionID: 1, epoch: localEpoch), sourceLabel: "Local")
        var clearCount = 0
        let remoteEpoch = service.synchronizeSession(surfaceID: id, connectionID: "ssh-A",
            sourceLabel: "SSH · cloud", captured: { [local] }, clear: { clearCount += 1 })
        #expect(clearCount == 1)
        #expect(service.archivedCommands(for: id).map(\.text) == ["ll"])
        #expect(service.archivedCommands(for: id)[0].location == .unavailable(.expired))
        #expect(service.archivedCommands(for: id)[0].sourceLabel == "Local")
        let remote = InspectorHistoryItem(id: "remote-ll", kind: .command, text: "ll", timestamp: date,
            location: .command(surfaceID: id, executionID: 2, epoch: remoteEpoch),
            sourceLabel: "SSH · cloud")
        service.synchronizeSession(surfaceID: id, connectionID: "ssh-B",
            sourceLabel: "SSH · other", captured: { [remote] }, clear: { clearCount += 1 })
        #expect(clearCount == 2)
        #expect(service.archivedCommands(for: id).map(\.sourceLabel) == ["Local", "SSH · cloud"])
        #expect(service.archivedCommands(for: id).count == 2) // repeated ll survives
        #expect(service.validate(remote.location, surfaceID: id) == .wrongSession)
    }

    @Test func readySSHHostIdentityUpdatesLabelWithoutStartingAnotherEpoch() {
        let service = TerminalHistoryService()
        let id = UUID()
        let first = service.synchronizeSession(surfaceID: id, connectionID: "ssh-A",
                                               sourceLabel: "SSH · cloud") {}
        let next = service.synchronizeSession(surfaceID: id, connectionID: "ssh-A",
                                              sourceLabel: "SSH · cloud · A1B2C3D4") {}
        #expect(first == next)
        #expect(service.archivedCommands(for: id).isEmpty)
    }

    @Test func firstRemoteObservationDoesNotInheritUnknownHistory() {
        let service = TerminalHistoryService()
        var cleared = false
        service.synchronizeSession(surfaceID: UUID(), connectionID: "ssh-A") { cleared = true }
        #expect(cleared)
    }

    @Test func usesOneInjectedSnapshotSourceWithoutDeduplicating() {
        let pane = UUID()
        let items = (0..<2).map { InspectorHistoryItem(id: "execution-\($0)", kind: .command, text: "ll") }
        let service = TerminalHistoryService { $0 == pane ? items : [] }
        #expect(service.commands(for: pane) == items)
        #expect(service.commands(for: UUID()).isEmpty)
    }

    @Test func restoresRepeatedCommandsByOccurrenceOnlyWhenEntireReplayMatches() {
        let pane = UUID()
        let epoch = UUID()
        let now = Date()
        let original = [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 2_000)]
        let replayed = (1...3).map { index in
            InspectorHistoryItem(
                id: "replayed-\(index)", kind: .command,
                text: index == 1 ? "new" : "ll", timestamp: now,
                location: .command(surfaceID: pane, executionID: UInt64(index), epoch: epoch)
            )
        }
        let saved = original.map { ShellScrollbackRestoreStore.SavedCommand(text: "ll", timestamp: $0) }
        let restored = TerminalHistoryService.restoringTimestamps(in: replayed, from: saved)
        #expect(restored.map(\.text) == ["new", "ll", "ll"])
        #expect(restored[0].timestamp == now)
        #expect(restored[1].timestamp == original[0])
        #expect(restored[2].timestamp == original[1])
        #expect(restored.map(\.location) == replayed.map(\.location))
        #expect(TerminalHistoryService.restoringTimestamps(in: replayed, from: [
            .init(text: "different", timestamp: original[0]), saved[1],
        ]) == replayed)
        #expect(TerminalHistoryService.restoringTimestamps(in: replayed, from: nil) == replayed)
    }

    @Test func displaysSavedCommandsWithoutInventingExpiredAnchors() {
        let pane = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let saved = [ShellScrollbackRestoreStore.SavedCommand(text: "ll", timestamp: oldDate)]
        let archived = TerminalHistoryService.presentingHistory(in: [], from: saved, surfaceID: pane)
        #expect(archived.count == 1)
        #expect(archived[0].text == "ll")
        #expect(archived[0].timestamp == oldDate)
        #expect(archived[0].location == .unavailable(.expired))
        let newItem = InspectorHistoryItem(id: "live", kind: .command, text: "pwd")
        #expect(TerminalHistoryService.presentingHistory(in: [newItem], from: saved, surfaceID: pane)
            == [newItem, archived[0]])
        let matched = InspectorHistoryItem(id: "anchor", kind: .command, text: "ll",
            location: .command(surfaceID: pane, executionID: 1, epoch: UUID()))
        let verified = TerminalHistoryService.presentingHistory(in: [matched], from: saved, surfaceID: pane)
        #expect(verified.count == 1)
        #expect(verified[0].location == matched.location)
        #expect(verified[0].timestamp == oldDate)
    }

    @Test func sshSnapshotNeverMatchesAnIdenticalLocalCommandAsTheOldRemoteExecution() {
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1_000)
        let remote = ShellScrollbackRestoreStore.SavedCommand(text: "ll", timestamp: old,
                                                                sourceLabel: "SSH · cloud")
        let local = ShellScrollbackRestoreStore.SavedCommand(text: "pwd", timestamp: old,
                                                               sourceLabel: "Local")
        let live = InspectorHistoryItem(id: "current", kind: .command, text: "ll", timestamp: Date(),
            location: .command(surfaceID: id, executionID: 1, epoch: UUID()),
            sourceLabel: "SSH · cloud")
        let items = TerminalHistoryService.presentingHistory(
            in: [live], from: [remote, local], surfaceID: id, allowReconciliation: false
        )
        #expect(items.count == 3)
        #expect(items[0].location == live.location)
        #expect(items[1].sourceLabel == "SSH · cloud")
        #expect(items[1].location == .unavailable(.expired))
        #expect(items[2].sourceLabel == "Local")
        #expect(items[2].location == .unavailable(.expired))
        let wrongHost = TerminalHistoryService.presentingHistory(
            in: [live], from: [
                .init(text: "ll", timestamp: old, sourceLabel: "SSH · other")
            ], surfaceID: id
        )
        #expect(wrongHost.count == 2)
        #expect(wrongHost[1].location == .unavailable(.expired))
    }

    @Test func localToSSHArchivesOnlyNewCommandsAfterAnExactReplaySuffix() {
        let id = UUID()
        let epoch = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        let saved: [ShellScrollbackRestoreStore.SavedCommand] = [
            .init(text: "ll", timestamp: date, sourceLabel: "Local"),
            .init(text: "ll", timestamp: date, sourceLabel: "Local"),
        ]
        let commands = ["pwd", "ll", "ll"].enumerated().map { index, text in
            InspectorHistoryItem(id: "item-\(index)", kind: .command, text: text,
                timestamp: date, location: .command(surfaceID: id, executionID: UInt64(index), epoch: epoch),
                sourceLabel: "Local")
        }
        #expect(TerminalHistoryService.excludingRestoredSuffix(commands, saved: saved,
                                                                  canReconcile: true).map(\.text) == ["pwd"])
        #expect(TerminalHistoryService.excludingRestoredSuffix(commands, saved: saved,
                                                                  canReconcile: false) == commands)
        #expect(TerminalHistoryService.excludingRestoredSuffix(commands, saved: [
            .init(text: "ll", timestamp: date, sourceLabel: "SSH · other"), saved[1]
        ], canReconcile: true) == commands)
        let archived = commands.map { InspectorHistoryItem(id: $0.id, kind: .command,
            text: $0.text, timestamp: $0.timestamp, location: .unavailable(.expired),
            sourceLabel: $0.sourceLabel) }
        let mixed = TerminalHistoryService.presentingHistory(in: archived, from: saved,
            surfaceID: id, allowReconciliation: false)
        #expect(mixed.count == 5) // Identical text/time is not proof of the same occurrence.
    }

    @Test func v3SSHReplayBindsRepeatedCommandsOnlyWhenEveryOccurrenceMatches() throws {
        let surfaceID = UUID()
        let epoch = UUID()
        let originalEpoch = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        let saved: [ShellScrollbackRestoreStore.SavedCommand] = [
            .init(text: "ll", timestamp: date.addingTimeInterval(1), sourceLabel: "SSH · cloud",
                  occurrenceID: "command:\(surfaceID):\(originalEpoch):2"),
            .init(text: "ll", timestamp: date, sourceLabel: "SSH · cloud",
                  occurrenceID: "command:\(surfaceID):\(originalEpoch):1"),
            .init(text: "pwd", timestamp: date.addingTimeInterval(-60), sourceLabel: "Local",
                  occurrenceID: "old-local"),
        ]
        let segment = [saved[1], saved[0]] // encoded oldest to newest
        let replayed = (0..<2).reversed().map { index in
            InspectorHistoryItem(id: "replayed-\(index)", kind: .command, text: "ll",
                location: .command(surfaceID: surfaceID, executionID: UInt64(index + 20), epoch: epoch),
                sourceLabel: "Local", replayKey: segment[index].occurrenceID)
        }
        let verified = try #require(TerminalHistoryService.verifiedReplay(
            replayed, segment: segment, saved: saved, surfaceID: surfaceID
        ))
        #expect(verified.map(\.id) == segment.compactMap(\.occurrenceID))
        #expect(verified.map(\.sourceLabel) == ["SSH · cloud", "SSH · cloud"])
        #expect(verified[0].location != verified[1].location)
        let merged = TerminalHistoryService.presentingHistory(in: verified, from: saved,
            surfaceID: surfaceID, allowReconciliation: false)
        #expect(merged.count == 3)
        #expect(merged.last?.text == "pwd")
        #expect(merged.last?.location == .unavailable(.expired))
        let pruned = verified.map { item in
            InspectorHistoryItem(id: item.id, kind: .command, text: item.text,
                timestamp: item.timestamp, location: .unavailable(.expired),
                sourceLabel: item.sourceLabel)
        }
        #expect(TerminalHistoryService.presentingHistory(in: pruned, from: saved,
            surfaceID: surfaceID, allowReconciliation: false).count == 3)
        let service = TerminalHistoryService()
        _ = service.synchronizeSession(surfaceID: surfaceID, connectionID: "new-ssh") {}
        service.installVerifiedReplay(verified, for: surfaceID)
        #expect(service.validate(verified[0].location, surfaceID: surfaceID) == nil)
        #expect(service.validate(verified[0].location, surfaceID: UUID()) == .wrongSession)
        #expect(TerminalHistoryService.verifiedReplay(Array(replayed.dropLast()),
            segment: segment, saved: saved, surfaceID: surfaceID) == nil)
        let bad = [segment[1], segment[0]]
        #expect(TerminalHistoryService.verifiedReplay(replayed,
            segment: bad, saved: saved, surfaceID: surfaceID) == nil)
        let unmarked = replayed.map { item in
            InspectorHistoryItem(id: item.id, kind: .command, text: item.text,
                location: item.location, sourceLabel: item.sourceLabel)
        }
        #expect(TerminalHistoryService.verifiedReplay(unmarked,
            segment: segment, saved: saved, surfaceID: surfaceID) == nil)
        #expect(TerminalHistoryService.verifiedReplay(replayed,
            segment: [segment[0], segment[0]], saved: saved, surfaceID: surfaceID) == nil)
        #expect(TerminalHistoryService.verifiedReplay(replayed,
            segment: [segment[0], .init(text: "wrong", timestamp: date,
                sourceLabel: "SSH · cloud", occurrenceID: segment[1].occurrenceID)],
            saved: saved, surfaceID: surfaceID) == nil)
        #expect(TerminalHistoryService.verifiedReplay(replayed,
            segment: segment, saved: saved, surfaceID: UUID()) == nil)
    }

    @Test func previewNeverChangesCopyText() {
        let text = "  " + String(repeating: "完整 Prompt\n", count: 3_000) + "  "
        let item = InspectorHistoryItem(kind: .agentPrompt, text: text)
        #expect(item.preview.count <= 2_001)
        #expect(item.text == text)
        #expect(!item.location.isAvailable)
    }
}
