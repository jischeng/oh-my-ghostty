import AppKit
import Combine
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

    @Test func linkHoverShowsHintWithoutChangingCursor() throws {
        let controller = try makeController(split: false)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        var styles = 0
        var hovers = 0
        let styleToken = surface.$pointerStyle.dropFirst().sink { _ in styles += 1 }
        let hoverToken = surface.$isHoveringLink.dropFirst().sink { _ in hovers += 1 }
        defer { styleToken.cancel(); hoverToken.cancel() }
        for _ in 0..<10 { surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_POINTER) }
        #expect(styles == 0, "Links must not switch the cursor to a pointing hand")
        #expect(surface.pointerStyle == .horizontalText)
        #expect(surface.isHoveringLink)
        #expect(hovers == 1, "Moving across one link must not republish per cell")
        surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        #expect(!surface.isHoveringLink)
        #expect(hovers == 2)
        #expect(styles == 0)
    }

    @Test func linkHintStaysInsideSurface() {
        let container = CGSize(width: 400, height: 300)
        let chip = CGSize(width: 90, height: 20)
        // AppKit y=290 is near the top; the chip sits below-right of the cursor.
        let normal = SurfaceLinkHint.origin(for: CGPoint(x: 100, y: 290), chip: chip, container: container)
        #expect(normal == CGPoint(x: 114, y: 28))
        // Near the bottom-right corner it flips to the top-left of the cursor.
        let corner = SurfaceLinkHint.origin(for: CGPoint(x: 390, y: 5), chip: chip, container: container)
        #expect(corner.x + chip.width <= 390)
        #expect(corner.y + chip.height <= 295)
        #expect(corner.x >= SurfaceLinkHint.edgeInset && corner.y >= SurfaceLinkHint.edgeInset)
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
            #expect(surface.isHoveringLink)
            #expect(surface.pointerStyle != .link)
            #expect(surface.mouseOverSurface)
        }
    }
}
