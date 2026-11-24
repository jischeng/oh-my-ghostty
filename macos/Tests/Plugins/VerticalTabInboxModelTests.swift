import Combine
import Foundation
import Testing
@testable import Ghostty

struct VerticalTabInboxModelTests {
    private typealias Rows = TabInboxRows<String>

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
        _ state: TabActivityState? = nil, created: Date, interacted: Date? = nil, agent: Date? = nil
    ) -> TabInboxItem {
        TabInboxItem(state: state, createdAt: created, lastInteractionAt: interacted ?? created,
                     lastAgentActivityAt: agent)
    }

    private func arrangement(
        _ items: [TabInboxItem], _ ordering: GhosttyTabOrderingMode, now: Date
    ) -> [TabInboxSection: [Int]] {
        TabInboxModel.arrangement(items: items, ordering: ordering, now: now, calendar: calendar)
    }

    @Test func sectionsChangeAtTheStartOfTheCalendarDay() throws {
        let now = try date(24, 0, 0, 30)
        let cases: [(created: Date, expected: TabInboxSection)] = [
            (try date(24, 0, 0, 0), .today),
            (try date(23, 23, 59, 59), .yesterday),
            (try date(23, 0, 0, 0), .yesterday),
            (try date(22, 23, 59, 59), .earlier),
            (try date(1, 12), .earlier),
            (try date(25, 9), .today),
        ]
        for (created, expected) in cases {
            for ordering in GhosttyTabOrderingMode.allCases {
                #expect(TabInboxModel.section(for: item(created: created), ordering: ordering,
                                              now: now, calendar: calendar) == expected)
            }
        }

        let evening = try date(24, 23, 30)
        let morning = item(created: try date(24, 0, 10))
        #expect(TabInboxModel.section(for: morning, ordering: .created, now: evening, calendar: calendar) == .today)
    }

    @Test func recencyIsTheLatestOfCreationInteractionAndAgentActivity() throws {
        let items = [
            item(created: try date(22, 10), agent: try date(24, 9)),
            item(created: try date(23, 12), interacted: try date(24, 8)),
            item(created: try date(24, 7)),
            item(created: try date(24, 6), interacted: try date(20, 6)),
        ]
        let recency = [try date(24, 9), try date(24, 8), try date(24, 7), try date(24, 6)]
        #expect(items.map { TabInboxModel.recency($0) } == recency)
        #expect(items.map { TabInboxModel.date($0, ordering: .recentlyUsed) } == recency)
        #expect(items.map { TabInboxModel.date($0, ordering: .created) } == items.map(\.createdAt))
        #expect(items.map { TabInboxModel.date($0, ordering: .manual) } == items.map(\.createdAt))
    }

    @Test func eachOrderingListsTheTabsInItsOwnOrder() throws {
        let items = [
            item(created: try date(22, 10), agent: try date(24, 9)),
            item(created: try date(23, 12), interacted: try date(24, 8)),
            item(created: try date(24, 7)),
            item(created: try date(24, 8, 30)),
        ]
        #expect(TabInboxModel.order(items: items, ordering: .recentlyUsed) == [0, 3, 1, 2])
        #expect(TabInboxModel.order(items: items, ordering: .created) == [3, 2, 1, 0])
        #expect(TabInboxModel.order(items: items, ordering: .manual) == [0, 1, 2, 3])
        for ordering in GhosttyTabOrderingMode.allCases {
            #expect(TabInboxModel.order(items: [], ordering: ordering).isEmpty)
        }
    }

    @Test func dateGroupingBucketsByTheOrderingDate() throws {
        let now = try date(24, 12)
        let items = [
            item(created: try date(22, 10), agent: try date(24, 9)),
            item(created: try date(23, 12), interacted: try date(24, 8)),
            item(created: try date(24, 7)),
            item(created: try date(24, 8, 30)),
        ]
        #expect(arrangement(items, .recentlyUsed, now: now) == [.today: [0, 3, 1, 2]])
        #expect(arrangement(items, .created, now: now) == [.today: [3, 2], .yesterday: [1], .earlier: [0]])
        #expect(arrangement(items, .manual, now: now) == [.today: [2, 3], .yesterday: [1], .earlier: [0]])
    }

    @Test func continueListsTabsWaitingForTheUserFirstThenByTheOrdering() throws {
        let created = try date(20, 9)
        let items = [
            item(.working, created: created, interacted: try date(24, 11, 50)),
            item(.done, created: created, interacted: try date(24, 11, 10)),
            item(.needsAttention, created: created, interacted: try date(24, 11, 5)),
            item(.error, created: created, interacted: try date(24, 11, 20)),
            item(.needsAttention, created: created, interacted: try date(24, 11, 30)),
            item(.idle, created: created, interacted: try date(24, 11, 40)),
            item(nil, created: created, interacted: try date(24, 11, 45)),
        ]
        let now = try date(24, 12)
        let recent = arrangement(items, .recentlyUsed, now: now)
        #expect(recent[.continue] == [4, 2, 3, 1, 0])
        #expect(recent[.today] == [6, 5])
        #expect(Set(recent.keys) == [.continue, .today])

        let manual = arrangement(items, .manual, now: now)
        #expect(manual == [.continue: [2, 4, 3, 1, 0], .earlier: [5, 6]])
        #expect(arrangement(items, .created, now: now) == manual)
    }

    @Test func theOrderingAlsoOrdersContinueWithinTheSameState() throws {
        let items = [
            item(.working, created: try date(24, 9)),
            item(.working, created: try date(24, 8), interacted: try date(24, 11)),
            item(.working, created: try date(24, 10)),
        ]
        let now = try date(24, 12)
        #expect(arrangement(items, .recentlyUsed, now: now) == [.continue: [1, 2, 0]])
        #expect(arrangement(items, .created, now: now) == [.continue: [2, 0, 1]])
        #expect(arrangement(items, .manual, now: now) == [.continue: [0, 1, 2]])
    }

    @Test func acknowledgedOrAbsentAgentsAreNotInContinue() {
        #expect(!TabInboxModel.isContinue(.idle))
        #expect(!TabInboxModel.isContinue(nil))
        for state in [TabActivityState.working, .done, .needsAttention, .error] {
            #expect(TabInboxModel.isContinue(state))
        }
    }

    @Test func equalDatesKeepTheNativeTabOrder() throws {
        let same = try date(24, 9)
        let now = try date(24, 12)
        let idle = Array(repeating: item(created: same), count: 4)
        let waiting = [item(.done, created: same), item(.needsAttention, created: same),
                       item(.done, created: same), item(.needsAttention, created: same)]
        for ordering in GhosttyTabOrderingMode.allCases {
            #expect(TabInboxModel.order(items: idle, ordering: ordering) == [0, 1, 2, 3])
            #expect(arrangement(idle, ordering, now: now) == [.today: [0, 1, 2, 3]])
            #expect(arrangement(waiting, ordering, now: now) == [.continue: [1, 3, 0, 2]])
        }
    }

    @Test func sectionsWithoutTabsAreOmitted() throws {
        let now = try date(24, 12)
        #expect(arrangement([], .recentlyUsed, now: now).isEmpty)
        let old = item(created: try date(2, 9))
        #expect(arrangement([old], .created, now: now) == [.earlier: [0]])
        #expect(TabInboxSection.allCases.map(\.groupID)
            == ["inbox:continue", "inbox:today", "inbox:yesterday", "inbox:earlier"])
    }

    @Test func heldOrderKeepsDisplayedRowsAndOnlyFollowsMembership() {
        let displayed = [Rows(id: "inbox:today", tabs: ["a", "b", "c"]), Rows(id: "inbox:earlier", tabs: ["d"])]
        let fresh = [Rows(id: "inbox:continue", tabs: ["b"]), Rows(id: "inbox:today", tabs: ["n", "c", "a"]),
                     Rows(id: "inbox:earlier", tabs: ["m"])]
        #expect(TabInboxModel.holding(fresh: fresh, displayed: displayed)
            == [Rows(id: "inbox:today", tabs: ["a", "b", "n", "c"]), Rows(id: "inbox:earlier", tabs: ["m"])])
        #expect(TabInboxModel.holding(fresh: fresh, displayed: fresh) == fresh)
        #expect(TabInboxModel.holding(fresh: fresh, displayed: []) == fresh)
        #expect(TabInboxModel.holding(fresh: [], displayed: displayed).isEmpty)
    }

    @Test func heldOrderPlacesNewGroupsWhereTheFreshOrderHasThem() {
        let today = [Rows(id: "inbox:today", tabs: ["a"])]
        let withContinue = [Rows(id: "inbox:continue", tabs: ["x"]), Rows(id: "inbox:today", tabs: ["a"]),
                            Rows(id: "inbox:earlier", tabs: ["y"])]
        #expect(TabInboxModel.holding(fresh: withContinue, displayed: today) == withContinue)

        let projects = [Rows(id: "inbox:project:/one", tabs: ["a", "b"]), Rows(id: "inbox:project:/two", tabs: ["c"])]
        let moved = [Rows(id: "inbox:project:/two", tabs: ["c", "b"]), Rows(id: "inbox:project:/one", tabs: ["a"]),
                     Rows(id: "inbox:project:/three", tabs: ["n"])]
        #expect(TabInboxModel.holding(fresh: moved, displayed: projects)
            == projects + [Rows(id: "inbox:project:/three", tabs: ["n"])])
        let leading = [Rows(id: "inbox:project:/zero", tabs: ["z"])] + projects
        #expect(TabInboxModel.holding(fresh: leading, displayed: projects) == leading)
    }

    @Test func attentionCountsTabsThatWaitForTheUser() {
        #expect(TabInboxModel.waitsForUser(.needsAttention))
        #expect(TabInboxModel.waitsForUser(.error))
        #expect(TabInboxModel.waitsForUser(.done))
        #expect(!TabInboxModel.waitsForUser(.working))
        #expect(!TabInboxModel.waitsForUser(.idle))
        #expect(!TabInboxModel.waitsForUser(nil))

        #expect(TabInboxModel.attentionCount([]) == 0)
        #expect(TabInboxModel.attentionCount([[.working], [.idle], []]) == 0)
        #expect(TabInboxModel.attentionCount([
            [.working], [.done], [.idle, .needsAttention], [], [.error, .working, .done], [.idle],
        ]) == 3)
    }

    @Test func settingsValuesAreTheDocumentedRawValues() {
        #expect(GhosttyTabSidebarViewMode.allCases.map(\.rawValue) == ["tabs", "inbox"])
        #expect(GhosttyTabGroupingMode.allCases.map(\.rawValue) == ["none", "project", "date"])
        #expect(GhosttyTabOrderingMode.allCases.map(\.rawValue) == ["manual", "created", "recentlyUsed"])
    }

    @Test func inboxStringsAreLocalized() {
        let english = ChromeStrings(language: .english)
        let chinese = ChromeStrings(language: .simplifiedChinese)
        #expect(english.inbox == "Inbox")
        #expect(chinese.inbox == "收件箱")
        #expect(TabInboxSection.allCases.map { $0.title(chinese) } == ["继续", "今天", "昨天", "更早"])
        #expect(TabInboxSection.allCases.map { $0.title(english) } == ["Continue", "Today", "Yesterday", "Earlier"])

        #expect(english.toggleInbox(shown: false) == "Show Inbox")
        #expect(english.toggleInbox(shown: false, attention: 1) == "Show Inbox · 1 tab needs attention")
        #expect(english.toggleInbox(shown: false, attention: 3) == "Show Inbox · 3 tabs need attention")
        #expect(chinese.toggleInbox(shown: false, attention: 3) == "显示收件箱 · 3 个标签页待处理")
        #expect(english.toggleInbox(shown: true, attention: 3) == "Show Tabs")
        #expect(chinese.toggleInbox(shown: true) == "显示标签页")
    }

    @Test @MainActor func untitledAgentRowRemainsSingleLineAndNonInboxSurfacesStayPure() throws {
        let settings = OhMyGhosttySettings.shared
        let savedMode = settings.agentSessionTitleMode
        let savedPathDisplay = settings.tabPathDisplay
        settings.agentSessionTitleMode = .native
        settings.tabPathDisplay = .folderName
        defer {
            settings.agentSessionTitleMode = savedMode
            settings.tabPathDisplay = savedPathDisplay
        }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = nil
        surface.pwd = NSHomeDirectory() + "/code/omg-agent-inbox"
        let conversation = try #require(AgentConversationID(UUID().uuidString))
        controller.adoptAgentResumeDescriptor(
            .init(agent: .claude, conversationID: conversation,
                  scope: .local, workingDirectory: NSHomeDirectory() + "/code/omg-agent-inbox"),
            for: surface
        )

        // Without a conversation title or OSC topic, Inbox shows a single-line
        // location with the Agent icon (never "Claude Code" + dangling "~").
        let untitledInbox = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil, style: .inbox)
        )
        #expect(untitledInbox.title == "~/code/omg-agent-inbox")
        #expect(!untitledInbox.showsSubtitle)
        #expect(untitledInbox.subtitle == nil)
        #expect(untitledInbox.icon == .asset(SupportedAgent.claude.glyphAssetName))

        // Chrome without live agent activity keeps its plain terminal icon and folder name.
        let idleChrome = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil, style: .chrome)
        )
        #expect(idleChrome.title == "omg-agent-inbox")
        #expect(!idleChrome.showsSubtitle)
        #expect(idleChrome.icon == .systemSymbol("terminal"))

        // Once a conversation title arrives, ONLY Inbox displays it with a path subtitle.
        #expect(AgentConversationTitleStore.shared.set(
            "Rebuild tab inbox", source: .native, agent: .claude, conversationID: conversation
        ))
        let namedInbox = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil, style: .inbox)
        )
        #expect(namedInbox.title == "Rebuild tab inbox")
        #expect(namedInbox.showsSubtitle)
        #expect(namedInbox.subtitle == "~/code/omg-agent-inbox")

        let pureChrome = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil, style: .chrome)
        )
        #expect(pureChrome.title == "omg-agent-inbox")
        #expect(pureChrome.subtitle == nil)
        #expect(controller.presentedTerminalTitle(for: surface, terminalTitle: "") != "Rebuild tab inbox")

        let picker = TerminalWorkspacePickerModel(controller: controller, dismiss: { $0() }, reopen: {})
        #expect(picker.movingTabTitle != "Rebuild tab inbox")
        #expect(controller.initialTabRenameValue().isEmpty)
        #expect(controller.tabRenamePlaceholder() == "omg-agent-inbox")
    }

    @Test @MainActor func manualOverridesNotifyPresentationWithoutInvalidatingShell() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = nil
        surface.pwd = NSHomeDirectory()

        var shellInvalidations = 0
        var presentationNotifications = 0
        var cancellables = Set<AnyCancellable>()
        controller.objectWillChange
            .sink { _ in shellInvalidations += 1 }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .ghosttyTabPresentationDidChange)
            .filter { ($0.object as? BaseTerminalController) === controller }
            .sink { _ in presentationNotifications += 1 }
            .store(in: &cancellables)

        controller.titleOverride = "API Server"
        #expect(shellInvalidations == 0)
        #expect(presentationNotifications == 1)
        #expect(controller.initialTabRenameValue() == "API Server")

        controller.titleOverride = nil
        #expect(shellInvalidations == 0)
        #expect(presentationNotifications == 2)

        // Surface-level manual override (`hasUserSetTitle`) is honored when tab override is nil.
        surface.titleOverride = "Pane Override"
        #expect(presentationNotifications == 3)
        let chrome = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil, style: .chrome)
        )
        let inbox = try #require(
            TerminalTabPresentationResolver.resolve(controller, index: 1, selected: true, activities: nil, style: .inbox)
        )
        #expect(chrome.title == "Pane Override")
        #expect(chrome.subtitle == nil)
        #expect(inbox.title == "Pane Override")
        #expect(inbox.subtitle == "~")
        #expect(controller.initialTabRenameValue() == "Pane Override")

        // Home folder basename is never mistaken for an Agent OSC topic.
        let homeFolder = (NSHomeDirectory() as NSString).lastPathComponent
        #expect(TerminalTabPresentationResolver.sessionName(
            fromTerminalTitle: "✳ \(homeFolder)", agent: .claude, directory: "~"
        ) == nil)
        #expect(TerminalTabPresentationResolver.sessionName(
            fromTerminalTitle: "\(homeFolder) | \(homeFolder)", agent: .codex, directory: "~"
        ) == nil)
    }
}
