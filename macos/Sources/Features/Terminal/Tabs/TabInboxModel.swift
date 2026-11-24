import Foundation

/// What the tab sidebar lists: the tabs in their native order, or the inbox.
enum GhosttyTabSidebarViewMode: String, CaseIterable {
    case tabs
    case inbox
}

enum TabInboxSection: String, CaseIterable {
    case `continue`
    case today
    case yesterday
    case earlier

    var groupID: String { "inbox:\(rawValue)" }

    var symbol: String {
        switch self {
        case .continue: "play.circle"
        case .today, .yesterday, .earlier: "calendar"
        }
    }

    func title(_ strings: ChromeStrings) -> String {
        switch self {
        case .continue: strings.inboxContinue
        case .today: strings.today
        case .yesterday: strings.yesterday
        case .earlier: strings.inboxEarlier
        }
    }
}

/// The inputs that place one tab in the inbox. A tab's position in the array
/// handed to `TabInboxModel` is its native index.
struct TabInboxItem: Equatable {
    /// State of the tab's preferred agent activity; nil without an agent.
    var state: TabActivityState?
    var createdAt: Date
    /// When the user last typed into the tab or left it after visiting it.
    var lastInteractionAt: Date
    var lastAgentActivityAt: Date?
}

/// One group of inbox rows, by identity only: what the sidebar keeps of the
/// order on screen between two refreshes.
struct TabInboxRows<ID: Hashable>: Equatable {
    let id: String
    var tabs: [ID]
}

/// The title and icon a group of inbox rows had when it was last computed.
struct TabInboxHeader {
    let title: String?
    let icon: GhosttyTabIcon?
}

/// The order the inbox has on screen, top to bottom. `goto_tab` and the
/// shortcut labels both count its rows. Weak, like `VerticalTabSnapshot`.
struct TabInboxDisplayOrder {
    private var tabs: [VerticalTabSnapshot.Tab] = []
    private var positions: [ObjectIdentifier: Int] = [:]

    init(_ controllers: [TerminalController] = []) {
        tabs = controllers.map { VerticalTabSnapshot.Tab(controller: $0) }
        for (offset, controller) in controllers.enumerated() {
            positions[ObjectIdentifier(controller)] = offset + 1
        }
    }

    var isEmpty: Bool { tabs.isEmpty }
    var controllers: [TerminalController] { tabs.compactMap(\.controller) }

    /// The row's number counted from the top, starting at 1 as `goto_tab` does.
    func position(of id: ObjectIdentifier) -> Int? { positions[id] }
}

/// The inbox is a display order over the open tabs. It never changes the
/// native tab order, so `actualIndex` stays the native index.
enum TabInboxModel {
    /// Prefix of the ids of inbox groups, so collapsing one leaves the Tabs
    /// view's group of the same project open.
    static let groupIDPrefix = "inbox:"

    /// An acknowledged finished agent reports `.idle` (or nothing), so it
    /// leaves Continue as soon as the user has seen it.
    static func isContinue(_ state: TabActivityState?) -> Bool {
        guard let state else { return false }
        return state != .idle
    }

    /// Order inside Continue: tabs waiting for the user come first.
    static func continueRank(_ state: TabActivityState?) -> Int {
        switch state {
        case .needsAttention: 0
        case .error: 1
        case .done: 2
        case .working: 3
        case .idle, nil: 4
        }
    }

    /// An agent that needs attention, failed, or finished without the user
    /// having seen it. A working agent is not waiting for anyone.
    static func waitsForUser(_ state: TabActivityState?) -> Bool {
        state == .needsAttention || state == .error || state == .done
    }

    /// How many tabs wait for the user, given the agent states of each tab.
    static func attentionCount(_ tabs: [[TabActivityState]]) -> Int {
        tabs.filter { $0.contains(where: waitsForUser) }.count
    }

