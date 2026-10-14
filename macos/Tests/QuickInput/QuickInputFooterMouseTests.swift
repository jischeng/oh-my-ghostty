import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
@Suite(.tags(.interactiveDesktop))
struct QuickInputFooterMouseTests {
    @Test func historyIconAndPaddingAllActivateOneButton() async throws {
        var activations = 0
        let host = NSHostingView(rootView: QuickInputHistoryButton(title: "历史") {
            activations += 1
        }.fixedSize())
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        // Activation is asynchronous; allow a bounded foreground handoff, but
        // never treat a background/locked session as a successful click test.
        for _ in 0..<10 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(NSApp.isActive && window.isKeyWindow,
                     "Requires an unlocked foreground desktop and key test window")
        host.layoutSubtreeIfNeeded()
        let locations: [CGFloat] = [1, 6, host.bounds.midX, host.bounds.width - 6, host.bounds.width - 1]
        for (index, x) in locations.enumerated() {
            let point = host.convert(NSPoint(x: x, y: host.bounds.midY), to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: index * 2,
                clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: index * 2 + 1,
                clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
            try await Task.sleep(for: .milliseconds(30))
            #expect(activations == index + 1, "Click at x=\(x) must activate the entire History action")
        }
    }
}
