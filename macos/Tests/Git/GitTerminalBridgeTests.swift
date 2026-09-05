import Foundation
import Testing
@testable import Ghostty

@MainActor
private final class GitTerminalSurfaceTargetStub: GitTerminalSurfaceTarget {
    let id: UUID
    private(set) var sentText: [String] = []
    let acceptsText: Bool

    init(id: UUID, acceptsText: Bool = true) {
        self.id = id
        self.acceptsText = acceptsText
    }

    func sendText(_ text: String) -> Bool {
        guard acceptsText else { return false }
        sentText.append(text)
        return true
    }
}

@MainActor
struct GitTerminalBridgeTests {
    @Test func dispatchesExactlyOnceToTheContextSurfaceAndFocusesIt() {
        let tabID = UUID()
        let surfaceID = UUID()
        let target = GitTerminalSurfaceTargetStub(id: surfaceID)
        var lookupArguments: [(UUID, UUID)] = []
        var focusedIDs: [UUID] = []
        let bridge = GitTerminalBridge(
            surfaceLookup: { requestedTabID, requestedSurfaceID in
                lookupArguments.append((requestedTabID, requestedSurfaceID))
                return requestedTabID == tabID && requestedSurfaceID == surfaceID ? target : nil
            },
            focusSurface: { focusedIDs.append($0.id) }
        )
        let context = InspectorPaneContext(
            tabID: tabID,
            surfaceID: surfaceID,
            title: "Terminal",
            workingDirectory: "/tmp/project"
        )
        let result = bridge.dispatch(
            .status(repository: GitRepositoryIdentity(
                worktreePath: "/tmp/project",
                gitDirPath: "/tmp/project/.git",
                commonGitDirPath: "/tmp/project/.git"
            )),
            in: context
        )

        #expect(lookupArguments.count == 1)
        #expect(lookupArguments.first?.0 == tabID)
        #expect(lookupArguments.first?.1 == surfaceID)
        #expect(focusedIDs == [surfaceID])
        #expect(target.sentText.count == 1)
        #expect(target.sentText.first?.hasSuffix("--branch") == true)
        #expect(target.sentText.first?.hasSuffix("\n") == false)
        #expect(result.displayMessage == nil)
    }

    @Test func rejectsMissingOrMismatchedTargetsWithoutWriting() {
        let tabID = UUID()
        let bridge = GitTerminalBridge(
            surfaceLookup: { _, _ in Issue.record("lookup must not run"); return nil },
            focusSurface: { _ in Issue.record("focus must not run") }
        )
        let repository = GitRepositoryIdentity(
            target: .remote(host: "prod", user: nil),
            worktreePath: "/srv/project",
            gitDirPath: "/srv/project/.git",
            commonGitDirPath: "/srv/project/.git"
        )
        let localContext = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "Terminal",
            workingDirectory: "/tmp/project"
        )

        let result = bridge.dispatch(.status(repository: repository), in: localContext)
        #expect(result == .failed(.targetContextMismatch))
    }
}