    /// When the tab was last used: by the user, or by an agent changing state.
    static func recency(createdAt: Date, lastInteractionAt: Date, lastAgentActivityAt: Date?) -> Date {
        max(createdAt, lastInteractionAt, lastAgentActivityAt ?? .distantPast)
    }

    static func recency(_ item: TabInboxItem) -> Date {
        recency(createdAt: item.createdAt, lastInteractionAt: item.lastInteractionAt,
                lastAgentActivityAt: item.lastAgentActivityAt)
    }

    /// The date that puts a tab in a date section, and that orders it unless
    /// the order is manual.
    static func date(_ item: TabInboxItem, ordering: GhosttyTabOrderingMode) -> Date {
        switch ordering {
        case .recentlyUsed: recency(item)
        case .created, .manual: item.createdAt
        }
    }

    /// Native indices in display order, before any grouping. Dates are listed
    /// newest first; manual is the native tab order.
    static func order(items: [TabInboxItem], ordering: GhosttyTabOrderingMode) -> [Int] {
        guard ordering != .manual else { return Array(items.indices) }
        let dates = items.map { date($0, ordering: ordering) }
        return items.indices.sorted { dates[$0] != dates[$1] ? dates[$0] > dates[$1] : $0 < $1 }
    }

    static func section(
        for item: TabInboxItem,
        ordering: GhosttyTabOrderingMode,
        now: Date,
        calendar: Calendar = .current
    ) -> TabInboxSection {
        if isContinue(item.state) { return .continue }
        let used = date(item, ordering: ordering)
        let today = calendar.startOfDay(for: now)
        if used >= today { return .today }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        return used >= yesterday ? .yesterday : .earlier
    }

    /// Date grouping: native indices per section, in display order. Sections
    /// without tabs are absent.
    static func arrangement(
        items: [TabInboxItem],
        ordering: GhosttyTabOrderingMode,
        now: Date,
        calendar: Calendar = .current
    ) -> [TabInboxSection: [Int]] {
        var result: [TabInboxSection: [Int]] = [:]
        for index in order(items: items, ordering: ordering) {
            let target = section(for: items[index], ordering: ordering, now: now, calendar: calendar)
            result[target, default: []].append(index)
        }
        // Tabs waiting for the user lead Continue; the ordering decides among equals.
        if let waiting = result[.continue] {
            result[.continue] = waiting.enumerated().sorted { lhs, rhs in
                (continueRank(items[lhs.element].state), lhs.offset) < (continueRank(items[rhs.element].state), rhs.offset)
            }.map(\.element)
        }
        return result
    }

    /// The rows to show while the pointer keeps the order in place: surviving
    /// tabs stay where they are displayed, closed tabs leave, and new tabs
    /// enter the group the fresh order gives them.
    static func holding<ID: Hashable>(
        fresh: [TabInboxRows<ID>],
        displayed: [TabInboxRows<ID>]
    ) -> [TabInboxRows<ID>] {
        let live = Set(fresh.flatMap(\.tabs))
        var result = displayed.map { TabInboxRows(id: $0.id, tabs: $0.tabs.filter(live.contains)) }
        let placed = Set(result.flatMap(\.tabs))
        for (position, group) in fresh.enumerated() {
            for (offset, id) in group.tabs.enumerated() where !placed.contains(id) {
                let shown = result.map(\.id)
                let index: Int
                if let existing = shown.firstIndex(of: group.id) {
                    index = existing
                } else {
                    // A group that is not on screen enters above the next fresh group that is.
                    index = fresh[(position + 1)...].lazy.compactMap { shown.firstIndex(of: $0.id) }.first ?? shown.count
                    result.insert(TabInboxRows(id: group.id, tabs: []), at: index)
                }
                // Enter above the next tab of the fresh order that is already shown here.
                let target = result[index].tabs
                let anchor = group.tabs[(offset + 1)...].lazy.compactMap { target.firstIndex(of: $0) }.first
                result[index].tabs.insert(id, at: anchor ?? target.count)
            }
        }
        return result.filter { !$0.tabs.isEmpty }
    }

