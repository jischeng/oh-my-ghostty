import Foundation
import Testing
@testable import Ghostty

struct VerticalTabInboxModelTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }

    /// A time on 2026-11-`day` in the test calendar.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second)))
    }

    private func item(
        _ state: TabActivityState? = nil, created: Date, activated: Date? = nil, agent: Date? = nil
    ) -> TabInboxItem {
        TabInboxItem(state: state, createdAt: created, lastActivatedAt: activated ?? created, lastAgentActivityAt: agent)
    }

    @Test func sectionsChangeAtTheStartOfTheCalendarDay() throws {
        let now = try date(24, 0, 0, 30)
        let cases: [(created: Date, expected: TabInboxSection)] = [
            (try date(24, 0, 0, 0), .today),
            // One second before midnight is yesterday, although it is 31 seconds ago.
            (try date(23, 23, 59, 59), .yesterday),
            (try date(23, 0, 0, 0), .yesterday),
            (try date(22, 23, 59, 59), .earlier),
            (try date(1, 12), .earlier),
            // A clock that moved backwards must not hide a tab.
            (try date(25, 9), .today),
        ]
        for (created, expected) in cases {
            #expect(TabInboxModel.section(for: item(created: created), sort: .created,
                                          now: now, calendar: calendar) == expected)
        }

        // Almost a full day ago, but still the same calendar day.
        let evening = try date(24, 23, 30)
        let morning = item(created: try date(24, 0, 10))
        #expect(TabInboxModel.section(for: morning, sort: .created, now: evening, calendar: calendar) == .today)
    }

    @Test func continueListsTabsWaitingForTheUserFirstThenByRecency() throws {
        let created = try date(20, 9)
        let items = [
            item(.working, created: created, activated: try date(24, 11, 50)),
            item(.done, created: created, activated: try date(24, 11, 10)),
            item(.needsAttention, created: created, activated: try date(24, 11, 5)),
            item(.error, created: created, activated: try date(24, 11, 20)),
            item(.needsAttention, created: created, activated: try date(24, 11, 30)),
            item(.idle, created: created, activated: try date(24, 11, 40)),
            item(nil, created: created, activated: try date(24, 11, 45)),
        ]
        let now = try date(24, 12)
        let result = TabInboxModel.arrangement(items: items, sort: .recent, now: now, calendar: calendar)
        #expect(result[.continue] == [4, 2, 3, 1, 0])
        #expect(result[.today] == [6, 5])
        #expect(Set(result.keys) == [.continue, .today])
    }

    @Test func acknowledgedOrAbsentAgentsAreNotInContinue() {
        // Acknowledging a finished agent turns its activity idle or clears it.
        #expect(!TabInboxModel.isContinue(.idle))
        #expect(!TabInboxModel.isContinue(nil))
        for state in [TabActivityState.working, .done, .needsAttention, .error] {
            #expect(TabInboxModel.isContinue(state))
        }
    }

    @Test func recentUsesTheLatestTimestampAndCreatedIgnoresActivity() throws {
        let now = try date(24, 12)
        let items = [
            item(created: try date(22, 10), agent: try date(24, 9)),
            item(created: try date(23, 12), activated: try date(24, 8)),
            item(created: try date(24, 7)),
        ]
        let expectedRecent = [try date(24, 9), try date(24, 8), try date(24, 7)]
        #expect(items.map { TabInboxModel.sortDate($0, sort: .recent) } == expectedRecent)
        #expect(items.map { TabInboxModel.sortDate($0, sort: .created) } == items.map(\.createdAt))

        let recent = TabInboxModel.arrangement(items: items, sort: .recent, now: now, calendar: calendar)
        #expect(recent == [.today: [0, 1, 2]])
        let created = TabInboxModel.arrangement(items: items, sort: .created, now: now, calendar: calendar)
        #expect(created == [.today: [2], .yesterday: [1], .earlier: [0]])
    }

    @Test func sortModeAlsoOrdersContinueWithinTheSameState() throws {
        let items = [
            item(.working, created: try date(24, 9), activated: try date(24, 9)),
            item(.working, created: try date(24, 8), activated: try date(24, 11)),
        ]
        let now = try date(24, 12)
        #expect(TabInboxModel.arrangement(items: items, sort: .recent, now: now, calendar: calendar)[.continue] == [1, 0])
        #expect(TabInboxModel.arrangement(items: items, sort: .created, now: now, calendar: calendar)[.continue] == [0, 1])
    }

    @Test func equalDatesKeepTheNativeTabOrder() throws {
        let same = try date(24, 9)
        let now = try date(24, 12)
        let idle = Array(repeating: item(created: same), count: 4)
        #expect(TabInboxModel.arrangement(items: idle, sort: .recent, now: now, calendar: calendar) == [.today: [0, 1, 2, 3]])
        let waiting = [item(.done, created: same), item(.needsAttention, created: same),
                       item(.done, created: same), item(.needsAttention, created: same)]
        #expect(TabInboxModel.arrangement(items: waiting, sort: .created, now: now, calendar: calendar)
            == [.continue: [1, 3, 0, 2]])
    }

    @Test func sectionsWithoutTabsAreOmitted() throws {
        let now = try date(24, 12)
        #expect(TabInboxModel.arrangement(items: [], sort: .recent, now: now, calendar: calendar).isEmpty)
        let old = item(created: try date(2, 9))
        let earlier = TabInboxModel.arrangement(items: [old], sort: .created, now: now, calendar: calendar)
        #expect(earlier == [.earlier: [0]])
        #expect(TabInboxSection.allCases.map(\.groupID)
            == ["inbox:continue", "inbox:today", "inbox:yesterday", "inbox:earlier"])
    }

    @Test func heldOrderKeepsDisplayedRowsAndOnlyFollowsMembership() {
        let displayed: [TabInboxSection: [String]] = [.today: ["a", "b", "c"], .earlier: ["d"]]
        // b started working, d was closed, n and m are new tabs.
        let fresh: [TabInboxSection: [String]] = [.continue: ["b"], .today: ["n", "c", "a"], .earlier: ["m"]]
        #expect(TabInboxModel.holding(fresh: fresh, displayed: displayed)
            == [.today: ["a", "b", "n", "c"], .earlier: ["m"]])
        #expect(TabInboxModel.holding(fresh: fresh, displayed: fresh) == fresh)
        #expect(TabInboxModel.holding(fresh: fresh, displayed: [:]) == fresh)
        #expect(TabInboxModel.holding(fresh: [:], displayed: displayed).isEmpty)
    }

    @Test func settingsValuesAreTheDocumentedRawValues() {
        #expect(GhosttyTabSidebarViewMode.allCases.map(\.rawValue) == ["tabs", "inbox"])
        #expect(GhosttyTabInboxSortMode.allCases.map(\.rawValue) == ["recent", "created"])
    }

    @Test func inboxStringsAreLocalized() {
        let english = ChromeStrings(language: .english)
        let chinese = ChromeStrings(language: .simplifiedChinese)
        #expect(english.inbox == "Inbox")
        #expect(chinese.inbox == "收件箱")
        #expect(TabInboxSection.allCases.map { $0.title(chinese) } == ["继续", "今天", "昨天", "更早"])
        #expect(TabInboxSection.allCases.map { $0.title(english) } == ["Continue", "Today", "Yesterday", "Earlier"])
        #expect(GhosttyTabInboxSortMode.allCases.map(chinese.inboxSortTitle) == ["最近活动", "创建时间"])
    }
}
