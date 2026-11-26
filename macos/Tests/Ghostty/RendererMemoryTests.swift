import AppKit
import Foundation
import Testing
@testable import Ghostty
@testable import GhosttyKit

@MainActor
struct RendererMemoryTests {
    @Test func inactiveSurfacesRetainTheirLastImageAndResumeRendering() async throws {
        guard let label = try? String(contentsOfFile: "/tmp/omg-memory-probe", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let app = try #require(NSApp.delegate as? AppDelegate)
        var controllers: [TerminalController] = []
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        for _ in 0..<4 {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "printf 'memory probe\n'; sleep 30"
            let controller = TerminalController(app.ghostty, withBaseConfig: config)
            controllers.append(controller)
            controller.window?.setContentSize(.init(width: 1600, height: 900))
            controller.window?.makeKeyAndOrderFront(nil)
        }
        try await Task.sleep(for: .milliseconds(600))
        let views = try controllers.map { try #require($0.surfaceTree.first) }
        let handles = try views.map { try #require($0.surface) }
        for _ in 0..<4 {
            for handle in handles { ghostty_surface_set_occlusion(handle, true); ghostty_surface_refresh(handle) }
            try await Task.sleep(for: .milliseconds(80))
        }
        func footprint(_ phase: String) async throws {
            let pid = ProcessInfo.processInfo.processIdentifier
            try await Task.detached {
                let process = Process(); let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
                process.arguments = ["-p", String(pid)]
                process.standardOutput = pipe; process.standardError = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try data.write(to: URL(fileURLWithPath: "/tmp/omg-memory-\(label)-\(phase).txt"))
            }.value
        }
        try await footprint("visible")
        for handle in handles { ghostty_surface_set_occlusion(handle, false) }
        try await Task.sleep(for: .milliseconds(500))
        try await footprint("hidden")
        for _ in 0..<4 {
            for view in views { view.layer?.display() }
            try await Task.sleep(for: .milliseconds(60))
        }
        try await footprint("hidden-redraw")
        for view in views { #expect(view.layer?.contents != nil) }
        for handle in handles { ghostty_surface_set_occlusion(handle, true); ghostty_surface_refresh(handle) }
        try await Task.sleep(for: .milliseconds(200))
        for view in views { #expect(view.layer?.contents != nil) }
        try await footprint("resumed")
    }

    @Test func evaluateSurfaceOcclusionStateDistinguishesOccludedWindowFromHibernationTargets() {
        let store = EditorWorkspaceStore()
        let surfaceID = UUID()

        // 1. Active tab, visible window: visible and not hibernation-eligible.
        let visibleState = BaseTerminalController.evaluateSurfaceOcclusionState(
            viewID: surfaceID,
            isControllerPresenting: true,
            isControllerRetainingPresentedSurfaces: true,
            zoomedNode: nil,
            editorWorkspaceStore: store
        )
        #expect(visibleState == .init(visible: true, hibernationEligible: false))

        // 2. Active tab, merely occluded normal window (e.g. another Space or covered
        //    by another app): occluded so spare swapchain buffers trim immediately,
        //    but ineligible for front-frame hibernation so Mission Control stays intact.
        let occludedNormalWindow = BaseTerminalController.evaluateSurfaceOcclusionState(
            viewID: surfaceID,
            isControllerPresenting: false,
            isControllerRetainingPresentedSurfaces: true,
            zoomedNode: nil,
            editorWorkspaceStore: store
        )
        #expect(occludedNormalWindow == .init(visible: false, hibernationEligible: false))

        // 3. Minimized/hidden window or unselected background tab: occluded and
        //    eligible for 5s front-frame hibernation.
        let offWindow = BaseTerminalController.evaluateSurfaceOcclusionState(
            viewID: surfaceID,
            isControllerPresenting: false,
            isControllerRetainingPresentedSurfaces: false,
            zoomedNode: nil,
            editorWorkspaceStore: store
        )
        #expect(offWindow == .init(visible: false, hibernationEligible: true))

        // 4. Editor-covered split remains hibernation-eligible even when its window
        //    retains front frames.
        let workspace = store.workspace(for: UUID(), surfaceID: surfaceID)
        workspace.isVisible = true
        let editorCovered = BaseTerminalController.evaluateSurfaceOcclusionState(
            viewID: surfaceID,
            isControllerPresenting: false,
            isControllerRetainingPresentedSurfaces: true,
            zoomedNode: nil,
            editorWorkspaceStore: store
        )
        #expect(editorCovered == .init(visible: false, hibernationEligible: true))
    }

    @Test func controllerOcclusionSyncPreservesFrontFrameOnlyForActiveTabOfNormalOccludedWindow() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        guard let coreApp = app.app else {
            Issue.record("Ghostty core app unavailable in test harness")
            return
        }

        let editorStore = EditorWorkspaceStore()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        let secondSurface = Ghostty.SurfaceView(coreApp, baseConfig: config)
        let siblingController = TerminalController(app, withBaseConfig: config)
        defer {
            editorStore.remove(surfaceIDs: controller.surfaceTree.map(\.id))
            window.delegate = nil
            window.close()
            siblingController.window?.delegate = nil
            siblingController.window?.close()
        }

        controller.editorWorkspaceStore = editorStore
        let primarySurface = try #require(controller.surfaceTree.first)
        let leftLeaf = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: primarySurface)
        let rightLeaf = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: secondSurface)
        let splitNode = SplitTree<Ghostty.SurfaceView>.Node.split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: leftLeaf,
            right: rightLeaf
        ))
        controller.surfaceTree = .init(root: splitNode, zoomed: nil)

        // 1. Visible active window: both splits visible, neither hibernation-eligible.
        controller.presentationRetainedOverrideForTesting = true
        controller.windowOcclusionOverrideForTesting = true
        controller.syncSurfaceTreeOcclusionState()
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(primarySurface.lastSentCoreHibernationEligible == false)
        #expect(secondSurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)

        // 2. Normal window merely occluded (another Space or behind another app):
        //    occluded for immediate spare-buffer trim, but front frames retained.
        controller.windowOcclusionOverrideForTesting = false
        controller.syncSurfaceTreeOcclusionState()
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastSentCoreHibernationEligible == false)
        #expect(secondSurface.lastSentCoreOcclusionState == false)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)

