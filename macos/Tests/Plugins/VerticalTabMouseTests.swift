import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct VerticalTabMouseTests {
    private final class MonitorOwner { var received = 0 }
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
        first.selectVerticalTab(first)
        try await Task.sleep(for: .milliseconds(50))
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
        // Drive the actual SwiftUI source and native drag loop. A pasteboard
        // change proves these gestures reached onDrag rather than only clicks.
        func nativeDrag(toRow destination: Int) async throws {
            let dragWindow = try #require(group.selectedWindow)
            let document = try #require(sidebarScroll(in: dragWindow)?.documentView)
            let height = OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            let sourceIndex = try #require(group.windows.firstIndex { $0 === controllers[0].window })
            func point(row: Int, fraction: CGFloat) -> NSPoint {
                let y = 2 + CGFloat(row) * (height + 2) + height * fraction
                return document.convert(.init(x: 70, y: document.isFlipped ? y : document.bounds.height - y), to: nil)
            }
            let start = point(row: sourceIndex, fraction: 0.5)
            let finish = point(row: destination, fraction: 0.8)
            func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dragWindow.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            let pasteboard = NSPasteboard(name: .drag)
            let before = pasteboard.changeCount
            // CoreDrag starts in a run-loop observer. Move and release only
            // after it starts tracking, so the OS sees the entire gesture.
            var tick = 0
            let timer = Timer(timeInterval: 0.05, repeats: true) { firingTimer in
                MainActor.assumeIsolated {
                    tick += 1
                    if tick == 2 { firingTimer.invalidate() }
                    if tick == 1, let moved = try? event(.leftMouseDragged, at: finish) {
                        NSApp.postEvent(moved, atStart: false)
                    } else if let up = try? event(.leftMouseUp, at: finish) {
                        NSApp.postEvent(up, atStart: false)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            NSApp.postEvent(try event(.leftMouseDragged, at: .init(x: start.x + 18, y: start.y)), atStart: false)
            NSApp.sendEvent(try event(.leftMouseDown, at: start))
            while let queued = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(pasteboard.changeCount > before, "The native drag source must actually run")
        }
        let initialOrder = group.windows
        try await nativeDrag(toRow: 0)
        #expect(group.windows == initialOrder, "Dragging within the source row must keep tab order")
        // The header is outside all row drop destinations, so release there
        // must cancel without committing tab order. Escape is covered with
        // actual keyboard events in VerticalTabDragLifecycleTests.
        try await nativeDrag(toRow: -1)
        #expect(group.windows == initialOrder, "A rejected drop must preserve native tab order")
        try await nativeDrag(toRow: 2)
        #expect(group.windows == [initialOrder[1], initialOrder[2], initialOrder[0]], "A completed drag must commit native tab order")

        let dragLifecycle = VerticalTabDragLifecycleMonitor()
        defer { dragLifecycle.finish() }
        var dragCleanups = 0
        var owner: MonitorOwner? = MonitorOwner()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown,
            handler: WeakLocalEventMonitor.handler(for: owner!) { owner, event in owner.received += 1; return event })
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        for step in 0..<64 {
            if step == 28 {
                #expect((owner?.received ?? 0) > 0, "Exercise application-level event monitors")
                owner = nil
            }
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
            if step % 8 == 0 {
                // Start the production source monitor, then deliver a genuine
                // AppKit release before the next row click. A no-op/cancelled
                // drag has no performDrop to rescue this lifecycle.
                dragLifecycle.begin { dragCleanups += 1 }
                NSApp.sendEvent(up)
                try await Task.sleep(for: .milliseconds(10))
                #expect(dragCleanups == step / 8 + 1)
            }
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
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
