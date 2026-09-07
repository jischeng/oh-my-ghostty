import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct EditorPaneDestinationTests {
    @Test func allDestinationsSelectTheExpectedPaneAndSpatialDirection() async throws {
        let presentation = InspectorPresentationStore.shared.snapshot
        defer { InspectorPresentationStore.shared.replace(with: presentation) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = root.path
        configuration.command = "/bin/sh"

        // Each case starts from one pane so the direction assertions cannot wrap
        // around a tree left behind by a previous case.
        for destination in EditorOpenDestination.allCases {
            let controller = TerminalController(app, withBaseConfig: configuration)
            let window = try #require(controller.window)
            var controllers = [controller]
            defer {
                for owned in controllers.reversed() {
                    EditorWorkspaceStore.shared.remove(tabID: owned.tabSessionID)
                    owned.window?.delegate = nil
                    owned.window?.close()
                }
            }
            window.makeKeyAndOrderFront(nil)
            let source = try #require(controller.surfaceTree.first)
            let target = try #require(EditorPaneDestination.open(
                in: controller, source: source, destination: destination, configuration: configuration
            ))
            if target.controller !== controller { controllers.append(target.controller) }
            #expect(target.controller.focusedSurface === target.surface)
            #expect(target.surface.surface != nil)

            switch destination {
            case .currentPane:
                #expect(target.controller === controller)
                #expect(target.surface === source)
                #expect(controller.surfaceTree.root?.leaves().count == 1)
            case .newTab:
                #expect(target.controller !== controller)
                #expect(target.surface !== source)
                #expect(target.controller.tabSessionID != controller.tabSessionID)
                #expect(controller.surfaceTree.root?.leaves().count == 1)
                #expect(target.controller.surfaceTree.root?.leaves().count == 1)
                #expect(window.tabGroup === target.controller.window?.tabGroup)
                #expect(window.tabGroup != nil)
            case .splitRight, .splitDown, .splitLeft, .splitUp:
                #expect(target.controller === controller)
                #expect(target.surface !== source)
                #expect(controller.surfaceTree.root?.leaves().count == 2)
                let direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
                switch destination {
                case .splitRight: direction = .right
                case .splitDown: direction = .down
                case .splitLeft: direction = .left
                case .splitUp: direction = .up
                default: preconditionFailure("Expected a split destination")
                }
                #expect(controller.surfaceTree.focusTarget(
                    for: .spatial(direction), from: .leaf(view: source)
                ) === target.surface)
            }
            // New tabs schedule their initial presentation on the next run loop.
            // Let it finish before closing, so the test cannot reopen a closed window later.
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}