    @MainActor
    static func item(for controller: TerminalController, activities: TabActivityStore? = nil) -> TabInboxItem {
        let activity = controller.preferredAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        return TabInboxItem(
            state: activity?.state,
            createdAt: controller.tabCreatedAt,
            lastInteractionAt: controller.tabLastInteractionAt,
            lastAgentActivityAt: controller.tabLastAgentActivityAt
        )
    }

    /// How many of `tabs` wait for the user. Every pane counts, not only the
    /// one whose activity the tab row shows.
    @MainActor
    static func attentionCount(tabs: [TerminalController], activities: TabActivityStore? = nil) -> Int {
        attentionCount(tabs.map { tab in
            tab.agentActivities.values.map(\.state) +
                [activities?.activity(for: tab.tabSessionID)?.state].compactMap { $0 }
        })
    }

    /// The inbox for one grouping and ordering. `actualIndex` is the native
    /// index + 1, whatever position the tab has in the inbox.
    ///
    /// Date grouping has the inbox's own sections, led by Continue. No
    /// grouping and project grouping are the Tabs view's, applied to the
    /// inbox order.
    @MainActor
    static func groups(
        tabs: [TerminalController],
        grouping: GhosttyTabGroupingMode,
        ordering: GhosttyTabOrderingMode,
        organization: GhosttyTabOrganizationModel? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        activities: TabActivityStore? = nil
    ) -> [GhosttyTabGroupPresentation] {
        let items = tabs.map { item(for: $0, activities: activities) }
        func organized(_ indices: [Int]) -> [GhosttyOrganizedTab] {
            indices.map { GhosttyOrganizedTab(controller: tabs[$0], actualIndex: $0 + 1) }
        }
        if grouping == .date {
            let sections = arrangement(items: items, ordering: ordering, now: now, calendar: calendar)
            let strings = ChromeStrings.current
            return TabInboxSection.allCases.compactMap { section -> GhosttyTabGroupPresentation? in
                guard let indices = sections[section], !indices.isEmpty else { return nil }
                return GhosttyTabGroupPresentation(
                    id: section.groupID, title: section.title(strings), icon: .systemSymbol(section.symbol),
                    tabs: organized(indices), count: indices.count
                )
            }
        }
        let ordered = organized(order(items: items, ordering: ordering))
        let organization = organization ?? GhosttyTabOrganizationModel()
        return organization.groups(of: ordered, grouping: grouping, now: now).map { group in
            GhosttyTabGroupPresentation(
                id: groupIDPrefix + group.id, title: group.title, icon: group.icon,
                tabs: group.tabs, count: group.title == nil ? nil : group.tabs.count
            )
        }
    }

    /// The identity of each group's rows, which is all a held order keeps.
    @MainActor
    static func rows(_ groups: [GhosttyTabGroupPresentation]) -> [TabInboxRows<ObjectIdentifier>] {
        groups.map { TabInboxRows(id: $0.id, tabs: $0.tabs.map(\.id)) }
    }

    /// Rows back as groups of the tabs that are still open.
    @MainActor
    static func groups(
        _ rows: [TabInboxRows<ObjectIdentifier>],
        headers: [String: TabInboxHeader],
        of tabs: [TerminalController]
    ) -> [GhosttyTabGroupPresentation] {
        var organized: [ObjectIdentifier: GhosttyOrganizedTab] = [:]
        for (offset, controller) in tabs.enumerated() {
            organized[ObjectIdentifier(controller)] = GhosttyOrganizedTab(controller: controller, actualIndex: offset + 1)
        }
        return rows.compactMap { group -> GhosttyTabGroupPresentation? in
            let members = group.tabs.compactMap { organized[$0] }
            guard !members.isEmpty else { return nil }
            let header = headers[group.id]
            return GhosttyTabGroupPresentation(
                id: group.id, title: header?.title, icon: header?.icon,
                tabs: members, count: header?.title == nil ? nil : members.count
            )
        }
    }
}
