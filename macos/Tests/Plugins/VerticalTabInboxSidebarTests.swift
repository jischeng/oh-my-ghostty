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

    private struct SavedInboxSettings {
        let viewMode: GhosttyTabSidebarViewMode
        let grouping: GhosttyTabGroupingMode
        let ordering: GhosttyTabOrderingMode
        let showShortcuts: Bool
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
        var inbox: NativeInboxViewController { host.sidebar.inbox }

        /// A forced refresh, independent of which native tab is selected.
        func refresh() {
            host.configure(configuration)
            host.layoutSubtreeIfNeeded()
        }

        var rows: [String] {
            if OhMyGhosttySettings.shared.tabSidebarViewMode == .inbox {
                return inbox.orderedItemKeys
            }
            return (0..<list.outline.numberOfRows).compactMap {
                (list.outline.item(atRow: $0) as? NativeTabNode)?.key
            }
        }

        func key(_ controller: TerminalController) -> String { "tab:\(controller.tabSessionID)" }

        /// Visible tabs top-to-bottom in the active sidebar mode.
        var displayed: [GhosttyOrganizedTab] {
            if OhMyGhosttySettings.shared.tabSidebarViewMode == .inbox {
                return inbox.visibleTabs
            }
            return list.configuration.groups.flatMap(\.tabs)
        }

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
        let saved = SavedInboxSettings(
            viewMode: settings.tabSidebarViewMode,
            grouping: settings.tabInboxGroupingMode,
            ordering: settings.tabInboxOrderingMode,
            showShortcuts: settings.showShortcutLabels
        )
        settings.tabSidebarViewMode = view
        settings.tabInboxGroupingMode = grouping
        settings.tabInboxOrderingMode = ordering
        settings.showShortcutLabels = true
        return {
            settings.tabSidebarViewMode = saved.viewMode
            settings.tabInboxGroupingMode = saved.grouping
            settings.tabInboxOrderingMode = saved.ordering
            settings.showShortcutLabels = saved.showShortcuts
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
        let inbox = sidebar.inbox
        let outline = list.outline
        sidebar.refresh()
        let tabRows = sidebar.rows
        #expect(!list.view.isHidden)
        #expect(inbox.view.isHidden)
        #expect(tabRows == controllers.map { sidebar.key($0) })
        // The Tabs view keeps the row density as pure single-line rows.
        #expect(list.configuration.rowHeight == settings.tabRowDensity.rowHeight)
        let drag = DragInfo(source: outline, tab: controllers[2].tabSessionID)
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(list.outlineView(outline, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0) == .move)

        try setAgentState(.needsAttention, on: controllers[2])
        settings.tabSidebarViewMode = .inbox
        sidebar.refresh()
        #expect(list.view.isHidden)
        #expect(!inbox.view.isHidden)
        let today = [controllers[0], controllers[1]].sorted {
            $0.tabCreatedAt == $1.tabCreatedAt ? $0 === controllers[0] : $0.tabCreatedAt > $1.tabCreatedAt
        }
        #expect(sidebar.rows == ["group:inbox:continue", sidebar.key(controllers[2]),
                                 "group:inbox:today"] + today.map { sidebar.key($0) })
        #expect(inbox.configuration.groups.map(\.count) == [1, 2])
        #expect(sidebar.displayed.allSatisfy { controllers[$0.actualIndex - 1] === $0.controller })
        // Selection follows the controller, not the row index it had in the Tabs view.
        #expect(inbox.rowView(for: controllers[0])?.isSelected == true)
        #expect(inbox.rowView(for: controllers[2])?.isSelected == false)
        let todayHeader = try #require(inbox.headerView(for: "inbox:today"))
        #expect(todayHeader.countLabel.stringValue == "2")
        #expect(!todayHeader.countLabel.isHidden)
        #expect(todayHeader.frame.height == NativeInboxMetrics.sectionHeaderHeight)

        let continueRow = try #require(inbox.rowView(for: controllers[2]))
        #expect(continueRow.frame.height == (continueRow.showsSubtitle ? 48 : 34))

        // The native order and the user's grouping and ordering are untouched.
        #expect(sidebar.group.windows == sidebar.nativeWindows)
        #expect(controllers[0].tabLayoutState.groupingMode == .none)
        #expect(controllers[0].tabLayoutState.orderingMode == .manual)

        settings.tabSidebarViewMode = .tabs
        sidebar.refresh()
        #expect(!list.view.isHidden)
        #expect(inbox.view.isHidden)
        #expect(sidebar.rows == tabRows)
        #expect(list.configuration.rowHeight == settings.tabRowDensity.rowHeight)
        #expect(list.configuration.groups.allSatisfy { $0.count == nil })
        let firstNode = try #require(list.nodes[sidebar.key(controllers[0])])
        #expect(list.outlineView(outline, pasteboardWriterForItem: firstNode) != nil)
        #expect(sidebar.group.windows == sidebar.nativeWindows)
    }

    @Test func headerToggleShowsTheInboxWithItsOwnGroupingAndOrdering() throws {
        let settings = OhMyGhosttySettings.shared
        let restore = inboxSettings(view: .tabs, grouping: .date, ordering: .recentlyUsed)
        defer { restore() }
        let savedGrouping = settings.groupingMode
        let savedOrdering = settings.orderingMode
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
        #expect(toggle.controlStyle == .plain)
        #expect(!toggle.isBordered)
        #expect(!toggle.isShown)
        #expect(toggle.toolTip == strings.toggleInbox(shown: false))
        #expect(titles() == entries)
        // The Tabs view: no grouping, manual order.
        #expect(checked() == [false, true, false, false, false, true, false, false])

        toggle.performClick(nil)
        #expect(settings.tabSidebarViewMode == .inbox)
        sidebar.refresh()
        #expect(toggle.controlStyle == .plain, "Active Inbox header toggle stays borderless without a stroke box")
        #expect(!toggle.isBordered)
        #expect(toggle.isShown)
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
        #expect(sidebar.inbox.configuration.groups.allSatisfy { $0.id.hasPrefix("inbox:") && $0.title != nil })
        // The inbox's choices never reach the Tabs view or the native tabs.
        #expect(sidebar.state.groupingMode == .none)
        #expect(sidebar.state.orderingMode == .manual)
        #expect(settings.groupingMode == savedGrouping)
        #expect(settings.orderingMode == savedOrdering)
        #expect(sidebar.group.windows == sidebar.nativeWindows)

        try choose(strings.groupingTitle(.none))
        sidebar.refresh()
        #expect(sidebar.rows.allSatisfy { $0.hasPrefix("tab:") })
        #expect(sidebar.rows.count == 3)

        toggle.performClick(nil)
        #expect(settings.tabSidebarViewMode == .tabs)
        sidebar.refresh()
        #expect(!toggle.isShown)
        #expect(toggle.controlStyle == .plain)
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

        sidebar.inbox.holdsOrderOverride = true
        last.recordTabInteraction(at: Date().addingTimeInterval(3_600))
        sidebar.refresh()
        #expect(sidebar.rows == before)
        #expect(sidebar.host.sidebar.inboxOrderIsPending)
        // The numbers follow the rows on screen, not the order that is waiting.
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == ids(shown))
        #expect(ids(shown[0].tabsInShortcutOrder(sidebar.controllers)) == ids(shown))

        sidebar.inbox.holdsOrderOverride = false
        sidebar.refresh()
        let released = [shown[2], shown[0], shown[1]]
        #expect(sidebar.rows == [before[0], before[3], before[1], before[2]])
        #expect(!sidebar.host.sidebar.inboxOrderIsPending)
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == ids(released))
        #expect(sidebar.group.windows == sidebar.nativeWindows)

        // `goto_tab` selects the row the user sees while the order is held.
        sidebar.inbox.holdsOrderOverride = true
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
        func labelsCount(inInbox: Bool, from index: (Int, GhosttyOrganizedTab) -> Int) {
            for (offset, tab) in sidebar.displayed.enumerated() {
                let actual = inInbox
                    ? sidebar.inbox.configuration.presentation(tab)?.shortcut
                    : sidebar.list.configuration.presentation(tab)?.shortcut
                #expect(actual == native[0].tabShortcutLabel(for: index(offset, tab)))
            }
        }
        #expect(sidebar.displayed.map { state.inboxDisplayOrder.position(of: $0.id) } == [1, 2, 3])
        #expect(sidebar.displayed.map(\.actualIndex) != [1, 2, 3])
        labelsCount(inInbox: true) { offset, _ in offset + 1 }

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
        labelsCount(inInbox: false) { _, tab in tab.actualIndex }
        #expect(select(1) === native[0])
        #expect(select(9) === native[2])
        #expect(try go(GHOSTTY_GOTO_TAB_PREVIOUS) === native[1])
    }

    @Test func collapsedInboxSectionsPersistAndRenumberVisibleShortcuts() throws {
        let restore = inboxSettings(view: .inbox, grouping: .date, ordering: .created)
        defer { restore() }
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        let selectedID = sidebar.state.tabSnapshot.selectedID
        let waiting = sidebar.controllers.filter { ObjectIdentifier($0) != selectedID }
        let selected = try #require(sidebar.controllers.first { ObjectIdentifier($0) == selectedID })
        try #require(waiting.count == 2)
        for controller in waiting { try setAgentState(.working, on: controller) }
        sidebar.refresh()
        let initialVisible = sidebar.displayed.map(\.controller)
        #expect(Set(ids(Array(initialVisible.prefix(2)))) == Set(ids(waiting)))
        #expect(initialVisible.last === selected)
        #expect(sidebar.rows.count == 5)
        let continueHeader = try #require(sidebar.inbox.headerView(for: "inbox:continue"))
        #expect(!continueHeader.isCollapsed)
        #expect(continueHeader.chevronRotationAngle == 0)

        // Collapsing Continue hides its rows, rotates its chevron -90°, persists the
        // inbox: group ID, and renumbers visible rows top-to-bottom so ⌘1 matches screen!
        #expect(continueHeader.accessibilityPerformPress())
        #expect(sidebar.state.collapsedGroupIDs.contains("inbox:continue"))
        sidebar.refresh()
        #expect(continueHeader.isCollapsed)
        #expect(abs(continueHeader.chevronRotationAngle - (-.pi / 2)) < 0.001)
        #expect(sidebar.rows == ["group:inbox:continue", "group:inbox:today", sidebar.key(selected)])
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == [ObjectIdentifier(selected)])
        #expect(sidebar.state.inboxDisplayOrder.position(of: ObjectIdentifier(selected)) == 1)
        #expect(sidebar.inbox.rowView(for: selected)?.shortcutLabel.stringValue == selected.tabShortcutLabel(for: 1))
        #expect(TerminalController.selectTab(digit: 1, in: selected.window))
        #expect(sidebar.selected === selected)

        // Even the section containing the selected tab can be collapsed cleanly in Inbox.
        let todayHeader = try #require(sidebar.inbox.headerView(for: "inbox:today"))
        #expect(todayHeader.accessibilityPerformPress())
        sidebar.refresh()
        #expect(sidebar.rows == ["group:inbox:continue", "group:inbox:today"])
        #expect(sidebar.state.inboxDisplayOrder.isEmpty)

        // Expanding both sections restores all 3 visible rows and ⌘1..3 shortcuts.
        #expect(continueHeader.accessibilityPerformPress())
        #expect(todayHeader.accessibilityPerformPress())
        sidebar.refresh()
        #expect(sidebar.rows.count == 5)
        #expect(ids(sidebar.state.inboxDisplayOrder.controllers) == ids(initialVisible))
        #expect(sidebar.state.inboxDisplayOrder.position(of: ObjectIdentifier(selected)) == 3)
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

    @Test func inboxGeometryPillSymmetryRemoteCloudAndContextMenu() throws {
        let controllers = try detachedTabs(created: [Date(), Date(), Date(), Date()])
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let organized = controllers.enumerated().map {
            GhosttyOrganizedTab(controller: $0.element, actualIndex: $0.offset + 1)
        }
        let groups = [
            GhosttyTabGroupPresentation(
                id: "inbox:continue",
                title: "Continue",
                icon: nil,
                tabs: Array(organized.prefix(2)),
                count: 2
            ),
            GhosttyTabGroupPresentation(
                id: "inbox:today",
                title: "Today",
                icon: nil,
                tabs: Array(organized.suffix(2)),
                count: 2
            ),
        ]

        func makeConfig() -> NativeInboxConfiguration {
            NativeInboxConfiguration(
                groups: groups,
                selectedID: ObjectIdentifier(controllers[1]),
                layoutState: state,
                controller: controllers[0],
                presentation: { tab in
                    switch tab.actualIndex {
                    case 1:
                        // 1-line plain path row (34pt)
                        return .init(
                            title: "~/code/omg-agent-inbox",
                            remoteBreadcrumb: nil,
                            subtitle: nil,
                            shortcut: "⌘1",
                            icon: .systemSymbol("terminal"),
                            activity: nil,
                            selected: false,
                            hovered: false
                        )
                    case 2:
                        // 2-line local named session row (48pt)
                        return .init(
                            title: "Rebuild native AppKit Inbox",
                            remoteBreadcrumb: nil,
                            subtitle: "~/code/omg-agent-inbox",
                            subtitleIsRemote: false,
                            shortcut: "⌘2",
                            icon: .asset("AgentClaudeLogo"),
                            activity: TabActivity(
                                source: "claude", state: .needsAttention, label: nil,
                                message: nil, detail: nil, progress: nil,
                                icon: .init(kind: .bundledAsset, name: "AgentClaudeLogo")
                            ),
                            selected: true,
                            hovered: false
                        )
                    case 3:
                        // 2-line remote SSH named session row (48pt + cloud before subtitle)
                        return .init(
                            title: "Deploy production worker",
                            remoteBreadcrumb: nil,
                            subtitle: "prod-box › ~/srv/worker",
                            subtitleIsRemote: true,
                            shortcut: "⌘3",
                            icon: .asset("AgentOpenAILogo"),
                            activity: nil,
                            selected: false,
                            hovered: false
                        )
                    default:
                        // 1-line unnamed SSH row with remoteBreadcrumb (34pt + cloud before breadcrumb)
                        return .init(
                            title: "prod-box",
                            remoteBreadcrumb: RemoteTabBreadcrumb(host: "prod-box", directory: "~/srv"),
                            subtitle: nil,
                            shortcut: "⌘4",
                            icon: .systemSymbol("terminal"),
                            activity: nil,
                            selected: false,
                            hovered: false
                        )
                    }
                }
            )
        }

        let inbox = NativeInboxViewController(makeConfig())
        let panelWidth: CGFloat = 250
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: panelWidth, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = inbox.view
        defer { window.contentView = nil; window.close() }
        inbox.update(makeConfig())
        inbox.view.layoutSubtreeIfNeeded()

        let expectedWidth = panelWidth - 16
        let header = try #require(inbox.headerView(for: "inbox:continue"))
        #expect(header.frame.minX == 8)
        #expect(header.frame.width == expectedWidth)
        #expect(header.frame.height == 26)
        #expect(header.chevronContainer.frame.minX == 4)
        #expect(header.titleLabel.frame.minX == 20)
        #expect(abs(header.countLabel.frame.maxX - (expectedWidth - 8)) <= 0.5)

        // Row 1: 1-line 34pt row centered at midY = 17pt
        let row1 = try #require(inbox.rowView(for: controllers[0]))
        #expect(row1.frame.minX == 8)
        #expect(row1.frame.width == expectedWidth)
        #expect(row1.frame.height == 34)
        #expect(row1.hoverRect == row1.selectionRect)
        #expect(row1.highlightRect == row1.bounds)
        #expect(NativeInboxRowView.cornerRadius == 6)
        #expect(row1.iconView.frame == NSRect(x: 8, y: 8, width: 18, height: 18))
        #expect(row1.titleLabel.frame.minX == 33)
        #expect(abs(row1.titleLabel.frame.midY - 17) <= 0.5)
        #expect(abs(row1.shortcutLabel.frame.maxX - (expectedWidth - 8)) <= 0.5)
        #expect(abs(row1.shortcutLabel.frame.midY - 17) <= 0.5)
        #expect(row1.subtitleLabel.isHidden)
        #expect(row1.remoteCloudView.isHidden)

        // Hover swaps ⌘N to 18×18 circular close button on the exact same centerline.
        inbox.updateHover(at: NSPoint(x: row1.frame.midX, y: row1.frame.midY))
        row1.layoutSubtreeIfNeeded()
        #expect(row1.isHovered)
        #expect(row1.shortcutLabel.isHidden)
        #expect(!row1.closeButton.isHidden)
        #expect(row1.closeButton.frame == NSRect(x: expectedWidth - 26, y: 8, width: 18, height: 18))

        // Row 2: 2-line 48pt local named session row (top midY = 16pt, bottom midY = 34.5pt at x = 33pt)
        let row2 = try #require(inbox.rowView(for: controllers[1]))
        #expect(row2.frame.minX == 8)
        #expect(row2.frame.width == expectedWidth)
        #expect(row2.frame.height == 48)
        #expect(row2.frame.minY - row1.frame.maxY == 2, "2pt vertical gap between rows")
        #expect(row2.isSelected)
        #expect(row2.iconView.frame == NSRect(x: 8, y: 7, width: 18, height: 18))
        #expect(row2.iconView.frame.midY == 16)
        #expect(row2.titleLabel.frame.minX == 33)
        #expect(abs(row2.titleLabel.frame.midY - 16) <= 0.5)
        #expect(abs(row2.shortcutLabel.frame.midY - 16) <= 0.5)
        #expect(row2.closeButton.frame.midY == 16)
        #expect(!row2.subtitleLabel.isHidden)
        #expect(row2.subtitleCloudView.isHidden)
        #expect(row2.subtitleLabel.frame.minX == row2.titleLabel.frame.minX)
        #expect(abs(row2.subtitleLabel.frame.midY - 34.5) <= 0.5)

        // Row 3: 2-line 48pt remote SSH named session row (inline cloud before subtitle)
        let row3 = try #require(inbox.rowView(for: controllers[2]))
        #expect(row3.frame.height == 48)
        #expect(!row3.subtitleCloudView.isHidden)
        #expect(row3.subtitleCloudView.frame.minX == 33)
        #expect(abs(row3.subtitleCloudView.frame.midY - 34.5) <= 0.5)
        #expect(row3.subtitleLabel.frame.minX == 33 + NativeInboxMetrics.cloudIconWidth + NativeInboxMetrics.cloudIconGap)
        #expect(abs(row3.subtitleLabel.frame.midY - 34.5) <= 0.5)

        // Row 4: 1-line 34pt remote SSH row (inline cloud before remoteBreadcrumb)
        let row4 = try #require(inbox.rowView(for: controllers[3]))
        #expect(row4.frame.height == 34)
        #expect(!row4.remoteCloudView.isHidden)
        #expect(row4.remoteCloudView.frame.minX == 33)
        #expect(abs(row4.remoteCloudView.frame.midY - 17) <= 0.5)
        #expect(row4.titleLabel.frame.minX == 33 + NativeInboxMetrics.cloudIconWidth + NativeInboxMetrics.cloudIconGap)

        // Native context menu includes Rename Tab…, New Tab, Move Tab to New Window, Close Tab, etc.
        let strings = ChromeStrings.current
        let menu = try #require(row2.contextMenuProvider?())
        let menuTitles = Set(menu.items.map(\.title))
        #expect(menuTitles.contains(strings.newTab))
        #expect(menuTitles.contains(strings.renameTab))
        #expect(menuTitles.contains(strings.moveTabToNewWindow))
        #expect(menuTitles.contains(strings.closeOtherTabs))
        #expect(menuTitles.contains(strings.closeTab))
    }
}