        // 3. Split zoom while occluded: zoomed split still retains its front frame,
        //    while hidden sibling becomes hibernation-eligible.
        controller.surfaceTree = .init(root: splitNode, zoomed: leftLeaf)
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastSentCoreHibernationEligible == false)
        #expect(secondSurface.lastSentCoreOcclusionState == false)
        #expect(secondSurface.lastSentCoreHibernationEligible == true)

        controller.surfaceTree = .init(root: splitNode, zoomed: nil)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)

        // 4. Editor covering a split while occluded makes that split hibernation-eligible.
        let editorWorkspace = editorStore.workspace(for: controller.tabSessionID, surfaceID: primarySurface.id)
        editorWorkspace.isVisible = true
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastSentCoreHibernationEligible == true)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)
        editorWorkspace.isVisible = false
        #expect(primarySurface.lastSentCoreHibernationEligible == false)

        // 5. Unselected background tab becomes hibernation-eligible.
        controller.applyWorkspaceTabProjection([controller, siblingController], selected: siblingController)
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastSentCoreHibernationEligible == true)
        #expect(secondSurface.lastSentCoreHibernationEligible == true)

        controller.applyWorkspaceTabProjection([controller, siblingController], selected: controller)
        #expect(primarySurface.lastSentCoreHibernationEligible == false)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)

        // 6. Parked workspace controller becomes hibernation-eligible.
        controller.workspacePresentationIsParked = true
        #expect(primarySurface.lastSentCoreHibernationEligible == true)
        #expect(secondSurface.lastSentCoreHibernationEligible == true)
        controller.workspacePresentationIsParked = false
        #expect(primarySurface.lastSentCoreHibernationEligible == false)

        // 7. Minimized or hidden window becomes hibernation-eligible.
        controller.presentationRetainedOverrideForTesting = false
        controller.syncSurfaceTreeOcclusionState()
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastSentCoreHibernationEligible == true)
        #expect(secondSurface.lastSentCoreOcclusionState == false)
        #expect(secondSurface.lastSentCoreHibernationEligible == true)

        // 8. Mission Control Exposé pauses live surface presentation (cursor blink / spinner swaps)
        //    while keeping the active tab's front GPU frame retained (`hibernationEligible == false`).
        let mcMonitor = MissionControlPresentationMonitor.shared
        defer { mcMonitor.overrideForTesting = nil }
        controller.presentationRetainedOverrideForTesting = true
        controller.windowOcclusionOverrideForTesting = true
        mcMonitor.overrideForTesting = true
        controller.syncSurfaceTreeOcclusionState()
        #expect(primarySurface.lastSentCoreOcclusionState == false)
        #expect(primarySurface.lastSentCoreHibernationEligible == false)
        #expect(secondSurface.lastSentCoreOcclusionState == false)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)

        mcMonitor.overrideForTesting = false
        controller.syncSurfaceTreeOcclusionState()
        #expect(primarySurface.lastSentCoreOcclusionState == true)
        #expect(primarySurface.lastSentCoreHibernationEligible == false)
        #expect(secondSurface.lastSentCoreOcclusionState == true)
        #expect(secondSurface.lastSentCoreHibernationEligible == false)
    }
}
