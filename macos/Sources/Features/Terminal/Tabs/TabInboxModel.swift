import Foundation

/// What the tab sidebar lists: the tabs in their native order, or the inbox.
enum GhosttyTabSidebarViewMode: String, CaseIterable {
    case tabs
    case inbox
}

/// The date that orders the inbox below the Continue section.
enum GhosttyTabInboxSortMode: String, CaseIterable {
    case recent
    case created
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
    var lastActivatedAt: Date
    var lastAgentActivityAt: Date?
}

/// The inbox is a display order over the open tabs. It never changes the
/// native tab order, so `actualIndex` (and the `⌘N` label) stays truthful.
enum TabInboxModel {
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

    static func sortDate(_ item: TabInboxItem, sort: GhosttyTabInboxSortMode) -> Date {
        switch sort {
        case .created: item.createdAt
        case .recent: max(item.createdAt, item.lastActivatedAt, item.lastAgentActivityAt ?? .distantPast)
        }
    }

    static func section(
        for item: TabInboxItem,
        sort: GhosttyTabInboxSortMode,
        now: Date,
        calendar: Calendar = .current
    ) -> TabInboxSection {
        if isContinue(item.state) { return .continue }
        let date = sortDate(item, sort: sort)
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        return date >= yesterday ? .yesterday : .earlier
    }

    /// Native indices per section, in display order. Sections without tabs
    /// are absent.
    static func arrangement(
        items: [TabInboxItem],
        sort: GhosttyTabInboxSortMode,
        now: Date,
        calendar: Calendar = .current
    ) -> [TabInboxSection: [Int]] {
        let dates = items.map { sortDate($0, sort: sort) }
        var result: [TabInboxSection: [Int]] = [:]
        for index in items.indices {
            let target = section(for: items[index], sort: sort, now: now, calendar: calendar)
            result[target, default: []].append(index)
        }
        for section in TabInboxSection.allCases {
            result[section]?.sort { lhs, rhs in
                if section == .continue {
                    let lhsRank = continueRank(items[lhs].state)
                    let rhsRank = continueRank(items[rhs].state)
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                }
                if dates[lhs] != dates[rhs] { return dates[lhs] > dates[rhs] }
                return lhs < rhs
            }
        }
        return result
    }

    /// The arrangement to show while the pointer keeps the order in place:
    /// surviving tabs stay where they are displayed, closed tabs leave, and
    /// new tabs enter the section the fresh order gives them.
    static func holding<ID: Hashable>(
        fresh: [TabInboxSection: [ID]],
        displayed: [TabInboxSection: [ID]]
    ) -> [TabInboxSection: [ID]] {
        let live = Set(fresh.values.joined())
        var result = displayed.mapValues { $0.filter(live.contains) }
        let placed = Set(result.values.joined())
        for section in TabInboxSection.allCases {
            guard let ids = fresh[section] else { continue }
            for (offset, id) in ids.enumerated() where !placed.contains(id) {
                var target = result[section] ?? []
                // Enter above the next tab of the fresh order that is already shown here.
                let anchor = ids[(offset + 1)...].lazy.compactMap { target.firstIndex(of: $0) }.first
                target.insert(id, at: anchor ?? target.count)
                result[section] = target
            }
        }
        return result.filter { !$0.value.isEmpty }
    }

    @MainActor
    static func item(for controller: TerminalController, activities: TabActivityStore? = nil) -> TabInboxItem {
        let activity = controller.preferredAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        return TabInboxItem(
            state: activity?.state,
            createdAt: controller.tabCreatedAt,
            lastActivatedAt: controller.tabLastActivatedAt,
            lastAgentActivityAt: controller.tabLastAgentActivityAt
        )
    }

    @MainActor
    static func arrangement(
        tabs: [TerminalController],
        sort: GhosttyTabInboxSortMode,
        now: Date = Date(),
        calendar: Calendar = .current,
        activities: TabActivityStore? = nil
    ) -> [TabInboxSection: [ObjectIdentifier]] {
        let items = tabs.map { item(for: $0, activities: activities) }
        return arrangement(items: items, sort: sort, now: now, calendar: calendar)
            .mapValues { $0.map { ObjectIdentifier(tabs[$0]) } }
    }

    /// Sections in their fixed order. `actualIndex` is the native index + 1,
    /// whatever position the tab has in the inbox.
    @MainActor
    static func groups(
        _ arrangement: [TabInboxSection: [ObjectIdentifier]],
        of tabs: [TerminalController]
    ) -> [GhosttyTabGroupPresentation] {
        var organized: [ObjectIdentifier: GhosttyOrganizedTab] = [:]
        for (offset, controller) in tabs.enumerated() {
            organized[ObjectIdentifier(controller)] = GhosttyOrganizedTab(controller: controller, actualIndex: offset + 1)
        }
        let strings = ChromeStrings.current
        return TabInboxSection.allCases.compactMap { section -> GhosttyTabGroupPresentation? in
            let members = (arrangement[section] ?? []).compactMap { organized[$0] }
            guard !members.isEmpty else { return nil }
            return GhosttyTabGroupPresentation(
                id: section.groupID, title: section.title(strings), icon: .systemSymbol(section.symbol),
                tabs: members, count: members.count
            )
        }
    }

    @MainActor
    static func groups(
        tabs: [TerminalController],
        sort: GhosttyTabInboxSortMode,
        now: Date = Date(),
        calendar: Calendar = .current,
        activities: TabActivityStore? = nil
    ) -> [GhosttyTabGroupPresentation] {
        groups(arrangement(tabs: tabs, sort: sort, now: now, calendar: calendar, activities: activities), of: tabs)
    }
}
