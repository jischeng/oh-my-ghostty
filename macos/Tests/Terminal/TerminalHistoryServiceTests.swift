import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalHistoryServiceTests {
    @Test func recordsAndDeduplicatesRecentCommands() {
        let service = TerminalHistoryService()
        let surfaceID = UUID()

        service.recordCommand(text: "git status", surfaceID: surfaceID)
        service.recordCommand(text: "git status", surfaceID: surfaceID) // 紧邻重复命令应去重
        service.recordCommand(text: "cargo test", surfaceID: surfaceID)

        let history = service.loadShellHistory(surfaceID: surfaceID, limit: 10)
        #expect(history.count >= 2)
        #expect(history[0].text == "cargo test")
        #expect(history[1].text == "git status")
        #expect(history[0].kind == .command)

        service.removeSurface(surfaceID)
        let afterRemoval = service.loadShellHistory(surfaceID: surfaceID, limit: 10)
        #expect(!afterRemoval.contains(where: { $0.text == "cargo test" }))
    }

    @Test func limitsRecordedCommandsToMaximumBound() {
        let service = TerminalHistoryService()
        let surfaceID = UUID()

        for i in 0..<60 {
            service.recordCommand(text: "cmd-\(i)", surfaceID: surfaceID)
        }

        let recorded = service.recordedCommands(for: surfaceID)
        #expect(recorded.count == 50)
        #expect(recorded.first?.text == "cmd-59")
    }

    @Test func modelInitializersHoldExpectedValues() {
        let now = Date()
        let item = InspectorHistoryItem(
            id: "test-id",
            kind: .agentPrompt,
            text: "Explain this code",
            timestamp: now,
            exitCode: 0,
            duration: 1_000_000,
            promptIndex: 2
        )
        #expect(item.id == "test-id")
        #expect(item.kind == .agentPrompt)
        #expect(item.text == "Explain this code")
        #expect(item.timestamp == now)
        #expect(item.exitCode == 0)
        #expect(item.duration == 1_000_000)
        #expect(item.promptIndex == 2)
    }
}
