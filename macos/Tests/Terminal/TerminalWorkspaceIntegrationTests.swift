import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalWorkspaceIntegrationTests {
    @Test func sessionSnapshotSurvivesStoreRecreationAndExplicitTabDeletion() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.start(app)
        store.capture()
        let snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(snapshot.tabs.contains { $0.id == controller.tabSessionID })
        let recreated = TerminalWorkspaceSessionStore(url: url, testing: true)
        recreated.prepare()
        #expect(recreated.ownsRestoration)
        store.forget(controller)
        store.capture()
        let deleted = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(!deleted.tabs.contains { $0.id == controller.tabSessionID })
    }

    @Test func sessionSnapshotPreservesEveryTabAndSplitIdentity() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let nativeApp = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let views = (0..<4).map { _ in Ghostty.SurfaceView(nativeApp, baseConfig: config) }
        let split = SplitTree<Ghostty.SurfaceView>(root: .split(.init(
            direction: .horizontal, ratio: 0.4,
            left: .leaf(view: views[0]), right: .split(.init(
                direction: .vertical, ratio: 0.6,
                left: .leaf(view: views[1]), right: .leaf(view: views[2])
            ))
        )), zoomed: nil)
        let first = TerminalController(app, withSurfaceTree: split)
        let second = TerminalController(app, withSurfaceTree: .init(view: views[3]))
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        defer {
            for controller in [first, second] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(firstWindow.addTabbedWindowSafely(secondWindow, ordered: .above))
        first.focusedSurface = views[2]
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.start(app)
        store.capture()
        let snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        let expected = [first.tabSessionID, second.tabSessionID]
        let tabs = snapshot.tabs.filter { expected.contains($0.id) }
        #expect(tabs.count == 2)
        for tab in tabs {
            let restored = try JSONDecoder().decode(TerminalRestorableState.self, from: tab.state)
            let ids = restored.surfaceTree.map(\.id)
            if tab.id == first.tabSessionID {
                #expect(ids == Array(views.prefix(3)).map(\.id))
                #expect(restored.focusedSurface == views[2].id.uuidString)
                #expect(restored.surfaceTree.isSplit)
            } else {
                #expect(ids == [views[3].id])
            }
        }
    }

    @Test func startupRestoresAllTabsAndSplitsFromTheSessionCatalog() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let nativeApp = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let panes = (0..<3).map { _ in Ghostty.SurfaceView(nativeApp, baseConfig: config) }
        let firstID = UUID()
        let secondID = UUID()
        let tabIDs = Set([firstID, secondID])
        let workspace = TerminalWorkspace.defaultID
        let trees: [SplitTree<Ghostty.SurfaceView>] = [
            .init(root: .split(.init(direction: .vertical, ratio: 0.35,
                left: .leaf(view: panes[0]), right: .leaf(view: panes[1]))), zoomed: nil),
            .init(view: panes[2]),
        ]
        var encoded = TerminalWorkspaceSessionStore.Snapshot()
        for (id, tree) in zip([firstID, secondID], trees) {
            let state = TerminalRestorableState.InternalState(
                focusedSurface: tree.first?.id.uuidString, surfaceTree: tree,
                effectiveFullscreenMode: nil, tabColor: nil, titleOverride: nil,
                tabSessionID: id.uuidString, tabCreatedAt: Date()
            )
            encoded.tabs.append(.init(id: id, workspace: workspace,
                state: try JSONEncoder().encode(state)))
        }
        #expect(TerminalController.all.allSatisfy { !tabIDs.contains($0.tabSessionID) })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(encoded).write(to: url)
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.prepare()
        #expect(store.ownsRestoration)
        store.start(app)
        let restored = TerminalController.all.filter { tabIDs.contains($0.tabSessionID) }
        defer {
            for controller in restored {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        #expect(restored.count == 2)
        #expect(Set(restored.flatMap { $0.surfaceTree.map(\.id) }) == Set(panes.map(\.id)))
        let restoredSplit = try #require(restored.first { $0.tabSessionID == firstID })
        #expect(restoredSplit.surfaceTree.isSplit)
        #expect(restoredSplit.window?.tabGroup?.windows.count == 2)
        let savedAgain = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(Set(savedAgain.tabs.map(\.id)).isSuperset(of: tabIDs))
    }

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
