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

    @Test func startupPreservesSavedManualTabOrderAfterPresentation() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let nativeApp = try #require(app.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let ids = (0..<4).map { _ in UUID() }
        var snapshot = TerminalWorkspaceSessionStore.Snapshot()
        for (index, id) in ids.enumerated() {
            let view = Ghostty.SurfaceView(nativeApp, baseConfig: config)
            let state = TerminalRestorableState.InternalState(
                focusedSurface: view.id.uuidString, surfaceTree: SplitTree(view: view),
                effectiveFullscreenMode: nil, tabColor: nil, titleOverride: "Order \(index)",
                tabSessionID: id.uuidString, tabCreatedAt: Date(timeIntervalSince1970: Double(4 - index))
            )
            snapshot.tabs.append(.init(id: id, workspace: TerminalWorkspace.defaultID,
                state: try JSONEncoder().encode(state)))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url)
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.prepare()
        store.start(app)
        let restored = TerminalController.all.filter { ids.contains($0.tabSessionID) }
        defer {
            for controller in restored {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let first = try #require(restored.first { $0.tabSessionID == ids[0] })
        let group = try #require(first.window?.tabGroup)
        func nativeOrder() -> [UUID] {
            group.windows.compactMap { ($0.windowController as? TerminalController)?.tabSessionID }
        }
        #expect(nativeOrder() == ids)
        try await Task.sleep(for: .milliseconds(250))
        #expect(nativeOrder() == ids)
        #expect(first.tabControllers.map(\.tabSessionID) == ids)
        store.capture()
        let captured = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(captured.tabs.filter { ids.contains($0.id) }.map(\.id) == ids)
    }

    @Test func quitKeepsManualOrderAndCancelResumesLayoutChanges() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controllers = (0..<4).map { _ in TerminalController(app, withBaseConfig: config) }
        let windows = try controllers.map { try #require($0.window) }
        defer {
            for window in windows {
                window.delegate = nil
                window.close()
            }
        }
        for index in 1..<windows.count {
            #expect(windows[index - 1].addTabbedWindowSafely(windows[index], ordered: .above))
        }
        let group = try #require(windows[0].tabGroup)
        // An explicit drag order must survive, independently of creation time.
        let manual = [windows[2], windows[0], windows[3], windows[1]]
        func reorder(_ order: [NSWindow]) {
            for (index, window) in order.enumerated() where group.windows[index] !== window {
                group.removeWindow(window)
                group.insertWindow(window, at: index)
            }
        }
        reorder(manual)
        let ids = Set(controllers.map(\.tabSessionID))
        func savedOrder() throws -> [UUID] {
            let snapshot = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
            return snapshot.tabs.filter { ids.contains($0.id) }.map(\.id)
        }
        let expected = manual.compactMap { ($0.windowController as? TerminalController)?.tabSessionID }
        let store = TerminalWorkspaceSessionStore(url: url, testing: true)
        store.start(app)
        store.prepareToQuit()
        #expect(try savedOrder() == expected)
        let beforeTeardown = try Data(contentsOf: url)
        // AppKit changes the live group order as it closes tab windows. Timer,
        // window-close, explicit-close and termination callbacks must freeze it.
        reorder(Array(manual.reversed()))
        store.capture()
        store.forget(controllers[0])
        store.prepareToQuit()
        #expect(try Data(contentsOf: url) == beforeTeardown)
        #expect(try savedOrder() == expected)

        store.cancelQuit()
        #expect(try savedOrder() == Array(expected.reversed()))
        store.forget(controllers[0])
        #expect(try savedOrder() == Array(expected.reversed()).filter { $0 != controllers[0].tabSessionID })
        store.prepareToQuit()
        reorder(manual)
        store.capture()
        #expect(try savedOrder() == Array(expected.reversed()).filter { $0 != controllers[0].tabSessionID })
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
