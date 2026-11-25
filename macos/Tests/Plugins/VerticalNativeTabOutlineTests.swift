import AppKit
import Testing
@testable import Ghostty

@MainActor
struct VerticalNativeTabOutlineTests {
    @Test func releaseDeliveredBeforeCoreDragStartsIsReplayedExactlyOnce() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let outline = NativeTabOutline()
        window.contentView = outline
        func event(_ type: NSEvent.EventType, time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .init(x: 60, y: 40), modifierFlags: [],
                timestamp: time, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, time: 10)
        let up = try event(.leftMouseUp, time: 11)
        outline.observeDragRelease(up)
        #expect(outline.takeEarlyDragRelease() == nil, "Unrelated clicks are never replayed")
        outline.beginMouseGesture(down)
        outline.observeDragRelease(try event(.leftMouseUp, time: 9))
        #expect(outline.takeEarlyDragRelease() == nil)
        outline.observeDragRelease(up)
        #expect(outline.takeEarlyDragRelease() === up)
        #expect(outline.takeEarlyDragRelease() == nil)
        outline.beginMouseGesture(down)
        outline.dragBegan()
        outline.observeDragRelease(up)
        #expect(outline.takeEarlyDragRelease() == nil, "Active CoreDrag owns normal releases")
        outline.dragEnded()
    }

    private final class DragInfo: NSObject, NSDraggingInfo {
        let source: NSOutlineView
        let draggingPasteboard = NSPasteboard.withUniqueName()
        var draggingDestinationWindow: NSWindow? { source.window }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { source }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        init(source: NSOutlineView, tab: UUID) {
            self.source = source
            super.init()
            draggingPasteboard.setString(tab.uuidString, forType: NativeTabOutlineController.tabType)
        }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    @Test func acceptedDropWaitsForNativeTrackingToFinishBeforeMovingWindows() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        _ = try fixture.tab(parent: first)
        _ = try fixture.tab(parent: first)
        let group = try #require(first.window?.tabGroup)
        let before = group.windows
        let source = try #require(before.last?.windowController as? TerminalController)
        let selected = group.selectedWindow
        let config = NativeTabOutlineConfiguration(
            groups: GhosttyTabOrganizationModel().groups(
                tabs: first.tabControllers, grouping: .none, ordering: .manual),
            selectedID: selected?.windowController.map(ObjectIdentifier.init),
            layoutState: first.tabLayoutState, controller: first, rowHeight: 32, presentation: { _ in nil })
        let controller = NativeTabOutlineController(config)
        _ = controller.view
        controller.update(config)
        let drag = DragInfo(source: controller.outline, tab: source.tabSessionID)
        defer { drag.draggingPasteboard.releaseGlobally() }
        controller.outline.dragBegan()
        #expect(controller.outlineView(controller.outline, acceptDrop: drag, item: nil, childIndex: 0))
        #expect(group.windows == before, "acceptDrop must return before mutating native windows")
        _ = RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.02))
        #expect(group.windows == before, "A nested tracking loop must not commit the drop")
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        #expect(group.windows == before, "Default-mode callbacks can run before the drag session has ended")
        controller.outline.dragEnded()
        for _ in 0..<40 where group.windows == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(group.windows == [try #require(before.last)] + before.dropLast())
        #expect(group.selectedWindow === selected)
    }

    @Test func nativeRowsAndCloseButtonsShareTheDeliveredHoverState() throws {
        final class Window: NSWindow {
            override var isKeyWindow: Bool { true }
            override var isVisible: Bool { true }
        }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        let config = NativeTabOutlineConfiguration(
            groups: GhosttyTabOrganizationModel().groups(tabs: [first, second], grouping: .none, ordering: .manual),
            selectedID: ObjectIdentifier(first), layoutState: first.tabLayoutState, controller: first, rowHeight: 32,
            presentation: { tab in
                .init(title: "Tab \(tab.actualIndex)", remoteBreadcrumb: nil, shortcut: "\(tab.actualIndex)",
                      icon: .systemSymbol("terminal"), activity: nil, selected: tab.controller === first, hovered: false)
            })
        let controller = NativeTabOutlineController(config)
        let window = Window(contentRect: .init(x: 0, y: 0, width: 320, height: 160),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.contentView = nil; window.close() }
        controller.update(config)
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outline
        outline.updateTrackingAreas()
        let owner = try #require(outline.trackingAreas.first { $0.owner is NativeTableHover }?.owner as? NativeTableHover)
        let rows = try (0..<2).map { try #require(outline.rowView(atRow: $0, makeIfNecessary: true) as? NativeTabRowView) }
        let buttons = try (0..<2).map { index in
            let cell = try #require(outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? NativeTabCell)
            #expect(cell.superview === rows[index])
            return cell.closeButton
        }
        let selection = outline.selectedRowIndexes
        for index in [1, 0, 1, 0] {
            let rect = outline.rect(ofRow: index)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: outline.convert(.init(x: 80, y: rect.midY), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: index, clickCount: 0, pressure: 0))
            #expect(NSApp.sendAction(#selector(NSResponder.mouseMoved(with:)), to: owner, from: event))
            for row in 0..<2 {
                #expect(rows[row].isHovered == (row == index))
                #expect(buttons[row].isHidden == (row != index))
                #expect(!buttons[row].showsHoverDisc)
            }
            #expect(outline.selectedRowIndexes == selection)
        }
        #expect(NSApp.sendAction(#selector(NSResponder.mouseExited(with:)), to: owner, from: NSEvent()))
        #expect(rows.allSatisfy { !$0.isHovered })
        #expect(buttons.allSatisfy { $0.isHidden })
    }

    @Test func hoverAndSelectionPillsShareExactGeometryAndVerticalCentering() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let nativeApp = try #require(delegate.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<5).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        // Make the last tab a split-pane tab to verify split multi-icon rows center identically.
        let splitLeft = try #require(controllers[4].surfaceTree.first)
        let splitRight = Ghostty.SurfaceView(nativeApp, baseConfig: config)
        controllers[4].surfaceTree = .init(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(view: splitLeft), right: .leaf(view: splitRight)
        )), zoomed: nil)

        let activities: [TabActivity?] = [
            nil,
            TabActivity(source: "codex", state: .working, label: nil, message: nil, detail: nil, progress: nil,
                        icon: .init(kind: .bundledAsset, name: "AgentOpenAILogo")),
            TabActivity(source: "codex", state: .idle, label: nil, message: nil, detail: nil, progress: nil,
                        icon: .init(kind: .bundledAsset, name: "AgentOpenAILogo")),
            TabActivity(source: "antigravity", state: .needsAttention, label: nil, message: nil, detail: nil, progress: nil,
                        icon: .init(kind: .bundledAsset, name: "AgentAntigravityLogo")),
            nil,
        ]
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let groups = GhosttyTabOrganizationModel().groups(tabs: controllers, grouping: .none, ordering: .manual)
        func makeConfig(rowHeight: CGFloat) -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: groups,
                selectedID: ObjectIdentifier(controllers[1]),
                layoutState: state,
                controller: controllers[0],
                rowHeight: rowHeight,
                presentation: { tab in
                    let idx = tab.actualIndex - 1
                    let activity = activities[idx]
                    let icon: GhosttyTabIcon = activity?.icon.map { .asset($0.name) } ?? .systemSymbol("terminal")
                    return .init(
                        title: "Session \(tab.actualIndex)",
                        remoteBreadcrumb: nil,
                        subtitle: "~/should/never/render/in/tabs",
                        shortcut: "⌘\(tab.actualIndex)",
                        icon: icon,
                        activity: activity,
                        selected: idx == 1,
                        hovered: false
                    )
                }
            )
        }

        let outlineController = NativeTabOutlineController(makeConfig(rowHeight: 36))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outlineController.view
        defer { window.contentView = nil; window.close() }

        for expectedHeight in [CGFloat(36), CGFloat(30)] {
            outlineController.update(makeConfig(rowHeight: expectedHeight))
            outlineController.view.layoutSubtreeIfNeeded()
            let outline = outlineController.outline
            #expect(NativeHoverRowView.highlightCornerRadius == 6)
            #expect(NativeHoverRowView.highlightInset == NSSize(width: 2, height: 1))
            #expect(NativeTabRowView.pillCornerRadius == 8)
            for index in 0..<controllers.count {
                let row = try #require(outline.rowView(atRow: index, makeIfNecessary: true) as? NativeTabRowView)
                let cell = try #require(outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? NativeTabCell)
                row.layoutSubtreeIfNeeded()
                cell.layoutSubtreeIfNeeded()
                #expect(row.cornerRadius == 8)
                #expect(outlineController.outlineView(outline, heightOfRowByItem: outlineController.roots[index]) == expectedHeight)
                #expect(row.bounds.height == expectedHeight + outline.intercellSpacing.height)
                #expect(row.highlightRect == row.bounds.insetBy(dx: 2, dy: 1))
                #expect(row.selectionRect == row.highlightRect)
                #expect(row.selectionRect.height == expectedHeight)
                let hoverLayer = try #require(row.layer?.sublayers?.first { $0.name == "omg.row.hover" } as? CAShapeLayer)
                #expect(hoverLayer.path?.boundingBoxOfPath == row.selectionRect)
                #expect(abs(cell.rowStack.frame.midY - cell.bounds.midY) <= 0.5)
                #expect(cell.icon.frame.size == NSSize(width: 18, height: 18))
                let iconInRow = row.convert(cell.icon.bounds, from: cell.icon)
                #expect(abs((iconInRow.minX - row.selectionRect.minX) - 10) <= 0.5)
                let expectedWeight: NSFont.Weight = index == 1 ? .medium : .regular
                #expect(cell.label.font == .systemFont(ofSize: 13, weight: expectedWeight))
                if index == 3 {
                    // Unhovered attention row shows 14×14 status badge in the single trailing slot, inset ~10pt from right pill edge.
                    #expect(cell.trailingAccessory == .status)
                    #expect(!cell.status.isHidden)
                    #expect(cell.shortcut.isHidden)
                    #expect(cell.closeButton.isHidden)
                    let slotInRow = row.convert(cell.trailingSlot.bounds, from: cell.trailingSlot)
                    #expect(abs((row.selectionRect.maxX - slotInRow.maxX) - 10) <= 0.5)
                } else {
                    // Unhovered rows without a status badge collapse the trailing slot so titles extend to 10pt inside the pill.
                    #expect(cell.trailingAccessory == .none)
                    #expect(cell.trailingSlot.isHidden)
                    let labelInRow = cell.rowStack.convert(
                        cell.label.alignmentRect(forFrame: cell.label.frame),
                        to: row
                    )
                    #expect(abs((row.selectionRect.maxX - labelInRow.maxX) - 10) <= 0.5)
                }
            }
        }
    }

    @Test func singleTrailingSlotPriorityAndCommandHoldRevealInNormalTabs() throws {
        final class KeyOutlineWindow: NSWindow {
            var keyState = true
            override var isKeyWindow: Bool { keyState }
            override var isVisible: Bool { true }
        }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        let third = try fixture.tab(parent: first)
        let tabs = [first, second, third]
        let attention = TabActivity(
            source: "claude", state: .needsAttention, attentionKind: .question,
            label: nil, message: nil, detail: nil, progress: nil,
            icon: .init(kind: .bundledAsset, name: "AgentClaudeLogo")
        )
        let completed = TabActivity(
            source: "codex", state: .done, label: nil, message: nil,
            detail: nil, progress: nil,
            icon: .init(kind: .bundledAsset, name: "AgentOpenAILogo")
        )
        var showShortcuts = true
        func makeConfig() -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: GhosttyTabOrganizationModel().groups(tabs: tabs, grouping: .none, ordering: .manual),
                selectedID: ObjectIdentifier(first),
                layoutState: first.tabLayoutState,
                controller: first,
                rowHeight: OhMyGhosttyTabRowDensity.comfortable.rowHeight,
                presentation: { tab in
                    let activity: TabActivity? = switch tab.actualIndex {
                    case 1: nil
                    case 2: attention
                    default: completed
                    }
                    return .init(
                        title: "Tab \(tab.actualIndex)",
                        remoteBreadcrumb: nil,
                        shortcut: showShortcuts ? "⌘\(tab.actualIndex)" : nil,
                        icon: .systemSymbol("terminal"),
                        activity: activity,
                        selected: tab.actualIndex == 1,
                        hovered: false
                    )
                }
            )
        }

        let controller = NativeTabOutlineController(makeConfig())
        let window = KeyOutlineWindow(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.contentView = nil; window.close() }

        controller.update(makeConfig())
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outline
        let rows = try (0..<3).map {
            try #require(outline.rowView(atRow: $0, makeIfNecessary: true) as? NativeTabRowView)
        }
        let cells = try (0..<3).map {
            try #require(outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NativeTabCell)
        }
        let baselineReloads = controller.reloadCount

        func flagsEvent(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 55
            ))
        }

        // 1. Default resting state: NO shortcuts shown; idle collapses (.none); attention/done show status badge (.status).
        #expect(!controller.isCommandHeld)
        #expect(cells[0].trailingAccessory == .none)
        #expect(cells[0].trailingSlot.isHidden)
        #expect(cells[0].shortcut.isHidden && cells[0].status.isHidden && cells[0].closeButton.isHidden)
        #expect(cells[1].trailingAccessory == .status)
        #expect(!cells[1].status.isHidden && cells[1].shortcut.isHidden && cells[1].closeButton.isHidden)
        #expect(cells[2].trailingAccessory == .status)
        #expect(!cells[2].status.isHidden && cells[2].shortcut.isHidden && cells[2].closeButton.isHidden)

        // 2. Holding ⌘ (and ⌘⇧) reveals ⌘1..3 in-place without reloadData(), overriding status on unhovered rows.
        controller.commandMonitor.handleFlagsChanged(try flagsEvent([.command]))
        #expect(controller.isCommandHeld)
        #expect(controller.reloadCount == baselineReloads)
        for cell in cells {
            cell.layoutSubtreeIfNeeded()
            #expect(cell.trailingAccessory == .shortcut)
            #expect(!cell.shortcut.isHidden)
            #expect(cell.status.isHidden)
            #expect(cell.closeButton.isHidden)
        }
        controller.commandMonitor.handleFlagsChanged(try flagsEvent([.command, .shift]))
        #expect(controller.isCommandHeld)
        #expect(cells.allSatisfy { $0.trailingAccessory == .shortcut })

        // 3. Hovering row 1 while ⌘ is held shows ONLY ✕ on row 1 (.close > .shortcut > .status),
        //    while unhovered rows 0 & 2 continue showing ⌘1 / ⌘3.
        rows[1].isHovered = true
        cells[1].layoutSubtreeIfNeeded()
        #expect(cells[1].trailingAccessory == .close)
        #expect(!cells[1].closeButton.isHidden)
        #expect(!cells[1].closeButton.showsHoverDisc)
        #expect(cells[1].shortcut.isHidden)
        #expect(cells[1].status.isHidden)
        cells[1].closeButton.isHovered = true
        #expect(cells[1].closeButton.showsHoverDisc)
        cells[1].closeButton.isHovered = false
        #expect(cells[0].trailingAccessory == .shortcut)
        #expect(cells[2].trailingAccessory == .shortcut)
        rows[1].isHovered = false
        #expect(cells[1].trailingAccessory == .shortcut)

        // 4. Adding Control or Option suppresses ⌘1..9 reveal.
        controller.commandMonitor.handleFlagsChanged(try flagsEvent([.command, .option]))
        #expect(!controller.isCommandHeld)
        #expect(cells[0].trailingAccessory == .none)
        #expect(cells[1].trailingAccessory == .status)
        #expect(cells[2].trailingAccessory == .status)

        // 5. Window resignKey and app resignActive immediately clear ⌘-hold so Command-Tab never sticks ON.
        controller.commandMonitor.handleFlagsChanged(try flagsEvent([.command]))
        #expect(controller.isCommandHeld)
        window.keyState = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!controller.isCommandHeld)
        #expect(cells[1].trailingAccessory == .status)

        window.keyState = true
        controller.commandMonitor.handleFlagsChanged(try flagsEvent([.command]))
        #expect(controller.isCommandHeld)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!controller.isCommandHeld)

        // 6. Disabling showShortcutLabels keeps shortcuts nil, so ⌘-hold leaves status/.none intact.
        showShortcuts = false
        controller.update(makeConfig())
        controller.isCommandModifierHeldOverride = true
        defer { controller.isCommandModifierHeldOverride = nil }
        #expect(cells[0].trailingAccessory == .none)
        #expect(cells[1].trailingAccessory == .status)
        #expect(cells[2].trailingAccessory == .status)
    }

    private func descendantLabel(_ view: NSView, matching value: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == value { return field }
        for child in view.subviews {
            if let field = descendantLabel(child, matching: value) { return field }
        }
        return nil
    }

    @Test func dropResolvesNativeIndexesInsteadOfShortcutNumbers() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<4).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        let windows = controllers.compactMap(\.window)
        defer { for window in windows { window.delegate = nil; window.close() } }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let nativeGroup = try #require(windows[0].tabGroup)
        let ordered = nativeGroup.windows.compactMap { $0.windowController as? TerminalController }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let model = GhosttyTabOrganizationModel()
        var groups = model.groups(tabs: ordered, grouping: .none, ordering: .manual)
        func makeView() -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(groups: groups, selectedID: ObjectIdentifier(ordered[0]),
                                 layoutState: state, controller: ordered[0], rowHeight: 32,
                                 presentation: { _ in nil })
        }
        let coordinator = NativeTabOutlineController(makeView())
        let column = NSTableColumn(identifier: .init("tab"))
        coordinator.outline.addTableColumn(column)
        coordinator.outline.outlineTableColumn = column
        coordinator.outline.dataSource = coordinator
        coordinator.outline.delegate = coordinator
        coordinator.update(makeView())
        #expect(groups[0].tabs.map(\.actualIndex) == [1, 2, 3, 4])
        for source in ordered {
            for insertion in 0...ordered.count {
                let result = try #require(coordinator.resolveDrop(
                    sourceID: source.tabSessionID, item: nil, index: insertion
                ))
                #expect(result.0 === source)
                #expect(result.1 == insertion)
            }
        }
        // A group-end insertion belongs before the next group's first tab.
        groups = [
            .init(id: "first", title: "First", icon: nil, tabs: Array(groups[0].tabs.prefix(2))),
            .init(id: "second", title: "Second", icon: nil, tabs: Array(groups[0].tabs.suffix(2)))
        ]
        coordinator.update(makeView())
        let first = try #require(coordinator.nodes["group:first"])
        let second = try #require(coordinator.nodes["group:second"])
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: 2)?.1 == 2)
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: second, index: 0) == nil)
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: -1) == nil)
        // A native reorder can precede publication of the next presentation.
        nativeGroup.removeWindow(try #require(ordered[1].window))
        nativeGroup.insertWindow(try #require(ordered[1].window), at: 0)
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: 1)?.1 == 0)
        nativeGroup.removeWindow(try #require(ordered[1].window))
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: 1) == nil)
    }

    @Test func tabDevelopmentProfileIsIsolated() {
        guard Bundle.main.bundleIdentifier == "com.jischeng.omg.debug.tab" else { return }
        #expect(OMGApplicationEnvironment.isDevelopment)
        #expect(OMGApplicationEnvironment.channel() == "debug-tab")
        #expect(OMGApplicationEnvironment.settingsFileURL().path.contains("oh-my-ghostty-dev-tab"))
        #expect(OMGApplicationEnvironment.applicationSupportURL().lastPathComponent == "OMG Dev Tab")
    }

    @Test func nativeCellRefreshesFocusAndDetachesWhenReconfigured() async throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let nativeApp = try #require(delegate.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let first = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let second = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let firstSurface = try #require(first.surfaceTree.first)
        let secondSurface = Ghostty.SurfaceView(nativeApp, baseConfig: config)
        first.surfaceTree = .init(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(view: firstSurface), right: .leaf(view: secondSurface)
        )), zoomed: nil)
        first.focusedSurface = firstSurface
        defer {
            for controller in [first, second] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }

        // An untitled surface names itself after 0.5 s. Title every surface now
        // so that timer cannot fire inside a counted refresh window below.
        for surface in [firstSurface, secondSurface] + Array(second.surfaceTree) { surface.setTitle("Titled") }
        try await Task.sleep(for: .milliseconds(100))

        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let tabs = [GhosttyOrganizedTab(controller: first, actualIndex: 1)]
        var presentationCalls = 0
        func view() -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: [.init(id: "test", title: nil, icon: nil, tabs: tabs)],
                selectedID: ObjectIdentifier(first), layoutState: state, controller: first,
                rowHeight: 32,
                presentation: { tab in
                    presentationCalls += 1
                    let title: String
                    if let override = tab.controller.titleOverride {
                        title = override
                    } else if tab.controller === first {
                        title = tab.controller.focusedSurface === secondSurface ? "Focused secondary" : "Focused primary"
                    } else {
                        title = "Second controller"
                    }
                    return .init(
                        title: title, remoteBreadcrumb: nil, shortcut: nil,
                        icon: .systemSymbol("terminal"), activity: nil,
                        selected: false, hovered: false
                    )
                }
            )
        }

        let coordinator = NativeTabOutlineController(view())
        let outline = coordinator.outline
        let column = NSTableColumn(identifier: .init("tab"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.setFrameSize(NSSize(width: 320, height: 80))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update(view())
        outline.reloadData()
        let firstCell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeTabCell)
        #expect(firstCell.toolTip == "Focused primary")
        #expect(descendantLabel(firstCell, matching: "Focused primary")?.stringValue == "Focused primary")

        // A controller-only title change must refresh this cell without an
        // NSViewRepresentable/coordinator update.
        first.titleOverride = "Background override"
        try await Task.sleep(for: .milliseconds(20))
        #expect(firstCell.toolTip == "Background override")
        #expect(descendantLabel(firstCell, matching: "Background override")?.stringValue == "Background override")

        first.titleOverride = nil
        first.focusedSurface = secondSurface
        try await Task.sleep(for: .milliseconds(20))
        #expect(firstCell.toolTip == "Focused secondary")

        // Settle the initial tree publisher and any coalesced refresh before
        // testing that the same cell detaches from its previous controller.
        try await Task.sleep(for: .milliseconds(20))
        let secondTab = GhosttyOrganizedTab(controller: second, actualIndex: 1)
        firstCell.configure(
            tab: secondTab, title: nil, presentation: view().presentation,
            canClose: true, selected: false, select: {}, close: {}
        )
        #expect(firstCell.toolTip == "Second controller")
        try await Task.sleep(for: .milliseconds(20))
        let callsAfterReplacement = presentationCalls

        first.titleOverride = "Old controller emission"
        NotificationCenter.default.post(name: Notification.Name("GhosttyTabPresentationDidChange"), object: first)
        try await Task.sleep(for: .milliseconds(20))
        #expect(presentationCalls == callsAfterReplacement)
        #expect(firstCell.toolTip == "Second controller")

        second.titleOverride = "New controller emission"
        try await Task.sleep(for: .milliseconds(20))
        #expect(presentationCalls >= callsAfterReplacement + 1)
        #expect(firstCell.toolTip == "New controller emission")
    }

    @Test func measureRepeatedNativeTabCreationAndClose() async throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let first = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        var controllers = [first]
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        first.showWindow(nil)
        var createTimes: [Double] = []
        var closeTimes: [Double] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            let next = try #require(TerminalController.newTab(delegate.ghostty, from: controllers.last?.window, withBaseConfig: config))
            createTimes.append(ProcessInfo.processInfo.systemUptime - start)
            controllers.append(next)
            try await Task.sleep(for: .milliseconds(30))
        }
        for controller in controllers.dropFirst().reversed() {
            let start = ProcessInfo.processInfo.systemUptime
            controller.closeTabImmediately(registerRedo: false)
            closeTimes.append(ProcessInfo.processInfo.systemUptime - start)
            try await Task.sleep(for: .milliseconds(30))
        }
        print("TAB_SYNC_COST create_ms=\(createTimes.map { Int($0 * 1000) }) close_ms=\(closeTimes.map { Int($0 * 1000) })")
    }

    @Test func everySingleMoveIsRecognized() throws {
        let original = ["a", "b", "c", "d", "e"]
        for source in original.indices {
            for destination in original.indices where source != destination {
                var expected = original
                expected.insert(expected.remove(at: source), at: destination)
                let (from, to) = try #require(NativeTabOutlineController.singleMove(from: original, to: expected))
                var actual = original
                actual.insert(actual.remove(at: from), at: to)
                #expect(actual == expected)
            }
        }
    }

    @Test func nativeWindowReorderPreservesSelectionAndSurfaces() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<5).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        let windows = controllers.compactMap(\.window)
        let surfaces = controllers.map { $0.surfaceTree.first?.id }
        defer { for window in windows { window.delegate = nil; window.close() } }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let original = group.windows
        let selected = original[2]
        group.selectedWindow = selected
        for destination in [4, 0, 3, 1] {
            let moved = original[0]
            let source = try #require(group.windows.firstIndex(of: moved))
            let controller = try #require(moved.windowController as? TerminalController)
            #expect(controllers[0].reorderTab(controller, toInsertionIndex: destination + (source < destination ? 1 : 0)))
            #expect(group.windows[destination] === moved)
            #expect(group.selectedWindow === selected)
            #expect(Set(group.windows.map(ObjectIdentifier.init)) == Set(original.map(ObjectIdentifier.init)))
            #expect(controllers.map { $0.surfaceTree.first?.id } == surfaces)
        }
    }

    @Test func selectionUpdatesKeepNativeRowIdentityWithoutReloading() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<3).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let tabs = controllers.enumerated().map { GhosttyOrganizedTab(controller: $0.element, actualIndex: $0.offset + 1) }
        var groups = [GhosttyTabGroupPresentation(id: "test", title: "Project", icon: nil, tabs: tabs)]
        func view(selected: Int) -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: groups, selectedID: ObjectIdentifier(controllers[selected]),
                layoutState: state, controller: controllers[0], rowHeight: 32,
                presentation: { _ in nil }
            )
        }
        let coordinator = NativeTabOutlineController(view(selected: 0))
        let outline = coordinator.outline
        let column = NSTableColumn(identifier: .init("tab"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update(view(selected: 0))
        let originalNode = try #require(outline.item(atRow: 2) as? NativeTabNode)
        #expect(outline.numberOfRows == 4)
        #expect(outline.selectedRow == 1)
        coordinator.update(view(selected: 1))
        #expect(outline.selectedRow == 2)
        #expect(coordinator.reloadCount == 1)
        #expect(outline.item(atRow: 2) as? NativeTabNode === originalNode)
        for index in 0..<20 { coordinator.update(view(selected: index % 3)) }
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.outlineView(outline, shouldSelectItem: coordinator.roots[0]) == false)
        groups[0].tabs = [tabs[1], tabs[2], tabs[0]]
        coordinator.update(view(selected: 1))
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.moveCount == 1)
        #expect(outline.item(atRow: 1) as? NativeTabNode === originalNode)
        #expect(outline.selectedRow == 1)
        groups[0].tabs = tabs
        coordinator.update(view(selected: 1))
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.moveCount == 2)
        #expect(outline.item(atRow: 2) as? NativeTabNode === originalNode)
        #expect(outline.selectedRow == 2)
        for _ in 0..<12 {
            groups[0].tabs = [tabs[1], tabs[2]]
            coordinator.update(view(selected: 1))
            #expect(outline.numberOfRows == 3)
            #expect(outline.item(atRow: 1) as? NativeTabNode === originalNode)
            groups[0].tabs = tabs
            coordinator.update(view(selected: 1))
            #expect(outline.numberOfRows == 4)
            #expect(outline.item(atRow: 2) as? NativeTabNode === originalNode)
        }
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.membershipUpdateCount == 24)
    }

    @Test func withinParentTabReordersAnimateViaMoveItemWithoutReloadingData() throws {
        final class VisibleOutlineWindow: NSWindow {
            override var isVisible: Bool { true }
        }

        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<4).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let tabs = controllers.enumerated().map {
            GhosttyOrganizedTab(controller: $0.element, actualIndex: $0.offset + 1)
        }
        var groups = [GhosttyTabGroupPresentation(id: "flat", title: nil, icon: nil, tabs: tabs)]
        func makeConfig() -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: groups,
                selectedID: ObjectIdentifier(controllers[0]),
                layoutState: state,
                controller: controllers[0],
                rowHeight: 32,
                presentation: { tab in
                    .init(
                        title: "Tab \(tab.actualIndex)",
                        remoteBreadcrumb: nil,
                        shortcut: "⌘\(tab.actualIndex)",
                        icon: .systemSymbol("terminal"),
                        activity: nil,
                        selected: tab.actualIndex == 1,
                        hovered: false
                    )
                }
            )
        }

        let coordinator = NativeTabOutlineController(makeConfig())
        let window = VisibleOutlineWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = coordinator.view
        defer { window.contentView = nil; window.close() }

        coordinator.update(makeConfig())
        coordinator.view.layoutSubtreeIfNeeded()
        let outline = coordinator.outline
        #expect(coordinator.reloadCount == 0)
        #expect(coordinator.membershipUpdateCount == 1)
        let initialNodes = try (0..<4).map { try #require(outline.item(atRow: $0) as? NativeTabNode) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Multi-item permutation in flat list uses moveSequence + beginUpdates/endUpdates without reloadData().
        groups = [GhosttyTabGroupPresentation(id: "flat", title: nil, icon: nil, tabs: [tabs[3], tabs[2], tabs[0], tabs[1]])]
        coordinator.update(makeConfig())
        #expect(coordinator.reloadCount == 0)
        #expect(coordinator.moveCount >= 2)
        if !reduceMotion {
            #expect(coordinator.animatedMoveCount == 1)
        }
        let reorderedNodes = try (0..<4).map { try #require(outline.item(atRow: $0) as? NativeTabNode) }
        #expect(reorderedNodes[0] === initialNodes[3])
        #expect(reorderedNodes[1] === initialNodes[2])
        #expect(reorderedNodes[2] === initialNodes[0])
        #expect(reorderedNodes[3] === initialNodes[1])

        // Grouped mode: simultaneous child reorders across two groups animate without reloadData().
        groups = [
            GhosttyTabGroupPresentation(id: "g1", title: "Alpha", icon: nil, tabs: [tabs[0], tabs[1]]),
            GhosttyTabGroupPresentation(id: "g2", title: "Beta", icon: nil, tabs: [tabs[2], tabs[3]]),
        ]
        coordinator.update(makeConfig())
        let reloadsAfterGrouping = coordinator.reloadCount
        let movesBeforeGroupReorder = coordinator.moveCount
        let animatedBeforeGroupReorder = coordinator.animatedMoveCount

        groups = [
            GhosttyTabGroupPresentation(id: "g1", title: "Alpha", icon: nil, tabs: [tabs[1], tabs[0]]),
            GhosttyTabGroupPresentation(id: "g2", title: "Beta", icon: nil, tabs: [tabs[3], tabs[2]]),
        ]
        coordinator.update(makeConfig())
        #expect(coordinator.reloadCount == reloadsAfterGrouping)
        #expect(coordinator.moveCount == movesBeforeGroupReorder + 2)
        if !reduceMotion {
            #expect(coordinator.animatedMoveCount == animatedBeforeGroupReorder + 1)
        }

        // animationsEnabled = false still uses moveItem without reloading, with duration 0.
        coordinator.animationsEnabled = false
        let animatedDisabledBaseline = coordinator.animatedMoveCount
        groups = [
            GhosttyTabGroupPresentation(id: "g1", title: "Alpha", icon: nil, tabs: [tabs[0], tabs[1]]),
            GhosttyTabGroupPresentation(id: "g2", title: "Beta", icon: nil, tabs: [tabs[3], tabs[2]]),
        ]
        coordinator.update(makeConfig())
        #expect(coordinator.reloadCount == reloadsAfterGrouping)
        #expect(coordinator.animatedMoveCount == animatedDisabledBaseline)
    }

    @Test func commandRevealMonitorPreservesHeldCommandAcrossNativeTabWindowSwitch() async throws {
        final class SimulatedKeyWindow: NSWindow {
            var simulatedIsKey = false
            var simulatedIsVisible = true
            override var isKeyWindow: Bool { simulatedIsKey }
            override var isVisible: Bool { simulatedIsVisible }
        }

        let window1 = SimulatedKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let window2 = SimulatedKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window1.isReleasedWhenClosed = false
        window2.isReleasedWhenClosed = false
        defer {
            window1.contentView = nil
            window2.contentView = nil
            window1.close()
            window2.close()
        }

        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window1.contentView = hostView
        window1.simulatedIsKey = true

        var modifiers: NSEvent.ModifierFlags = [.command]
        var appActive = true
        var activeKeyWindow: NSWindow? = window1

        let monitor = NativeCommandRevealMonitor()
        monitor.currentModifiersProvider = { modifiers }
        monitor.isAppActiveProvider = { appActive }
        monitor.keyWindowProvider = { activeKeyWindow }
        monitor.hostView = hostView

        // Initial sync picks up already-held ⌘ in the key window.
        #expect(monitor.isCommandHeld)

        // Native tab switch: old window resigns key, sidebar moves to new tab window, new window becomes key.
        window1.simulatedIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window1)
        #expect(monitor.isCommandHeld, "Deferred resign-key must not synchronously clear ⌘ during tab switch")

        window2.contentView = hostView
        window2.simulatedIsKey = true
        activeKeyWindow = window2
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window2)
        #expect(monitor.isCommandHeld)

        // After the deferred resign-key runloop tick runs, ⌘ remains revealed.
        try await Task.sleep(for: .milliseconds(30))
        #expect(monitor.isCommandHeld)

        // Releasing ⌘ or deactivating the app clears live state.
        appActive = false
        activeKeyWindow = nil
        window2.simulatedIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window2)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!monitor.isCommandHeld)

        // Returning to an active key window while ⌘ is held re-syncs immediately.
        appActive = true
        activeKeyWindow = window2
        window2.simulatedIsKey = true
        modifiers = [.command]
        monitor.syncFromCurrentModifiers()
        #expect(monitor.isCommandHeld)
    }
}
