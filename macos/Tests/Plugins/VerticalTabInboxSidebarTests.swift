import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// These tests switch the shared sidebar view mode. They stay synchronous while
/// it is changed, so no other main-actor test observes the inbox.
@Suite(.serialized) @MainActor
struct VerticalTabInboxSidebarTests {
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

    /// A window group of three tabs with a sidebar that is refreshed on demand.
    @MainActor
    private final class Sidebar {
        let fixture: TerminalWorkspaceRefactorTests.Fixture
        let controllers: [TerminalController]
        let state: VerticalTabWindowLayoutState
        let group: NSWindowTabGroup
        let nativeWindows: [NSWindow]
        let host: NativeTabSidebarHostingView
        let window: NSWindow
        private let configuration: NativeTabSidebarConfiguration

        init() throws {
            let fixture = try TerminalWorkspaceRefactorTests.Fixture()
            self.fixture = fixture
            let first = try fixture.tab()
            _ = try fixture.tab(parent: first)
            _ = try fixture.tab(parent: first)
            let group = try #require(first.window?.tabGroup)
            let controllers = group.windows.compactMap { $0.windowController as? TerminalController }
            let activities = try #require(NSApp.delegate as? AppDelegate).tabActivities
            let state = first.tabLayoutState
            state.applyPreferences(grouping: .none, ordering: .manual)
            // Shortcuts only follow an inbox the user can see.
            state.setSidebarVisible(true)
            state.updateTabs(controllers, selectedID: ObjectIdentifier(first))
            let configuration = NativeTabSidebarConfiguration(
                controller: first, layoutState: state, statusStore: activities, backgroundColor: .black)
            let host = NativeTabSidebarHostingView(configuration: configuration)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 250, height: 320),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            self.state = state
            self.group = group
            self.nativeWindows = group.windows
            self.controllers = controllers
            self.configuration = configuration
            self.host = host
            self.window = window
        }

        var list: NativeTabOutlineController { host.sidebar.list }

        /// A forced refresh, independent of which native tab is selected.
        func refresh() { host.configure(configuration) }

        var rows: [String] {
            (0..<list.outline.numberOfRows).compactMap { (list.outline.item(atRow: $0) as? NativeTabNode)?.key }
        }

        func key(_ controller: TerminalController) -> String { "tab:\(controller.tabSessionID)" }

        /// The list's tabs from the top, those of collapsed sections included.
        var displayed: [GhosttyOrganizedTab] { list.configuration.groups.flatMap(\.tabs) }

        var selected: TerminalController? { group.selectedWindow?.windowController as? TerminalController }

        var inboxButton: TabInboxHeaderButton? {
            func find(_ view: NSView) -> TabInboxHeaderButton? {
                (view as? TabInboxHeaderButton) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        func close() {
            window.contentView = nil
            window.close()
            fixture.close()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func ids(_ controllers: [TerminalController]) -> [ObjectIdentifier] { controllers.map(ObjectIdentifier.init) }

    /// The shared settings these tests change, restored by the returned closure.
    private func inboxSettings(
        view: GhosttyTabSidebarViewMode, grouping: GhosttyTabGroupingMode = .date,
        ordering: GhosttyTabOrderingMode = .recentlyUsed
    ) -> () -> Void {
        let settings = OhMyGhosttySettings.shared
        let previous = (settings.tabSidebarViewMode, settings.tabInboxGroupingMode,
                        settings.tabInboxOrderingMode, settings.showShortcutLabels)
        settings.tabSidebarViewMode = view
        settings.tabInboxGroupingMode = grouping
        settings.tabInboxOrderingMode = ordering
        settings.showShortcutLabels = true
        return {
            (settings.tabSidebarViewMode, settings.tabInboxGroupingMode,
             settings.tabInboxOrderingMode, settings.showShortcutLabels) = previous
        }
    }

    /// Projects by tab, in place of the directories the test terminals share.
    private struct Projects: GhosttyTabMetadataProviding {
        let names: [UUID: String]
        func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
            names[context.tabID].map { name in
                GhosttyTabMetadata(
                    project: .init(id: "project:/\(name)", title: name, icon: .systemSymbol("folder")),
                    agent: nil, workspace: nil, customGroup: nil)
            }
        }
    }

    private func detachedTabs(created: [Date]) throws -> [TerminalController] {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        return created.map {
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical, tabCreatedAt: $0)
        }
    }

    private func setAgentState(_ state: TabActivityState, on controller: TerminalController) throws {
        let surface = try #require(controller.surfaceTree.first)
        let activity = TabActivity(source: "codex", state: state, label: nil, message: nil,
                                   detail: nil, progress: nil, icon: nil)
        controller.restorePaneSessionState(.init(
            context: PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "Agent"),
            activity: activity, resumeDescriptor: nil, resumeContextID: nil, reducer: nil,
            typedHookContextID: nil, observedForegroundProcessID: nil, detectedAgent: nil,
            screenSignature: nil, screenStableTicks: nil, quickInputState: nil), for: surface.id)
    }

