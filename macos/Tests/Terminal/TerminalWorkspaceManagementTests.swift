import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceManagementTests {
    @MainActor final class Fixture {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator: TerminalWorkspaceCoordinator
        let controller: TerminalController
        var deferred: (() -> Void)?
        var reopenCount = 0
        lazy var model = TerminalWorkspacePickerModel(controller: controller, dismiss: { [weak self] in self?.deferred = $0 },
            reopen: { [weak self] in self?.reopenCount += 1 })

        init() throws {
            let app = try #require(NSApp.delegate as? AppDelegate).ghostty
            coordinator = TerminalWorkspaceCoordinator(store: store)
            coordinator.finishRestoring()
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/sleep 60"
            controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
            _ = controller.window
        }
        func close() { for controller in coordinator.liveControllers { controller.window?.close() } }
    }

    @Test func deferredRestoreDoesNotToggleOffUserEnteredFullscreen() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let fixture = try Fixture()
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: fixture.store)
        fixture.coordinator.useSessions(sessions)
        sessions.start(app)
        fixture.store.transaction {
            $0.windows?[fixture.controller.windowSessionID]?.fullscreen = true
            $0.windows?[fixture.controller.windowSessionID]?.fullscreenMode = .nonNative
        }
        sessions.capture()
        sessions.flush()
        fixture.coordinator.prepareToQuit()
        fixture.controller.window?.close()
        let store = TerminalWorkspaceStore(fileURL: nil)
        let restoredSessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        let runtime = TerminalWorkspaceCoordinator(store: store, sessions: restoredSessions)
        restoredSessions.prepare()
        restoredSessions.start(app)
        runtime.finishRestoring()
        defer { for controller in runtime.liveControllers { controller.window?.close() } }
        let controller = try #require(runtime.liveControllers.first)
        // User action wins before the queued automatic restore executes.
        controller.toggleFullscreen(mode: .nonNative)
        try #require(controller.fullscreenStyle?.isFullscreen == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.fullscreenStyle?.isFullscreen == true)
        controller.toggleFullscreen(mode: .nonNative)
    }

    @Test func fullscreenCompletionDoesNotReenterTheNativeNotification() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        var completed = false
        fixture.coordinator.native.transitionCompleted = { _ in completed = true }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(!completed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed)
    }

    @Test func incomingHeaderAndLayoutResolveBeforeTheWindowIsShown() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var inspected = false
        fixture.coordinator.native.show = { controller in
            inspected = true
            // Catalog commit deliberately follows native presentation.
            #expect(!fixture.store.workspaces.contains { $0.id == controller.workspaceID })
            #expect(fixture.coordinator.presentationWorkspace(controller.workspaceID)?.name == "Destination")
            #expect(controller.tabLayoutState.workspaceBindingID == controller.workspaceID)
            return controller.showWindowSafely(nil)
        }
        let result = fixture.coordinator.createWorkspace(name: "Destination", symbol: "house", color: "blue", from: fixture.controller)
        #expect(result != nil)
        #expect(inspected)
        #expect(fixture.coordinator.presentationWorkspace(UUID()) == nil)
    }

    @Test func createCommitsCatalogAndTerminalTogetherAfterDismissal() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.beginCreate()
        model.name = "Created together"
        model.save()
        #expect(model.isPerforming)
        #expect(fixture.store.workspaces.count == 1)
        fixture.deferred?()
        #expect(!model.isPerforming)
        let created = try #require(fixture.store.workspaces.first { $0.name == "Created together" })
        let controller = try #require(fixture.coordinator.controllers(in: created.id).first)
        #expect(controller.window?.isVisible == true)
        #expect(fixture.store.snapshot.windows?[fixture.controller.windowSessionID]?.currentWorkspace == created.id)
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
    }

    @Test func failedCreateRetainsFormAndDoesNotLeaveAnEmptyWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.native.show = { _ in false }
        let before = fixture.store.snapshot
        let model = fixture.model
        model.beginCreate()
        model.name = "Retry me"
        model.symbol = "cloud"
        model.save()
        fixture.deferred?()
        #expect(fixture.store.snapshot == before)
        #expect(model.page == .create)
        #expect(model.name == "Retry me" && model.symbol == "cloud")
        #expect(model.error != nil)
        #expect(fixture.reopenCount == 1)
    }

    @Test func editAndDeleteUseTheExplicitRowInsteadOfTheActiveWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let other = try #require(fixture.store.create(name: "Other", symbol: "house", color: "blue"))
        let model = fixture.model
        model.beginEdit(other)
        model.selectedID = fixture.store.defaultID
        model.name = "Renamed other"
        model.save()
        #expect(fixture.store.workspace(other).name == "Renamed other")
        #expect(fixture.store.workspace(fixture.store.defaultID).name == "Personal")
        #expect(fixture.controller.workspaceID == fixture.store.defaultID)
        model.beginDelete(other)
        model.selectedID = fixture.store.defaultID
        model.confirmDelete()
        fixture.deferred?()
        #expect(!fixture.store.workspaces.contains { $0.id == other })
        #expect(fixture.controller.isAvailableForWorkspace)
    }

    @Test func moveListExcludesCurrentWorkspaceAndSearchDoesNotChangeOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let other = try #require(fixture.store.create(name: "Destination", symbol: "house", color: "blue"))
        let model = fixture.model
        model.beginMove()
        #expect(model.filtered.map(\.id) == [other])
        model.query = "missing"
        #expect(model.filtered.isEmpty)
        #expect(fixture.controller.workspaceID == fixture.store.defaultID)
        model.cancel()
        #expect(model.page == .switcher)
    }

    @Test func nativeTransitionOwnershipSurvivesLogicalIdentityChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        let host = fixture.controller.windowSessionID
        let unrelated = TerminalWorkspaceNativeAdapter()
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(fixture.coordinator.native.transitioningWindows.contains(host))
        #expect(unrelated.transitioningWindows.isEmpty)
        fixture.controller.windowSessionID = UUID()
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(!fixture.coordinator.native.transitioningWindows.contains(host))
        fixture.controller.windowSessionID = host
    }

    @Test func sharedWorkspacePersistenceIsDisabledForTestProcesses() {
        #expect(ProcessInfo.processInfo.environment["OMG_TESTING"] == "1")
        #expect(OMGApplicationEnvironment.isRunningTests)
    }

    @Test func managementPagesRenderAtBoundedSize() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for index in 1...8 { _ = fixture.store.create(name: "Project \(index)", symbol: "briefcase", color: "blue") }
        let model = fixture.model
        let host = NSHostingView(rootView: TerminalWorkspacePicker(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(50))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width == 360)
            #expect(host.fittingSize.height < 600)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/omg-workspace-management-\(name).png"))
        }
        try await capture("switcher")
        model.beginCreate()
        model.name = "New project"
        try await capture("create")
        model.beginMove()
        try await capture("move")
        model.beginDelete(try #require(fixture.store.workspaces.last).id)
        try await capture("delete")
    }

    @Test func immediateExitCancelsDeferredBorderlessEntryGeometry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        window.setFrame(.init(x: 80, y: 100, width: 780, height: 520), display: false)
        fixture.controller.toggleFullscreen(mode: .nonNative)
        fixture.controller.toggleFullscreen(mode: .nonNative)
        let restored = window.frame
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.controller.fullscreenStyle?.isFullscreen == false)
        #expect(window.frame == restored)
    }

    @Test func nonNativeFullscreenSupportsWorkspaceCreationAndReturn() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let sibling = try #require(TerminalController.newTab(app, from: fixture.controller.window!, withBaseConfig: config))
        try await Task.sleep(for: .milliseconds(80))
        fixture.controller.selectVerticalTab(fixture.controller)
        fixture.controller.window?.makeKeyAndOrderFront(nil)
        fixture.controller.toggleFullscreen(mode: .nonNative)
        try await Task.sleep(for: .milliseconds(100))
        try #require(fixture.controller.fullscreenStyle?.isFullscreen == true)
        #expect(fixture.controller.tabControllers.map(\.tabSessionID) == [fixture.controller.tabSessionID, sibling.tabSessionID])
        let target = try #require(fixture.coordinator.createWorkspace(name: "Borderless", symbol: "house", color: "blue", from: fixture.controller))
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.fullscreenStyle?.fullscreenMode == .nonNative)
        #expect(target.fullscreenStyle?.isFullscreen == true)
        #expect(target.window?.isVisible == true)
        #expect(fixture.store.snapshot.windows?[target.windowSessionID]?.fullscreenMode == .nonNative)
        for _ in 0..<5 {
            try #require(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: target) === fixture.controller)
            try #require(fixture.coordinator.switchWorkspace(to: target.workspaceID, from: fixture.controller) === target)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.window?.isVisible == true)
        #expect(fixture.controller.window?.isVisible == false)
        #expect(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: target) === fixture.controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.controller.fullscreenStyle?.isFullscreen == true)
        #expect(fixture.controller.tabControllers.map(\.tabSessionID) == [fixture.controller.tabSessionID, sibling.tabSessionID])
        fixture.controller.selectVerticalTab(sibling)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sibling.fullscreenStyle?.isFullscreen == true)
        #expect(sibling.tabControllers.count == 2)
        sibling.toggleFullscreen(mode: .nonNative)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sibling.window?.tabGroup?.windows.count == 2)
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
    }
}
