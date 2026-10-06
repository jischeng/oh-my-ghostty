import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalLinkHoverTests {
    private func makeController(split: Bool, command: String = "/bin/sleep 30") throws -> TerminalController {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = "/tmp"
        let controller = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: .vertical)
        if split {
            let surface = try #require(controller.focusedSurface)
            _ = try #require(controller.newSplit(at: surface, direction: .right, baseConfig: config))
        }
        controller.showWindow(nil)
        return controller
    }

    @Test(arguments: [false, true])
    func trackingAreasSurviveHoverAndGeometryUpdates(split: Bool) async throws {
        let controller = try makeController(split: split)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        try await Task.sleep(for: .milliseconds(100))
        surface.updateTrackingAreas()
        let areas = surface.trackingAreas
        #expect(areas.contains { $0.options.contains([.cursorUpdate, .inVisibleRect, .activeInKeyWindow]) })
        #expect(areas.contains { $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways]) })
        for shape in [GHOSTTY_MOUSE_SHAPE_POINTER, GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_POINTER] {
            surface.setCursorShape(shape)
            surface.hoverUrl = shape == GHOSTTY_MOUSE_SHAPE_POINTER ? "https://example.com" : nil
            surface.updateTrackingAreas()
            #expect(surface.trackingAreas == areas, "Hover must not replace tracking areas and synthesize mouse exits")
        }
        surface.setFrameSize(CGSize(width: surface.frame.width + 10, height: surface.frame.height + 10))
        surface.updateTrackingAreas()
        #expect(surface.trackingAreas == areas, "inVisibleRect already follows geometry changes")
    }

    @Test func cursorUpdateUsesCurrentCoreShape() throws {
        let controller = try makeController(split: false)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: surface.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        for shape in [GHOSTTY_MOUSE_SHAPE_POINTER, GHOSTTY_MOUSE_SHAPE_TEXT] {
            surface.setCursorShape(shape)
            NSCursor.arrow.set() // Simulate an ancestor/hosting view resetting the cursor.
            surface.cursorUpdate(with: event)
            #expect(NSCursor.current == surface.pointerStyle.cursor)
        }
    }

    @Test(arguments: [false, true])
    func linkHoverKeepsSurfaceAsHitTarget(split: Bool) async throws {
        let controller = try makeController(split: split)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        let content = try #require(controller.window?.contentView)
        try await Task.sleep(for: .milliseconds(100))
        for url in [nil, "https://example.com", nil] as [String?] {
            surface.hoverUrl = url
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            for fraction in [0.25, 0.5, 0.75] {
                let point = NSPoint(x: surface.bounds.midX, y: surface.bounds.height * fraction)
                #expect(content.hitTest(surface.convert(point, to: content)) === surface,
                    "Hover banner must not intercept terminal mouse events")
            }
        }
    }

    @Test(.tags(.interactiveDesktop))
    func commandHoverRemainsStable() async throws {
        for split in [false, true] {
            try await checkCommandHover(split: split)
        }
    }

    private func checkCommandHover(split: Bool) async throws {
        let controller = try makeController(split: split,
            command: "/bin/sh -c 'printf \"https://example.com\\n\"; sleep 30'")
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        for _ in 0..<20 {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            if NSApp.isActive && window.isKeyWindow { break }
        }
        try #require(NSApp.isActive && window.isKeyWindow,
            "Desktop hover test needs an unlocked desktop and the test window in foreground")
        let surface = try #require(controller.focusedSurface)
        let point = window.convertPoint(toScreen: surface.convert(NSPoint(x: 30, y: surface.bounds.height - 10), to: nil))
        let screenHeight = try #require(NSScreen.screens.first).frame.height
        let original = NSEvent.mouseLocation
        defer {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: original.x, y: screenHeight - original.y),
                mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        for _ in 0..<20 {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x, y: screenHeight - point.y), mouseButton: .left))
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(50))
            #expect(surface.pointerStyle == .link)
            #expect(surface.mouseOverSurface)
        }
    }
}
