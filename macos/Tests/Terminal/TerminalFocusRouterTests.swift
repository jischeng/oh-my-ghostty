import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalFocusRouterTests {
    @Test func focusSurfaceSwitchesParkedWorkspaceUnzoomsSiblingAndHidesCoveringEditor() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()

        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp"

        let defaultController = TerminalController(
            app,
            withBaseConfig: config,
            workspaceID: store.defaultID,
            workspaceCoordinator: coordinator
        )
        defaultController.window?.makeKeyAndOrderFront(nil)

        let backendController = try #require(coordinator.createWorkspace(
            name: "Backend",
            symbol: "house",
            color: "blue",
            from: defaultController
        ))
        defer {
            for controller in [defaultController, backendController] {
                EditorWorkspaceStore.shared.remove(tabID: controller.tabSessionID)
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }

        let leftSurface = try #require(backendController.focusedSurface)
        let rightSurface = try #require(backendController.newSplit(
            at: leftSurface,
            direction: .right,
            baseConfig: config
        ))

        // Zoom the left sibling split and cover the right split with a full-pane EditorWorkspace.
        #expect(leftSurface.surfaceModel?.perform(action: "toggle_split_zoom") == true)
        #expect(backendController.surfaceTree.zoomed != nil)
        #expect(backendController.surfaceTree.zoomed?.find(id: rightSurface.id) == nil)

        let coveringEditor = backendController.editorWorkspaceStore.workspace(
            for: backendController.tabSessionID,
            surfaceID: rightSurface.id
        )
        coveringEditor.isVisible = true
        #expect(coveringEditor.isVisible)

        // Park the Backend workspace by switching back to the Default workspace.
        _ = try #require(coordinator.switchWorkspace(to: store.defaultID, from: backendController))
        #expect(backendController.workspacePresentationIsParked)

        // Routing focus to `rightSurface` must unpark its workspace, unzoom the sibling split,
        // collapse the covering editor, and focus `rightSurface`.
        #expect(TerminalFocusRouter.focus(
            surface: rightSurface,
            activateApp: false,
            coordinator: coordinator
        ))
        #expect(!backendController.workspacePresentationIsParked)
        #expect(backendController.surfaceTree.zoomed == nil)
        #expect(!coveringEditor.isVisible)
        #expect(backendController.focusedSurface === rightSurface)
    }

    @Test func findSurfaceResolvesActiveParkedAndQuickTerminalSurfaces() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()

        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp"

        let activeController = TerminalController(
            app,
            withBaseConfig: config,
            workspaceID: store.defaultID,
            workspaceCoordinator: coordinator
        )
        activeController.window?.makeKeyAndOrderFront(nil)

        let parkedController = try #require(coordinator.createWorkspace(
            name: "Parked",
            symbol: "terminal",
            color: "green",
            from: activeController
        ))
        _ = try #require(coordinator.switchWorkspace(to: store.defaultID, from: parkedController))
        #expect(parkedController.workspacePresentationIsParked)

        let quickController = QuickTerminalController(app, baseConfig: config)
        let cApp = try #require(app.app)
        let quickSurface = Ghostty.SurfaceView(cApp, baseConfig: config)
        quickController.surfaceTree = SplitTree(view: quickSurface)

        defer {
            quickController.surfaceTree = .init()
            quickController.window?.delegate = nil
            quickController.window?.close()
            for controller in [activeController, parkedController] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }

        let activeSurface = try #require(activeController.surfaceTree.first)
        let parkedSurface = try #require(parkedController.surfaceTree.first)

        #expect(TerminalFocusRouter.findSurface(
            forUUID: activeSurface.id,
            coordinator: coordinator,
            quickController: quickController
        ) === activeSurface)
        #expect(TerminalFocusRouter.findSurface(
            forUUID: parkedSurface.id,
            coordinator: coordinator,
            quickController: quickController
        ) === parkedSurface)
        #expect(TerminalFocusRouter.findSurface(
            forUUID: quickSurface.id,
            coordinator: coordinator,
            quickController: quickController
        ) === quickSurface)
        #expect(TerminalFocusRouter.findSurface(
            forUUID: UUID(),
            coordinator: coordinator,
            quickController: quickController
        ) == nil)
    }

    @Test func dockBadgeCountsUnacknowledgedAttentionAndClearsOnAcknowledge() throws {
        #expect(DockBadgePolicy.badgeLabel(
            bellCount: 0,
            bellAttentionEnabled: true,
            unacknowledgedAttentionCount: 0
        ) == nil)
        #expect(DockBadgePolicy.badgeLabel(
            bellCount: 2,
            bellAttentionEnabled: false,
            unacknowledgedAttentionCount: 1
        ) == "1")
        #expect(DockBadgePolicy.badgeLabel(
            bellCount: 2,
            bellAttentionEnabled: true,
            unacknowledgedAttentionCount: 1
        ) == "3")
        #expect(DockBadgePolicy.badgeLabel(
            bellCount: 60,
            bellAttentionEnabled: true,
            unacknowledgedAttentionCount: 50
        ) == "99+")

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.surfaceTree.first)
        let tabActivities = TabActivityStore()

        #expect(tabActivities.set(
            PluginSetSessionStatus(
                sessionID: surface.id,
                revision: 1,
                status: PluginSessionStatus(
                    agent: "claude",
                    title: "Claude",
                    state: .waiting,
                    message: "Needs tool approval"
                ),
                ttlMilliseconds: nil
            ),
            pluginID: "test.plugin",
            sessionExists: { $0 == surface.id }
        ) == nil)
        #expect(TerminalFocusRouter.unacknowledgedAttentionCount(
            controllers: [controller],
            tabActivities: tabActivities
        ) == 1)

        TerminalFocusRouter.acknowledgeDockAttention(
            for: surface,
            in: controller,
            tabActivities: tabActivities
        )
        #expect(TerminalFocusRouter.unacknowledgedAttentionCount(
            controllers: [controller],
            tabActivities: tabActivities
        ) == 0)

        // A new attention/error transition on the same surface re-arms the Dock badge.
        #expect(tabActivities.set(
            PluginSetSessionStatus(
                sessionID: surface.id,
                revision: 2,
                status: PluginSessionStatus(
                    agent: "claude",
                    title: "Claude",
                    state: .failed,
                    message: "Agent command failed"
                ),
                ttlMilliseconds: nil
            ),
            pluginID: "test.plugin",
            sessionExists: { $0 == surface.id }
        ) == nil)
        #expect(TerminalFocusRouter.unacknowledgedAttentionCount(
            controllers: [controller],
            tabActivities: tabActivities
        ) == 1)

        // Clearing the activity clears the count as well.
        #expect(tabActivities.clear(
            PluginClearSessionStatus(sessionID: surface.id, revision: 3),
            pluginID: "test.plugin"
        ) == nil)
        #expect(TerminalFocusRouter.unacknowledgedAttentionCount(
            controllers: [controller],
            tabActivities: tabActivities
        ) == 0)
    }
}
