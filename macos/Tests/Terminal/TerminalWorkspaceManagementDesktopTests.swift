import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.tags(.interactiveDesktop), .serialized) @MainActor
struct TerminalWorkspaceManagementDesktopTests {
    @Test(arguments: [FullscreenMode.native, .nonNative])
    func createWorkspaceFromFullscreenPopover(mode: FullscreenMode) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let source = TerminalController(app, withBaseConfig: config, tabLayout: .vertical, workspaceCoordinator: coordinator)
        let window = try #require(source.window)
        defer { for controller in coordinator.liveControllers { controller.window?.close() } }
        source.showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires unlocked foreground desktop")
        var entered = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { entered = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        source.toggleFullscreen(mode: mode)
        for _ in 0..<200 {
            if mode == .native ? entered : source.fullscreenStyle?.isFullscreen == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(source.fullscreenStyle?.isFullscreen == true)
        try await Task.sleep(for: .milliseconds(100))
        source.workspaceSwitcherIsPresented = true
        try #require(source.workspacePopover.isShown)
        let content = try #require(source.workspacePopover.contentView)
        try await Task.sleep(for: .milliseconds(100))
        try click(content, at: NSPoint(x: content.bounds.width - 35, y: 21))
        try await Task.sleep(for: .milliseconds(100))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(fields(content).first { $0.isEditable })
        content.window?.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Fullscreen created via popover", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        try click(content, at: NSPoint(x: content.bounds.width - 55, y: content.bounds.height - 28))
        try await Task.sleep(for: .milliseconds(500))
        let created = try #require(store.workspaces.first { $0.name == "Fullscreen created via popover" })
        let target = try #require(coordinator.controllers(in: created.id).first,
            "Created label must have a presented terminal; transition=\(coordinator.native.transitioningWindows), error=\(coordinator.operationError ?? "none")")
        #expect(!source.workspacePopover.isShown)
        #expect(target.window?.isKeyWindow == true)
        #expect(target.fullscreenStyle?.isFullscreen == true)
        #expect(target.windowSessionID == source.windowSessionID)
        #expect(store.snapshot.windows?[source.windowSessionID]?.currentWorkspace == created.id)
        target.toggleFullscreen(mode: mode)
        try await Task.sleep(for: .seconds(2))
    }

    private func click(_ view: NSView, at point: NSPoint) throws {
        let window = try #require(view.window)
        let location = view.convert(point, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let event = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
}
