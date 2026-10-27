import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalWorkspaceIntegrationTests {
    @Test func switchingRetainsSurfacesAndNativeTabMembership() async throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        let personal = try #require(store.create(name: "Test Personal", symbol: "house", color: "sage"))
        let work = try #require(store.create(name: "Work", symbol: "briefcase", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(appDelegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let second = TerminalController(appDelegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let target = TerminalController(appDelegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        first.workspaceID = personal
        second.workspaceID = personal
        target.workspaceID = work
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        let targetWindow = try #require(target.window)
        defer {
            for controller in [first, second, target] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(firstWindow.addTabbedWindowSafely(secondWindow, ordered: .above))
        first.refreshWorkspaceTabs()
        firstWindow.makeKeyAndOrderFront(nil)
        targetWindow.orderOut(nil)
        let firstSurface = try #require(first.surfaceTree.first)
        let secondSurface = try #require(second.surfaceTree.first)
        let targetSurface = try #require(target.surfaceTree.first)
        #expect(firstWindow.tabGroup?.windows.count == 2)
        try await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.switchWorkspace(to: work, from: first) === target)
        #expect(coordinator.parked[first.tabSessionID] === first)
        #expect(coordinator.parked[second.tabSessionID] === second)
        #expect(first.surfaceTree.first === firstSurface)
        #expect(second.surfaceTree.first === secondSurface)
        #expect(target.surfaceTree.first === targetSurface)
        #expect(firstSurface.surface != nil)
        #expect(secondSurface.surface != nil)

        #expect(coordinator.switchWorkspace(to: personal, from: target) === first)
        #expect(firstWindow.tabGroup?.selectedWindow === firstWindow)
        #expect(firstWindow.tabGroup?.windows == [firstWindow, secondWindow])
        #expect(coordinator.parked[target.tabSessionID] === target)
        #expect(coordinator.parked[first.tabSessionID] == nil)
        #expect(first.surfaceTree.first === firstSurface)
        #expect(target.surfaceTree.first === targetSurface)

        // Moving a live tab into the parked target must keep both sessions,
        // leave the source's remaining tab selected, and restore target order.
        #expect(coordinator.move(second, to: work))
        #expect(second.workspaceID == work)
        #expect(second.surfaceTree.first === secondSurface)
        #expect(coordinator.switchWorkspace(to: work, from: first) === target)
        #expect(targetWindow.tabGroup?.windows == [targetWindow, secondWindow])
        #expect(first.surfaceTree.first === firstSurface)
        #expect(second.surfaceTree.first === secondSurface)
    }
}
