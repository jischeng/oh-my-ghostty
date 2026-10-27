import AppKit
import IOSurface
import Testing
@testable import Ghostty

/// Requires a real fullscreen Space and the test application in the foreground.
@Suite(.tags(.interactiveDesktop))
@MainActor
struct VerticalTabFullscreenTests {
    @Test(arguments: [Ghostty.Config.MacOSTabLayout.vertical, .horizontal])
    func newTabsInNativeFullscreen(layout: Ghostty.Config.MacOSTabLayout) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: layout)
        var controllers = [first]
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let window = try #require(first.window)
        first.showWindow(nil)
        first.setSidebarVisible(true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: "/tmp/omg-fullscreen-test.pid", atomically: true, encoding: .utf8
        )
        for _ in 0..<200 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires foreground test app")
        window.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
        try #require(window.styleMask.contains(.fullScreen))
        let fullscreenFrame = window.frame
        let contentSize = try #require(window.contentView?.bounds.size)

        for _ in 0..<3 {
            let parent = try #require(controllers.last?.window)
            let next = try #require(TerminalController.newTab(app.ghostty, from: parent, withBaseConfig: config))
            controllers.append(next)
            let incoming = try #require(next.window)
            let animation = incoming.animationBehavior
            // Exercise the presentation boundary synchronously: inspecting only
            // a later run-loop turn would miss a default-color/undersized frame.
            let shown = next.withNewTabPresentation(from: parent) {
                #expect(incoming.backgroundColor == parent.backgroundColor)
                #expect(incoming.animationBehavior == .none)
                #expect(CATransaction.disableActions())
                return next.showWindowSafely(nil)
            }
            #expect(shown)
            #expect(incoming.animationBehavior == animation)
            #expect(incoming.styleMask.contains(.fullScreen))
            // Horizontal tabs reserve the native tab strip on the first
            // insertion. Both members must agree on the resulting frame.
            #expect(incoming.frame == parent.frame)
            if layout == .vertical {
                #expect(incoming.frame == fullscreenFrame)
                #expect(incoming.contentView?.bounds.size == contentSize)
            }
            try expectPreparedFrame(next)
            if layout == .vertical {
                #expect(next.tabLayoutState.sidebarHost.liveView?.window === incoming)
                #expect((incoming as? VerticalTabsTerminalWindow)?.nativeTabBarIsSuppressed == true)
            }
            // Let the normal deferred newTab presentation run as well.
            try await Task.sleep(for: .milliseconds(100))
            #expect(incoming.tabGroup?.selectedWindow === incoming)
            #expect(incoming.frame == parent.frame)
        }

        let last = try #require(controllers.last)
        last.closeTabImmediately(registerRedo: false)
        try await Task.sleep(for: .milliseconds(100))
        let selected = try #require(window.tabGroup?.selectedWindow)
        #expect(selected.styleMask.contains(.fullScreen))
        if layout == .vertical { #expect(selected.frame == fullscreenFrame) }
        selected.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(2))
        #expect(!selected.styleMask.contains(.fullScreen))
        #expect(selected.contentLayoutRect.height < selected.frame.height)
    }

    private func expectPreparedFrame(_ controller: TerminalController) throws {
        let view = try #require(controller.surfaceTree.first)
        let layer = try #require(view.layer)
        let image = try #require(layer.contents as? IOSurface)
        #expect(image.width == Int((layer.bounds.width * layer.contentsScale).rounded(.down)))
        #expect(image.height == Int((layer.bounds.height * layer.contentsScale).rounded(.down)))
    }
}
