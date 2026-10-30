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

    @Test(arguments: [FullscreenMode.native, .nonNative])
    func restoredWorkspaceSwitchesUsingKeyboardInFullscreen(mode: FullscreenMode) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = TerminalWorkspaceStore(fileURL: nil)
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        let coordinator = TerminalWorkspaceCoordinator(store: store, sessions: sessions)
        coordinator.finishRestoring()
        let other = try #require(store.create(name: "Restored destination", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        first.window?.makeKeyAndOrderFront(nil)
        sessions.start(app)
        let second = try #require(coordinator.switchWorkspace(to: other, from: first))
        _ = try #require(TerminalController.newTab(app, from: second.window!, withBaseConfig: config))
        try await Task.sleep(for: .milliseconds(100))
        second.window?.makeKeyAndOrderFront(nil)
        coordinator.didActivate(second)
        try #require(coordinator.switchWorkspace(to: store.defaultID, from: second) === first)
        store.transaction { state in
            state.windows?[first.windowSessionID]?.fullscreen = mode != .native
            state.windows?[first.windowSessionID]?.fullscreenMode = mode == .native ? nil : mode
        }
        sessions.capture()
        sessions.flush()
        coordinator.prepareToQuit()
        for controller in coordinator.liveControllers { controller.window?.close() }
        let restoredStore = TerminalWorkspaceStore(fileURL: nil)
        let restoredSessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: restoredStore)
        let restored = TerminalWorkspaceCoordinator(store: restoredStore, sessions: restoredSessions)
        restoredSessions.prepare()
        restoredSessions.start(app)
        restored.finishRestoring()
        defer { for controller in restored.liveControllers { controller.window?.close() } }
        let source = try #require(restored.controllers(in: restoredStore.defaultID).first)
        let target = try #require(restored.controllers(in: other).first)
        let window = try #require(source.window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow)
        var entered = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { entered = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        if mode == .native {
            let fullscreenKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            NSApp.sendEvent(fullscreenKey)
        } else if source.fullscreenStyle?.isFullscreen != true { source.toggleFullscreen(mode: mode) }
        for _ in 0..<200 {
            if mode == .native ? (entered || (source.fullscreenStyle?.isFullscreen == true && restored.native.transitioningWindows.isEmpty)) : source.fullscreenStyle?.isFullscreen == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(source.fullscreenStyle?.isFullscreen == true && restored.native.transitioningWindows.isEmpty,
            "The fullscreen shortcut must complete before workspace switching is exercised")
        try await Task.sleep(for: .milliseconds(100))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        NSApp.sendEvent(key)
        try await Task.sleep(for: .milliseconds(300))
        #expect(restoredStore.snapshot.windows?[source.windowSessionID]?.currentWorkspace == other)
        #expect(target.window?.isKeyWindow == true)
        #expect(target.fullscreenStyle?.isFullscreen == true)
        #expect(source.window?.isVisible == false)
        #expect(target.window?.tabGroup?.selectedWindow === target.window || mode != .native)
        #expect(target.tabLayoutState.sidebarHost.liveView?.window === target.window)
        for index in 0..<8 {
            let current = index.isMultiple(of: 2) ? target : source
            let digit = index.isMultiple(of: 2) ? "1" : "2"
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: current.window!.windowNumber, context: nil,
                characters: digit, charactersIgnoringModifiers: digit, isARepeat: false, keyCode: digit == "1" ? 18 : 19))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(150))
            let expected = index.isMultiple(of: 2) ? source : target
            #expect(expected.window?.isKeyWindow == true)
            #expect(expected.fullscreenStyle?.isFullscreen == true)
        }
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
