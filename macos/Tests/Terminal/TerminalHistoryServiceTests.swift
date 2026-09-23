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

    @Test func previewNeverChangesCopyText() {
        let text = "  " + String(repeating: "完整 Prompt\n", count: 3_000) + "  "
        let item = InspectorHistoryItem(kind: .agentPrompt, text: text)
        #expect(item.preview.count <= 2_001)
        #expect(item.text == text)
        #expect(!item.location.isAvailable)
    }
}
