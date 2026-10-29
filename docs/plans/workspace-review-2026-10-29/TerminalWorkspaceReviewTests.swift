import AppKit
import Testing
@testable import Ghostty

/// Temporary review probes: assert and print observed behavior, not acceptance criteria.
/// Removed from the test target after evidence is collected.
@Suite(.serialized) @MainActor
struct TerminalWorkspaceReviewTests {
    private func config() -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        return config
    }

    @Test func undoRestoredTabRemainsExcludedFromCheckpoint() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.json")
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true)
        let original = TerminalController(app, withBaseConfig: config())
        _ = original.window
        let undo = try #require(original.undoState)
        sessions.start(app)
        sessions.forget(original)
        original.closeTabImmediately(registerRedo: false)
        let restored = TerminalController(app, with: undo)
        defer {
            for controller in [original, restored] {
                controller.cancelWorkspacePendingPresentation()
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        try #require(restored.isAvailableForWorkspace)
        sessions.capture()
        let saved = try JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: Data(contentsOf: url))
        let included = saved.tabs.contains { $0.id == restored.tabSessionID }
        print("REVIEW_PROBE undo: restoredAvailable=\(restored.isAvailableForWorkspace), includedInCheckpoint=\(included)")
        #expect(!included)
    }

    @Test func parallelWindowLayoutOverwritesOtherWindowChange() throws {
        let store = TerminalWorkspaceStore.shared
        let workspace = try #require(store.create(name: "Review layout", symbol: "house", color: "blue"))
        defer { store.delete(id: workspace) }
        let first = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let second = VerticalTabWindowLayoutState(isSidebarVisible: true)
        first.bindWorkspace(workspace)
        second.bindWorkspace(workspace)
        first.setSidebarVisible(false)
        let before = store.presentation(for: workspace)
        second.setInspectorVisible(true)
        let after = store.presentation(for: workspace)
        print("REVIEW_PROBE layout: persistedSidebarBefore=\(before.sidebarVisible), afterUnrelatedInspectorChange=\(after.sidebarVisible), firstWindowSidebar=\(first.isSidebarVisible), secondWindowSidebar=\(second.isSidebarVisible)")
        #expect(!before.sidebarVisible)
        #expect(after.sidebarVisible)
        #expect(first.isSidebarVisible != second.isSidebarVisible)
    }

    @Test func deletingParkedWorkspaceHidesOtherVisibleHost() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore.shared
        let coordinator = TerminalWorkspaceCoordinator.shared
        coordinator.finishRestoring()
        let workspace = try #require(store.create(name: "Review delete", symbol: "house", color: "blue"))
        let first = TerminalController(app, withBaseConfig: config(), workspaceID: workspace)
        let second = TerminalController(app, withBaseConfig: config(), workspaceID: workspace)
        var controllers = [first, second]
        defer {
            for controller in controllers {
                controller.cancelWorkspacePendingPresentation()
                controller.window?.close()
            }
            store.delete(id: workspace)
        }
        first.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(first)
        second.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(second)
        let fallback = try #require(coordinator.switchWorkspace(to: store.defaultID, from: second))
        controllers.append(fallback)
        try #require(fallback.window?.isVisible == true)
        try #require(second.workspacePresentationIsParked)
        first.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(first)
        try #require(coordinator.deleteWorkspace(workspace))
        let hostVisible = TerminalController.all.contains {
            $0.windowSessionID == second.windowSessionID && $0.isAvailableForWorkspace && $0.window?.isVisible == true
        }
        print("REVIEW_PROBE delete: otherHostVisible=\(hostVisible), fallbackParked=\(fallback.workspacePresentationIsParked), fallbackVisible=\(fallback.window?.isVisible == true)")
        #expect(!hostVisible)
        #expect(fallback.workspacePresentationIsParked)
    }

    @Test func movingOneTabOutOfParkedGroupLosesRemainingOrder() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore.shared
        let coordinator = TerminalWorkspaceCoordinator.shared
        coordinator.finishRestoring()
        let workspace = try #require(store.create(name: "Review parked move", symbol: "house", color: "blue"))
        let first = TerminalController(app, withBaseConfig: config(), workspaceID: workspace)
        let firstWindow = try #require(first.window)
        let second = TerminalController(app, withBaseConfig: config(), parent: firstWindow, workspaceID: workspace)
        let secondWindow = try #require(second.window)
        var controllers = [first, second]
        defer {
            for controller in controllers {
                controller.cancelWorkspacePendingPresentation()
                controller.window?.close()
            }
            store.delete(id: workspace)
        }
        try #require(firstWindow.addTabbedWindowSafely(secondWindow, ordered: .above))
        second.finishWorkspaceTabAttachment()
        first.refreshWorkspaceTabs()
        firstWindow.makeKeyAndOrderFront(nil)
        coordinator.didActivate(first)
        let fallback = try #require(coordinator.switchWorkspace(to: store.defaultID, from: first))
        controllers.append(fallback)
        try #require(first.workspacePresentationIsParked && second.workspacePresentationIsParked)
        let originalGroup = first.workspaceGroupID
        let before = store.group(window: first.windowSessionID, workspace: workspace)?.tabs ?? []
        try #require(coordinator.move(first, to: store.defaultID, replacingLastTab: false))
        let after = store.group(window: second.windowSessionID, workspace: workspace)?.tabs ?? []
        print("REVIEW_PROBE parkedMove: sourceTabsBefore=\(before.count), after=\(after.count), remainingTabAvailable=\(second.isAvailableForWorkspace), sameGroup=\(second.workspaceGroupID == originalGroup)")
        #expect(before.count == 2)
        #expect(after.isEmpty)
        #expect(second.isAvailableForWorkspace)
    }

    @Test func deletingWorkspaceCanFailAfterMovingSomeTabs() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore.shared
        let coordinator = TerminalWorkspaceCoordinator.shared
        coordinator.finishRestoring()
        let workspace = try #require(store.create(name: "Review partial delete", symbol: "house", color: "blue"))
        let first = TerminalController(app, withBaseConfig: config(), workspaceID: workspace)
        let second = TerminalController(app, withBaseConfig: config(), workspaceID: workspace)
        let controllers = [first, second]
        defer {
            for controller in controllers {
                controller.window?.tabbingMode = .preferred
                controller.cancelWorkspacePendingPresentation()
                controller.window?.close()
            }
            store.delete(id: workspace)
        }
        first.window?.makeKeyAndOrderFront(nil)
        second.window?.makeKeyAndOrderFront(nil)
        let affected = coordinator.controllers(in: workspace)
        try #require(affected.count == 2)
        affected.last?.window?.tabbingMode = .disallowed
        let result = coordinator.deleteWorkspace(workspace)
        let moved = controllers.filter { $0.workspaceID == store.defaultID }.count
        print("REVIEW_PROBE partialDelete: result=\(result), labelStillExists=\(store.workspaces.contains { $0.id == workspace }), tabsAlreadyMoved=\(moved)")
        #expect(!result)
        #expect(moved == 1)
        #expect(store.workspaces.contains { $0.id == workspace })
    }

    @Test func mismatchedCatalogAndSessionGenerationsRestoreUnknownWorkspace() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sessions.json")
        let store = TerminalWorkspaceStore(fileURL: nil)
        let source = TerminalController(app, withBaseConfig: config())
        _ = source.window
        let data = try JSONEncoder().encode(TerminalRestorableState(from: source))
        let orphanID = UUID(), tabID = UUID(), hostID = UUID(), groupID = UUID()
        var snapshot = TerminalWorkspaceSessionStore.Snapshot()
        snapshot.tabs = [.init(id: tabID, workspace: orphanID, state: data, group: groupID, window: hostID)]
        try JSONEncoder().encode(snapshot).write(to: url)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        sessions.prepare()
        sessions.start(app)
        let restored = try #require(TerminalController.all.first { $0.tabSessionID == tabID })
        defer {
            for controller in [source, restored] {
                controller.cancelWorkspacePendingPresentation()
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let known = store.workspaces.contains { $0.id == restored.workspaceID }
        print("REVIEW_PROBE writeSkew: restoredWorkspaceKnown=\(known), displayFallsBackToDefault=\(store.workspace(restored.workspaceID).id == store.defaultID), unknownGroupPersisted=\(store.group(window: hostID, workspace: orphanID) != nil)")
        #expect(!known)
        #expect(restored.workspaceID == orphanID)
        #expect(store.group(window: hostID, workspace: orphanID) != nil)
    }

    @Test func unchangedCapturesCanRewriteWholeCheckpoint() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.json")
        let controller = TerminalController(app, withBaseConfig: config())
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true)
        sessions.start(app)
        var previous = try Data(contentsOf: url)
        var differentBytes = 0
        var differentObjects = 0
        var differentSemantics = 0
        var replacedFiles = 0
        var inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        func semanticObject(_ data: Data) throws -> NSDictionary {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var tabs = try #require(object["tabs"] as? [[String: Any]])
            for index in tabs.indices {
                let text = try #require(tabs[index]["state"] as? String)
                let payload = try #require(Data(base64Encoded: text))
                tabs[index]["state"] = try JSONSerialization.jsonObject(with: payload)
            }
            object["tabs"] = tabs
            return object as NSDictionary
        }
        let start = Date()
        for _ in 0..<10 {
            sessions.capture()
            let current = try Data(contentsOf: url)
            if previous != current { differentBytes += 1 }
            let oldObject = try JSONSerialization.jsonObject(with: previous) as? NSDictionary
            let newObject = try JSONSerialization.jsonObject(with: current) as? NSDictionary
            if oldObject != newObject { differentObjects += 1 }
            if try semanticObject(previous) != semanticObject(current) { differentSemantics += 1 }
            let newInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            if newInode != inode { replacedFiles += 1 }
            inode = newInode
            previous = current
        }
        print("REVIEW_PROBE idleCapture: changedBytes=\(differentBytes)/10, changedOuterJSON=\(differentObjects)/10, changedSemantics=\(differentSemantics)/10, replacedFiles=\(replacedFiles)/10, elapsedMs=\(Date().timeIntervalSince(start) * 1000)")
    }

    @Test func emptyCheckpointClaimsRestorationOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sessions.json")
        try JSONEncoder().encode(TerminalWorkspaceSessionStore.Snapshot()).write(to: url)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: TerminalWorkspaceStore(fileURL: nil))
        sessions.prepare()
        print("REVIEW_PROBE emptySnapshot: ownsRestoration=\(sessions.ownsRestoration)")
        #expect(sessions.ownsRestoration)
    }
}
