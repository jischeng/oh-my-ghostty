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

    @Test func previewNeverChangesCopyText() {
        let text = "  " + String(repeating: "完整 Prompt\n", count: 3_000) + "  "
        let item = InspectorHistoryItem(kind: .agentPrompt, text: text)
        #expect(item.preview.count <= 2_001)
        #expect(item.text == text)
        #expect(!item.location.isAvailable)
    }
}
