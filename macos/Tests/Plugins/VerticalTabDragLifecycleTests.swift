import AppKit
import Testing
@testable import Ghostty

@MainActor
struct VerticalTabDragLifecycleTests {
    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }

    private func key(_ code: UInt16, in window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: code == 53 ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r", isARepeat: false, keyCode: code))
    }

    @Test func policyReadsOnlyFieldsValidForTheActualEvent() throws {
        // A hand-written keyCode argument hid the mouse-up exception in the
        // previous policy test. These must be real AppKit mouse events.
        #expect(VerticalTabDragLifecyclePolicy.shouldFinish(try mouse(.leftMouseUp)))
        #expect(VerticalTabDragLifecyclePolicy.shouldFinish(try mouse(.leftMouseDown)))
        #expect(!VerticalTabDragLifecyclePolicy.shouldFinish(try mouse(.mouseMoved)))
        #expect(!VerticalTabDragLifecyclePolicy.shouldFinish(try mouse(.leftMouseDragged)))
        #expect(VerticalTabDragLifecyclePolicy.shouldFinish(try key(53)))
        #expect(!VerticalTabDragLifecyclePolicy.shouldFinish(try key(36)))
    }

    @Test func applicationDispatchedReleaseCleansUpExactlyOnce() async throws {
        let monitor = VerticalTabDragLifecycleMonitor()
        var completed = 0
        defer { monitor.finish() }
        for _ in 0..<8 {
            monitor.begin { completed += 1 }
            let before = completed
            NSApp.sendEvent(try mouse(.leftMouseUp))
            #expect(completed == before, "Drop destinations must finish before source cleanup")
            try await Task.sleep(for: .milliseconds(10))
            #expect(completed == before + 1)
            monitor.finish()
            #expect(completed == before + 1)
        }
    }

    @Test func queuedReleaseCannotClearANewerDrag() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        defer { window.close() }
        let monitor = VerticalTabDragLifecycleMonitor()
        var completions: [Int] = []
        defer { monitor.finish() }
        monitor.begin { completions.append(1) }
        NSApp.sendEvent(try mouse(.leftMouseUp))
        monitor.begin { completions.append(2) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(completions == [1])
        NSApp.sendEvent(try key(36, in: window))
        try await Task.sleep(for: .milliseconds(10))
        #expect(completions == [1])
        NSApp.sendEvent(try key(53, in: window))
        try await Task.sleep(for: .milliseconds(10))
        #expect(completions == [1, 2])
    }

    @Test func nextPressRetiresStateWhenNativeDragConsumedRelease() async throws {
        let monitor = VerticalTabDragLifecycleMonitor()
        var completed = false
        defer { monitor.finish() }
        monitor.begin { completed = true }
        NSApp.sendEvent(try mouse(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(10))
        #expect(completed)
    }
}
