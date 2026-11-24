import AppKit
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
            state.updateTabs(controllers, selectedID: ObjectIdentifier(first))
            let configuration = NativeTabSidebarConfiguration(
                controller: first, layoutState: state, statusStore: activities, backgroundColor: .black)
            let host = NativeTabSidebarHostingView(configuration: configuration)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 250, height: 320),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
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

        func close() {
            window.contentView = nil
            window.close()
            fixture.close()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

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

    @Test func realTabsAreBucketedByCreationAndKeepTheirNativeIndex() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let created = [today.addingTimeInterval(-3 * 86_400), today.addingTimeInterval(-60),
                       today, today.addingTimeInterval(-7_200)]
        let controllers = created.map {
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical, tabCreatedAt: $0)
        }
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        func indices(_ sort: GhosttyTabInboxSortMode) -> [String: [Int]] {
            let groups = TabInboxModel.groups(tabs: controllers, sort: sort, now: now)
            #expect(groups.allSatisfy { $0.count == $0.tabs.count })
            #expect(groups.flatMap(\.tabs).allSatisfy { controllers[$0.actualIndex - 1] === $0.controller })
            return Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.tabs.map(\.actualIndex)) })
        }

        // Every tab was activated when it was created, which is now.
        #expect(Set(indices(.recent).keys) == ["inbox:today"])
        #expect(TabInboxModel.groups(tabs: controllers, sort: .created, now: now).map(\.id)
            == ["inbox:today", "inbox:yesterday", "inbox:earlier"])
        #expect(indices(.created) == ["inbox:today": [3], "inbox:yesterday": [2, 4], "inbox:earlier": [1]])

        try setAgentState(.working, on: controllers[0])
        try setAgentState(.done, on: controllers[3])
        #expect(indices(.created) == ["inbox:continue": [4, 1], "inbox:today": [3], "inbox:yesterday": [2]])

        // Acknowledging the finished agent leaves it idle: it returns to its date section.
        try setAgentState(.idle, on: controllers[3])
        #expect(indices(.created) == ["inbox:continue": [1], "inbox:today": [3], "inbox:yesterday": [2, 4]])
    }

    @Test func tabsViewGroupsCarryNoCount() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<2).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        let model = GhosttyTabOrganizationModel()
        for grouping in GhosttyTabGroupingMode.allCases {
            let groups = model.groups(tabs: controllers, grouping: grouping, ordering: .created)
            #expect(groups.allSatisfy { $0.count == nil })
            #expect(groups.flatMap(\.tabs).map(\.actualIndex) == [1, 2])
        }
    }

    @Test func inboxIsADisplayOrderThatLeavesTheTabsViewAsItWas() throws {
        let settings = OhMyGhosttySettings.shared
        let previous = (settings.tabSidebarViewMode, settings.tabInboxSortMode)
        defer { (settings.tabSidebarViewMode, settings.tabInboxSortMode) = previous }
        settings.tabSidebarViewMode = .tabs
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
        let drag = DragInfo(source: outline, tab: controllers[2].tabSessionID)
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(list.outlineView(outline, validateDrop: drag, proposedItem: nil, proposedChildIndex: 0) == .move)

        try setAgentState(.needsAttention, on: controllers[2])
        settings.tabInboxSortMode = .created
        settings.tabSidebarViewMode = .inbox
        sidebar.refresh()
        let today = [controllers[0], controllers[1]].sorted {
            $0.tabCreatedAt == $1.tabCreatedAt ? $0 === controllers[0] : $0.tabCreatedAt > $1.tabCreatedAt
        }
        #expect(sidebar.rows == ["group:inbox:continue", sidebar.key(controllers[2]),
                                 "group:inbox:today"] + today.map { sidebar.key($0) })
        #expect(list.configuration.groups.map(\.count) == [1, 2])
        #expect(list.configuration.groups.flatMap(\.tabs).allSatisfy { controllers[$0.actualIndex - 1] === $0.controller })
        // Selection follows the controller, not the row it had in the Tabs view.
        #expect((outline.item(atRow: outline.selectedRow) as? NativeTabNode)?.tab?.controller === list.configuration.controller)
        let header = try #require(outline.view(atColumn: 0, row: 2, makeIfNecessary: true))
        #expect(descendants(header).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "2" && !$0.isHidden })

        // Nothing can be dragged, and no drop can be placed relative to a row.
        #expect(!list.configuration.allowsReordering)
        let node = try #require(list.nodes[sidebar.key(controllers[2])])
        #expect(list.outlineView(outline, pasteboardWriterForItem: node) == nil)
        #expect(list.resolveDrop(sourceID: controllers[2].tabSessionID,
                                 item: list.nodes["group:inbox:continue"], index: 0) == nil)
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
        #expect(list.configuration.groups.allSatisfy { $0.count == nil })
        #expect(list.outlineView(outline, pasteboardWriterForItem: node) != nil)
        #expect(sidebar.group.windows == sidebar.nativeWindows)
    }

    @Test func headerToggleShowsTheInboxAndItsSortModes() throws {
        let settings = OhMyGhosttySettings.shared
        let previous = (settings.tabSidebarViewMode, settings.tabInboxSortMode)
        defer { (settings.tabSidebarViewMode, settings.tabInboxSortMode) = previous }
        settings.tabSidebarViewMode = .tabs
        settings.tabInboxSortMode = .recent
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        sidebar.refresh()
        let strings = ChromeStrings.current
        let controls = descendants(sidebar.host).compactMap { $0 as? NativeActionControl }
        let toggle = try #require(controls.first { $0.accessibilityIdentifier() == "tabs.inbox" })
        let options = try #require(controls.compactMap { $0 as? NativeOptionsControl }.first)
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
        #expect(toggle.toolTip == strings.toggleInbox(shown: false))
        #expect(titles().contains(strings.groupHeader))

        toggle.performClick(nil)
        #expect(settings.tabSidebarViewMode == .inbox)
        sidebar.refresh()
        #expect(toggle.toolTip == strings.toggleInbox(shown: true))
        #expect(titles() == [strings.inboxSortHeader, strings.inboxSortTitle(.recent), strings.inboxSortTitle(.created)])
        #expect(checked() == [false, true, false])

        guard case let .action(_, _, _, _, chooseCreated)? = options.entries.last else {
            Issue.record("The inbox menu must end with the Created Time entry")
            return
        }
        chooseCreated()
        #expect(settings.tabInboxSortMode == .created)
        sidebar.refresh()
        #expect(checked() == [false, false, true])

        toggle.performClick(nil)
        #expect(settings.tabSidebarViewMode == .tabs)
        sidebar.refresh()
        #expect(titles().contains(strings.orderHeader))
    }

    @Test func heldPointerKeepsRowsInPlaceUntilItIsReleased() throws {
        let settings = OhMyGhosttySettings.shared
        let previous = (settings.tabSidebarViewMode, settings.tabInboxSortMode)
        defer { (settings.tabSidebarViewMode, settings.tabInboxSortMode) = previous }
        settings.tabInboxSortMode = .recent
        settings.tabSidebarViewMode = .inbox
        let sidebar = try Sidebar()
        defer { sidebar.close() }
        sidebar.refresh()
        let before = sidebar.rows
        try #require(before.first == "group:inbox:today" && before.count == 4)
        let last = try #require(sidebar.controllers.first { sidebar.key($0) == before[3] })

        sidebar.list.holdsOrderOverride = true
        last.markTabActivated()
        sidebar.refresh()
        #expect(sidebar.rows == before)
        #expect(sidebar.host.sidebar.inboxOrderIsPending)

        sidebar.list.holdsOrderOverride = false
        sidebar.refresh()
        #expect(sidebar.rows == [before[0], before[3], before[1], before[2]])
        #expect(!sidebar.host.sidebar.inboxOrderIsPending)
        #expect(sidebar.group.windows == sidebar.nativeWindows)
    }

    @Test func rowsWithASubtitleAreTallerAndOtherRowsKeepTheirHeight() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<3).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let groups = GhosttyTabOrganizationModel().groups(tabs: controllers, grouping: .none, ordering: .manual)
        var subtitled: Set<ObjectIdentifier> = [ObjectIdentifier(controllers[1])]
        func view(rowHeight: CGFloat) -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: groups, selectedID: ObjectIdentifier(controllers[0]), layoutState: state,
                controller: controllers[0], rowHeight: rowHeight,
                presentation: { tab in
                    .init(title: "Fix the flaky test", remoteBreadcrumb: nil,
                          subtitle: subtitled.contains(tab.id) ? "~/code/project" : nil, shortcut: nil,
                          icon: .systemSymbol("terminal"), activity: nil, selected: false, hovered: false)
                })
        }
        let list = NativeTabOutlineController(view(rowHeight: 28))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.contentView = nil; window.close() }
        list.update(view(rowHeight: 28))
        list.view.layoutSubtreeIfNeeded()
        let outline = list.outline
        func heights() -> [CGFloat] { (0..<3).map { outline.rect(ofRow: $0).height } }
        func subtitle(row: Int) throws -> NSTextField? {
            let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
            return descendants(cell).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "~/code/project" && !$0.isHidden }
        }
        let single = heights()[0]
        #expect(heights() == [single, single + NativeTabCell.subtitleLineHeight, single])
        #expect(list.outlineView(outline, heightOfRowByItem: list.roots[0]) == 28)
        #expect(list.outlineView(outline, heightOfRowByItem: list.roots[1]) == 28 + NativeTabCell.subtitleLineHeight)
        let initial = [try subtitle(row: 0), try subtitle(row: 1), try subtitle(row: 2)]
        #expect(initial.map { $0 != nil } == [false, true, false])
        let reloads = list.reloadCount

        // The subtitle moves to another tab without any change of structure.
        subtitled = [ObjectIdentifier(controllers[2])]
        list.update(view(rowHeight: 28))
        #expect(heights() == [single, single, single + NativeTabCell.subtitleLineHeight])
        #expect(list.heightUpdateCount == 1)
        let moved = [try subtitle(row: 0), try subtitle(row: 1), try subtitle(row: 2)]
        #expect(moved.map { $0 != nil } == [false, false, true])

        // A density change resizes every row.
        list.update(view(rowHeight: 32))
        #expect(heights() == [single + 4, single + 4, single + 4 + NativeTabCell.subtitleLineHeight])
        #expect(list.reloadCount == reloads)
    }
}