    @Test func dateGroupingBucketsRealTabsAndKeepsTheirNativeIndex() throws {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let controllers = try detachedTabs(created: [
            today.addingTimeInterval(-3 * 86_400), today.addingTimeInterval(-60),
            today, today.addingTimeInterval(-7_200),
        ])
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        func indices(_ ordering: GhosttyTabOrderingMode) -> [String: [Int]] {
            let groups = TabInboxModel.groups(tabs: controllers, grouping: .date, ordering: ordering, now: now)
            #expect(groups.allSatisfy { $0.count == $0.tabs.count })
            #expect(groups.flatMap(\.tabs).allSatisfy { controllers[$0.actualIndex - 1] === $0.controller })
            return Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.tabs.map(\.actualIndex)) })
        }

        // A restored tab without an interaction date counts as last used when it was created.
        #expect(controllers.allSatisfy { $0.tabLastInteractionAt == $0.tabCreatedAt })
        let byCreation = ["inbox:today": [3], "inbox:yesterday": [2, 4], "inbox:earlier": [1]]
        #expect(TabInboxModel.groups(tabs: controllers, grouping: .date, ordering: .created, now: now).map(\.id)
            == ["inbox:today", "inbox:yesterday", "inbox:earlier"])
        for ordering in GhosttyTabOrderingMode.allCases { #expect(indices(ordering) == byCreation) }

        // Selecting the oldest tab changes nothing; using it moves it to today.
        controllers[0].markTabActivated()
        #expect(indices(.recentlyUsed) == byCreation)
        controllers[0].recordTabInteraction(at: now.addingTimeInterval(60))
        #expect(indices(.recentlyUsed) == ["inbox:today": [1, 3], "inbox:yesterday": [2, 4]])
        #expect(indices(.created) == byCreation)
        #expect(indices(.manual) == byCreation)

        try setAgentState(.working, on: controllers[0])
        try setAgentState(.done, on: controllers[3])
        #expect(indices(.created) == ["inbox:continue": [4, 1], "inbox:today": [3], "inbox:yesterday": [2]])

        // Acknowledging the finished agent leaves it idle: it returns to its date section.
        try setAgentState(.idle, on: controllers[3])
        #expect(indices(.created) == ["inbox:continue": [1], "inbox:today": [3], "inbox:yesterday": [2, 4]])
    }

    @Test func noGroupingAndProjectGroupingFollowEachOrdering() throws {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let controllers = try detachedTabs(created: [
            today.addingTimeInterval(-3 * 86_400), today.addingTimeInterval(-60),
            today, today.addingTimeInterval(-7_200),
        ])
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        let names = ["alpha", "beta", "alpha", "beta"]
        let organization = GhosttyTabOrganizationModel(metadataProvider: .init(Projects(
            names: Dictionary(uniqueKeysWithValues: zip(controllers.map(\.tabSessionID), names)))))
        // The last tab was used most recently although it is not the newest.
        controllers[3].recordTabInteraction(at: now.addingTimeInterval(60))
        // An agent does not open Continue without date grouping.
        try setAgentState(.needsAttention, on: controllers[1])

        func groups(_ grouping: GhosttyTabGroupingMode, _ ordering: GhosttyTabOrderingMode) -> [GhosttyTabGroupPresentation] {
            let result = TabInboxModel.groups(tabs: controllers, grouping: grouping, ordering: ordering,
                                              organization: organization, now: now)
            #expect(result.flatMap(\.tabs).allSatisfy { controllers[$0.actualIndex - 1] === $0.controller })
            return result
        }
        let orders: [(GhosttyTabOrderingMode, [Int])] = [
            (.manual, [1, 2, 3, 4]), (.created, [3, 2, 4, 1]), (.recentlyUsed, [4, 3, 2, 1]),
        ]
        for (ordering, order) in orders {
            let flat = groups(.none, ordering)
            #expect(flat.map(\.id) == ["inbox:all"])
            #expect(flat.first?.title == nil)
            #expect(flat.first?.count == nil)
            #expect(flat.flatMap(\.tabs).map(\.actualIndex) == order)

            // A project takes the place of its first tab and keeps the order inside.
            let projects = groups(.project, ordering)
            let alpha = order.filter { names[$0 - 1] == "alpha" }
            let beta = order.filter { names[$0 - 1] == "beta" }
            let expected = names[order[0] - 1] == "alpha" ? [("alpha", alpha), ("beta", beta)] : [("beta", beta), ("alpha", alpha)]
            #expect(projects.map(\.id) == expected.map { "inbox:project:/\($0.0)" })
            #expect(projects.map { $0.title ?? "" } == expected.map { $0.0 })
            #expect(projects.map { $0.tabs.map(\.actualIndex) } == expected.map { $0.1 })
            #expect(projects.map(\.count) == [2, 2])
        }
    }

    @Test func tabsViewGroupsCarryNoCount() throws {
        let controllers = try detachedTabs(created: [Date(), Date()])
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        let model = GhosttyTabOrganizationModel()
        for grouping in GhosttyTabGroupingMode.allCases {
            let groups = model.groups(tabs: controllers, grouping: grouping, ordering: .manual)
            #expect(groups.allSatisfy { $0.count == nil })
            #expect(groups.flatMap(\.tabs).map(\.actualIndex) == [1, 2])
        }
    }

    @Test func inboxIsADisplayOrderThatLeavesTheTabsViewAsItWas() throws {
        let settings = OhMyGhosttySettings.shared
        let restore = inboxSettings(view: .tabs, grouping: .date, ordering: .created)
        defer { restore() }
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        let controllers = sidebar.controllers
        try #require(controllers.count == 3)
        let list = sidebar.list
        let outline = list.outline
        sidebar.refresh()
        let tabRows = sidebar.rows
        #expect(tabRows == controllers.map { sidebar.key($0) })
        #expect(list.configuration.allowsReordering)
        // The Tabs view keeps the row density.
        #expect(list.configuration.metrics == .tabs(rowHeight: settings.tabRowDensity.rowHeight))
        let drag = DragInfo(source: outline, tab: controllers[2].tabSessionID)
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(list.outlineView(outline, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0) == .move)

        try setAgentState(.needsAttention, on: controllers[2])
        settings.tabSidebarViewMode = .inbox
        sidebar.refresh()
        let today = [controllers[0], controllers[1]].sorted {
            $0.tabCreatedAt == $1.tabCreatedAt ? $0 === controllers[0] : $0.tabCreatedAt > $1.tabCreatedAt
        }
        #expect(sidebar.rows == ["group:inbox:continue", sidebar.key(controllers[2]),
                                 "group:inbox:today"] + today.map { sidebar.key($0) })
        #expect(list.configuration.groups.map(\.count) == [1, 2])
        #expect(sidebar.displayed.allSatisfy { controllers[$0.actualIndex - 1] === $0.controller })
        // Selection follows the controller, not the row it had in the Tabs view.
        #expect((outline.item(atRow: outline.selectedRow) as? NativeTabNode)?.tab?.controller === list.configuration.controller)
        let header = try #require(outline.view(atColumn: 0, row: 2, makeIfNecessary: true))
        #expect(descendants(header).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "2" && !$0.isHidden })

        // Inbox rows are roomier than any density, and headers are shorter than rows.
        #expect(list.configuration.metrics == .inbox)
        let node = try #require(list.nodes[sidebar.key(controllers[2])])
        let section = try #require(list.nodes["group:inbox:continue"])
        #expect(list.outlineView(outline, heightOfRowByItem: node) == (node.isTwoLine ? 54 : 36))
        #expect(list.outlineView(outline, heightOfRowByItem: section) == NativeTabRowMetrics.inbox.headerHeight)

        // Nothing can be dragged, and no drop can be placed relative to a row.
        #expect(!list.configuration.allowsReordering)
        #expect(list.outlineView(outline, pasteboardWriterForItem: node) == nil)
        #expect(list.resolveDrop(sourceID: controllers[2].tabSessionID, item: section, index: 0) == nil)
        #expect(list.outlineView(outline, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0) == [])
        #expect(!list.outlineView(outline, acceptDrop: drag, item: nil, childIndex: 0))

        // The native order and the user's grouping and ordering are untouched.
        #expect(sidebar.group.windows == sidebar.nativeWindows)
        #expect(controllers[0].tabLayoutState.groupingMode == .none)
        #expect(controllers[0].tabLayoutState.orderingMode == .manual)

        settings.tabSidebarViewMode = .tabs
        sidebar.refresh()
        #expect(sidebar.rows == tabRows)
        #expect(list.configuration.allowsReordering)
        #expect(list.configuration.metrics == .tabs(rowHeight: settings.tabRowDensity.rowHeight))
        #expect(list.configuration.groups.allSatisfy { $0.count == nil })
        #expect(list.outlineView(outline, pasteboardWriterForItem: node) != nil)
        #expect(sidebar.group.windows == sidebar.nativeWindows)
    }

    @Test func headerToggleShowsTheInboxWithItsOwnGroupingAndOrdering() throws {
        let settings = OhMyGhosttySettings.shared
        let restore = inboxSettings(view: .tabs, grouping: .date, ordering: .recentlyUsed)
        defer { restore() }
        let tabsViewSettings = (settings.groupingMode, settings.orderingMode)
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        sidebar.refresh()
        let strings = ChromeStrings.current
        let toggle = try #require(sidebar.inboxButton)
        let options = try #require(descendants(sidebar.host).compactMap { $0 as? NativeOptionsControl }.first)
        func titles() -> [String] {
            options.entries.compactMap { entry -> String? in
                guard case let .action(title, _, _, _, _) = entry else { return nil }
                return title
            }
        }
        func checked() -> [Bool] {
            options.entries.compactMap { entry -> Bool? in
                guard case let .action(_, _, _, checked, _) = entry else { return nil }
                return checked
            }
        }
        func choose(_ wanted: String) throws {
            let handler = options.entries.compactMap { entry -> (() -> Void)? in
                guard case let .action(title, _, _, _, handler) = entry, title == wanted else { return nil }
                return handler
            }.first
            let run = try #require(handler)
            run()
        }
        // Both views offer the same entries in the same words.
        let entries = [strings.groupHeader] + GhosttyTabGroupingMode.allCases.map(strings.groupingTitle)
            + [strings.orderHeader] + GhosttyTabOrderingMode.allCases.map(strings.orderingTitle)
        #expect(toggle.accessibilityIdentifier() == "tabs.inbox")
        #expect(toggle.toolTip == strings.toggleInbox(shown: false))
        #expect(titles() == entries)
        // The Tabs view: no grouping, manual order.
        #expect(checked() == [false, true, false, false, false, true, false, false])

        toggle.performClick(nil)
        #expect(settings.tabSidebarViewMode == .inbox)
        sidebar.refresh()
        #expect(toggle.toolTip == strings.toggleInbox(shown: true))
        #expect(titles() == entries)
        // The inbox: by date, recently used first.
        #expect(checked() == [false, false, false, true, false, false, false, true])

        try choose(strings.groupingTitle(.project))
        try choose(strings.orderingTitle(.created))
        #expect(settings.tabInboxGroupingMode == .project)
        #expect(settings.tabInboxOrderingMode == .created)
        sidebar.refresh()
        #expect(checked() == [false, false, true, false, false, false, true, false])
        #expect(sidebar.list.configuration.groups.allSatisfy { $0.id.hasPrefix("inbox:") && $0.title != nil })
        // The inbox's choices never reach the Tabs view or the native tabs.
        #expect(sidebar.state.groupingMode == .none)
        #expect(sidebar.state.orderingMode == .manual)
        #expect((settings.groupingMode, settings.orderingMode) == tabsViewSettings)
        #expect(sidebar.group.windows == sidebar.nativeWindows)

        try choose(strings.groupingTitle(.none))
        sidebar.refresh()
        #expect(sidebar.rows.allSatisfy { $0.hasPrefix("tab:") })
        #expect(sidebar.rows.count == 3)

        toggle.performClick(nil)
        #expect(settings.tabSidebarViewMode == .tabs)
        sidebar.refresh()
        #expect(checked() == [false, true, false, false, false, true, false, false])
        #expect(sidebar.rows == sidebar.controllers.map { sidebar.key($0) })
    }

    @Test func heldPointerKeepsRowsAndShortcutNumbersInPlaceUntilItIsReleased() throws {
        let restore = inboxSettings(view: .inbox, grouping: .date, ordering: .recentlyUsed)
        defer { restore() }
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        sidebar.refresh()
        let before = sidebar.rows
        try #require(before.first == "group:inbox:today" && before.count == 4)
        let shown = sidebar.displayed.map(\.controller)
        let last = try #require(shown.last)

        // Selecting a tab is not using it: nothing moves.
        last.markTabActivated()
        sidebar.refresh()
        #expect(sidebar.rows == before)
        #expect(!sidebar.host.sidebar.inboxOrderIsPending)

        sidebar.list.holdsOrderOverride = true
        last.recordTabInteraction(at: Date().addingTimeInterval(3_600))
        sidebar.refresh()
        #expect(sidebar.rows == before)
        #expect(sidebar.host.sidebar.inboxOrderIsPending)
        // The numbers follow the rows on screen, not the order that is waiting.
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == ids(shown))
        #expect(ids(shown[0].tabsInShortcutOrder(sidebar.controllers)) == ids(shown))

        sidebar.list.holdsOrderOverride = false
        sidebar.refresh()
        let released = [shown[2], shown[0], shown[1]]
        #expect(sidebar.rows == [before[0], before[3], before[1], before[2]])
        #expect(!sidebar.host.sidebar.inboxOrderIsPending)
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == ids(released))
        #expect(sidebar.group.windows == sidebar.nativeWindows)

        // `goto_tab` selects the row the user sees while the order is held.
        // Selecting can leave a tab, so nothing is read from the order afterwards.
        sidebar.list.holdsOrderOverride = true
        released[2].recordTabInteraction(at: Date().addingTimeInterval(7_200))
        sidebar.refresh()
        #expect(sidebar.host.sidebar.inboxOrderIsPending)
        #expect(ids(sidebar.displayed.map(\.controller)) == ids(released))
        let digit = sidebar.selected === released[0] ? 2 : 1
        #expect(TerminalController.selectTab(digit: digit, in: released[0].window))
        #expect(sidebar.selected === released[digit - 1])
    }

    @Test func shortcutNumbersCountInboxRowsAndGotoTabFollowsThem() throws {
        let settings = OhMyGhosttySettings.shared
        // Newest first: a display order that no tab switch can change.
        let restore = inboxSettings(view: .inbox, grouping: .none, ordering: .created)
        defer { restore() }
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        sidebar.refresh()
        let native = sidebar.controllers
        try #require(Set(native.map(\.tabCreatedAt)).count == 3)
        let rows = native.sorted { $0.tabCreatedAt > $1.tabCreatedAt }
        try #require(ids(rows) != ids(native))
        let state = sidebar.state
        #expect(ids(sidebar.displayed.map(\.controller)) == ids(rows))
        #expect(ids(state.inboxDisplayOrder.controllers) == ids(rows))
        #expect(native[0].tabShortcutsFollowInbox)
        #expect(ids(native[0].tabsInShortcutOrder(native)) == ids(rows))
        #expect(native[0].tabWindowsInShortcutOrder(native[0].workspaceTabWindows) == rows.compactMap(\.window))

        // The labels read 1, 2, 3 from the top; the native indices do not.
        func labelsCount(from index: (Int, GhosttyOrganizedTab) -> Int) {
            for (offset, tab) in sidebar.displayed.enumerated() {
                #expect(sidebar.list.configuration.presentation(tab)?.shortcut
                    == native[0].tabShortcutLabel(for: index(offset, tab)))
            }
        }
        #expect(sidebar.displayed.map { state.inboxDisplayOrder.position(of: $0.id) } == [1, 2, 3])
        #expect(sidebar.displayed.map(\.actualIndex) != [1, 2, 3])
        labelsCount { offset, _ in offset + 1 }

        // Numbers, the last tab, and next and previous all walk the rows.
        func select(_ digit: Int) -> TerminalController? {
            #expect(TerminalController.selectTab(digit: digit, in: native[0].window))
            return sidebar.selected
        }
        func go(_ action: ghostty_action_goto_tab_e) throws -> TerminalController? {
            let focused = try #require(sidebar.selected?.focusedSurface)
            NotificationCenter.default.post(name: Ghostty.Notification.ghosttyGotoTab, object: focused,
                                            userInfo: [Ghostty.Notification.GotoTabKey: action])
            return sidebar.selected
        }
        #expect(select(2) === rows[1])
        #expect(select(1) === rows[0])
        #expect(select(9) === rows[2])
        #expect(select(1) === rows[0])
        #expect(try go(GHOSTTY_GOTO_TAB_LAST) === rows[2])
        #expect(try go(GHOSTTY_GOTO_TAB_PREVIOUS) === rows[1])
        #expect(try go(GHOSTTY_GOTO_TAB_NEXT) === rows[2])
        #expect(try go(GHOSTTY_GOTO_TAB_NEXT) === rows[0])
        #expect(try go(GHOSTTY_GOTO_TAB_PREVIOUS) === rows[2])
        #expect(try go(ghostty_action_goto_tab_e(rawValue: 2)) === rows[1])
        #expect(try go(ghostty_action_goto_tab_e(rawValue: 1)) === rows[0])
        // The inbox never reorders the native tabs.
        #expect(sidebar.group.windows == sidebar.nativeWindows)

        // A hidden sidebar shows no order to follow.
        state.setSidebarVisible(false)
        #expect(!native[0].tabShortcutsFollowInbox)
        sidebar.refresh()
        #expect(state.inboxDisplayOrder.isEmpty)
        #expect(ids(native[0].tabsInShortcutOrder(native)) == ids(native))
        #expect(select(2) === native[1])
        state.setSidebarVisible(true)
        sidebar.refresh()
        #expect(native[0].tabShortcutsFollowInbox)
        #expect(select(2) === rows[1])

        // Outside the inbox nothing changed: numbers are the native order.
        settings.tabSidebarViewMode = .tabs
        #expect(!native[0].tabShortcutsFollowInbox)
        #expect(native[0].tabWindowsInShortcutOrder(native[0].workspaceTabWindows) == sidebar.nativeWindows)
        sidebar.refresh()
        #expect(state.inboxDisplayOrder.isEmpty)
        #expect(sidebar.displayed.map(\.actualIndex) == [1, 2, 3])
        labelsCount { _, tab in tab.actualIndex }
        #expect(select(1) === native[0])
        #expect(select(9) === native[2])
        #expect(try go(GHOSTTY_GOTO_TAB_PREVIOUS) === native[1])
    }

    @Test func tabsInCollapsedSectionsKeepTheirNumbers() throws {
        let restore = inboxSettings(view: .inbox, grouping: .date, ordering: .created)
        defer { restore() }
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        // The outline keeps the section of the selected tab open.
        let selectedID = sidebar.state.tabSnapshot.selectedID
        let waiting = sidebar.controllers.filter { ObjectIdentifier($0) != selectedID }
        let selected = try #require(sidebar.controllers.first { ObjectIdentifier($0) == selectedID })
        try #require(waiting.count == 2)
        for controller in waiting { try setAgentState(.working, on: controller) }
        sidebar.refresh()
        let rows = sidebar.displayed.map(\.controller)
        #expect(Set(ids(Array(rows.prefix(2)))) == Set(ids(waiting)))
        #expect(rows.last === selected)
        #expect(sidebar.rows.count == 5)

        sidebar.state.toggleGroup("inbox:continue")
        sidebar.refresh()
        #expect(sidebar.rows == ["group:inbox:continue", "group:inbox:today", sidebar.key(selected)])
        // The hidden rows still count: the visible tab stays number 3.
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == ids(rows))
        #expect(sidebar.state.inboxDisplayOrder.position(of: ObjectIdentifier(selected)) == 3)
        #expect(ids(selected.tabsInShortcutOrder(sidebar.controllers)) == ids(rows))
        #expect(TerminalController.selectTab(digit: 2, in: selected.window))
        #expect(sidebar.selected === rows[1])
    }

    @Test func inboxButtonShowsADotWhileTabsWaitInTheTabsView() throws {
        let settings = OhMyGhosttySettings.shared
        let restore = inboxSettings(view: .tabs)
        defer { restore() }
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        let controllers = sidebar.controllers
        let strings = ChromeStrings.current
        sidebar.refresh()
        let button = try #require(sidebar.inboxButton)
        func value() -> String? { button.accessibilityValue() as? String }
        #expect(!button.showsBadge)
        #expect(button.toolTip == strings.toggleInbox(shown: false))
        #expect(value() == "")

        // A working agent waits for nobody.
        try setAgentState(.working, on: controllers[0])
        sidebar.refresh()
        #expect(!button.showsBadge)

        try setAgentState(.needsAttention, on: controllers[1])
        try setAgentState(.done, on: controllers[2])
        sidebar.refresh()
        #expect(button.showsBadge)
        #expect(button.attentionCount == 2)
        #expect(button.toolTip == strings.toggleInbox(shown: false, attention: 2))
        #expect(value() == strings.inboxAttention(2))
        #expect(button.bounds.contains(button.badgeRect))
        try setAgentState(.error, on: controllers[0])
        sidebar.refresh()
        #expect(button.attentionCount == 3)

        // The inbox lists those tabs itself.
        settings.tabSidebarViewMode = .inbox
        sidebar.refresh()
        #expect(!button.showsBadge)
        #expect(button.toolTip == strings.toggleInbox(shown: true))
        #expect(value() == strings.selected)
        settings.tabSidebarViewMode = .tabs
        sidebar.refresh()
        #expect(button.attentionCount == 3)

        // Acknowledged agents are idle; the dot leaves with the last of them.
        for (remaining, controller) in zip([2, 1, 0], controllers) {
            try setAgentState(.idle, on: controller)
            sidebar.refresh()
            #expect(button.attentionCount == remaining)
            #expect(button.showsBadge == (remaining > 0))
        }
        #expect(button.toolTip == strings.toggleInbox(shown: false))
        #expect(value() == "")
    }

    @Test func rowsWithASubtitleAreTallerAndOtherRowsKeepTheirHeight() throws {
        let controllers = try detachedTabs(created: [Date(), Date(), Date()])
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let groups = GhosttyTabOrganizationModel().groups(tabs: controllers, grouping: .none, ordering: .manual)
        var subtitled: Set<ObjectIdentifier> = [ObjectIdentifier(controllers[1])]
        func view(_ metrics: NativeTabRowMetrics) -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: groups, selectedID: ObjectIdentifier(controllers[0]), layoutState: state,
                controller: controllers[0], metrics: metrics,
                presentation: { tab in
                    .init(title: "Fix the flaky test", remoteBreadcrumb: nil,
                          subtitle: subtitled.contains(tab.id) ? "~/code/project" : nil, shortcut: nil,
                          icon: .systemSymbol("terminal"), activity: nil, selected: false, hovered: false)
                })
        }
        let compact = NativeTabRowMetrics.tabs(rowHeight: 28)
        let list = NativeTabOutlineController(view(compact))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.contentView = nil; window.close() }
        list.update(view(compact))
        list.view.layoutSubtreeIfNeeded()
        let outline = list.outline
        func heights() -> [CGFloat] { (0..<3).map { outline.rect(ofRow: $0).height } }
        func rowHeights() -> [CGFloat] { list.roots.map { list.outlineView(outline, heightOfRowByItem: $0) } }
        func subtitle(row: Int) throws -> NSTextField? {
            let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
            return descendants(cell).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "~/code/project" && !$0.isHidden }
        }
        let single = heights()[0]
        #expect(heights() == [single, single + 14, single])
        #expect(rowHeights() == [28, 42, 28])
        let initial = [try subtitle(row: 0), try subtitle(row: 1), try subtitle(row: 2)]
        #expect(initial.map { $0 != nil } == [false, true, false])
        #expect(initial[1]?.font?.pointSize == 11)
        let reloads = list.reloadCount

        // The subtitle moves to another tab without any change of structure.
        subtitled = [ObjectIdentifier(controllers[2])]
        list.update(view(compact))
        #expect(heights() == [single, single, single + 14])
        #expect(list.heightUpdateCount == 1)
        let moved = [try subtitle(row: 0), try subtitle(row: 1), try subtitle(row: 2)]
        #expect(moved.map { $0 != nil } == [false, false, true])

        // A density change resizes every row.
        list.update(view(.tabs(rowHeight: 32)))
        #expect(heights() == [single + 4, single + 4, single + 4 + 14])

        // The inbox metrics: 36 pt rows, 54 pt with a 12 pt subtitle.
        list.update(view(.inbox))
        #expect(rowHeights() == [36, 36, 54])
        #expect(heights() == [single + 8, single + 8, single + 8 + 18])
        #expect(try subtitle(row: 2)?.font?.pointSize == 12)
        #expect(list.reloadCount == reloads)
    }
}
