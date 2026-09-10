import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct VerticalTabMouseTests {
    @Test func mouseSelectionKeepsWorkingAcrossNativeWindows() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let settings = OhMyGhosttySettings.shared
        let previousGrouping = settings.groupingMode
        let previousOrdering = settings.orderingMode
        defer { settings.groupingMode = previousGrouping; settings.orderingMode = previousOrdering }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        config.workingDirectory = "/tmp"
        let first = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: .vertical)
        var controllers = [first]
        let firstWindow = try #require(first.window)
        first.titleOverride = "mouse-tab-0"
        first.showWindow(nil)
        for index in 1..<3 {
            let next = try #require(TerminalController.newTab(app.ghostty, from: firstWindow, withBaseConfig: config))
            next.titleOverride = "mouse-tab-\(index)"
            controllers.append(next)
        }
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        first.setTabGroupingMode(.none); first.setTabOrderingMode(.manual); first.setSidebarVisible(true)
        first.selectVerticalTab(first)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(250))
        let group = try #require(firstWindow.tabGroup)
        func sidebarScroll(in window: NSWindow) -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    if frame.minX < 40 && frame.width < 400 && frame.height > 100 { return scroll }
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }
        for step in 0..<18 {
            let target = controllers[step % 3]
            let sourceWindow = try #require(group.selectedWindow)
            let scroll = try #require(sidebarScroll(in: sourceWindow))
            let document = try #require(scroll.documentView)
            let height = OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            let targetIndex = try #require(group.windows.firstIndex { $0 === target.window })
            let rowY = 2 + CGFloat(targetIndex) * (height + 2) + height / 2
            let point = document.convert(.init(x: 70, y: document.isFlipped ? rowY : document.bounds.height - rowY), to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: step * 2, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: step * 2 + 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            sourceWindow.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { sourceWindow.sendEvent(queued) }
            try await Task.sleep(for: .milliseconds(35))
            #expect(group.selectedWindow === target.window, "Mouse click \(step) must select its target window")
        }
        // A row action may outlive a native group change. Its target still
        // identifies a live window even after the source cache drops it.
        let moved = controllers[2]
        let movedWindow = try #require(moved.window)
        group.removeWindow(movedWindow)
        movedWindow.makeKeyAndOrderFront(nil)
        firstWindow.makeKeyAndOrderFront(nil)
        first.selectVerticalTab(first)
        #expect(!first.tabControllers.contains { $0 === moved })
        first.selectVerticalTab(moved)
        #expect(movedWindow.isKeyWindow)
    }
}
