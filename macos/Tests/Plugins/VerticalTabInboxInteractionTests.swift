import AppKit
import Combine
import Testing
@testable import Ghostty

/// What makes a tab "recently used" for the inbox, and how that date is saved.
@Suite(.serialized) @MainActor
struct VerticalTabInboxInteractionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }

    private func terminal(created: Date? = nil) throws -> TerminalController {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        return TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical, tabCreatedAt: created)
    }

    private func close(_ controllers: [TerminalController]) {
        for controller in controllers {
            controller.window?.delegate = nil
            controller.window?.close()
        }
    }

    @Test func aVisitCountsOnlyWhenTheTabIsLeftAfterStayingOnIt() {
        let visit = TabInteractionTracker.visitInterval
        var tracker = TabInteractionTracker()
        // Changes among other tabs are none of this tab's business.
        let stamped1 = tracker.selectionChanged(wasSelected: false, isSelected: false, uptime: 50)
        #expect(!stamped1)
        #expect(tracker.selectedSince == nil)

        // Becoming the selected tab is not an interaction.
        let stamped2 = tracker.selectionChanged(wasSelected: false, isSelected: true, uptime: 100)
        #expect(!stamped2)
        #expect(tracker.selectedSince == 100)
        // Restoring a session and attaching tabs select a tab for an instant.
        let stamped3 = tracker.selectionChanged(wasSelected: true, isSelected: false, uptime: 100 + visit / 2)
        #expect(!stamped3)
        #expect(tracker.selectedSince == nil)

        let stamped4 = tracker.selectionChanged(wasSelected: false, isSelected: true, uptime: 200)
        #expect(!stamped4)
        // A repeated report does not restart the visit.
        let stamped5 = tracker.selectionChanged(wasSelected: true, isSelected: true, uptime: 200 + visit / 2)
        #expect(!stamped5)
        #expect(tracker.selectedSince == 200)
        let stamped6 = tracker.selectionChanged(wasSelected: true, isSelected: false, uptime: 200 + visit)
        #expect(stamped6)
        // Leaving is reported once.
        let stamped7 = tracker.selectionChanged(wasSelected: true, isSelected: false, uptime: 400)
        #expect(!stamped7)
    }

    @Test func typingIsThrottledAndOnlyStampsWhenItMovesTheTab() throws {
        let interval = TabInteractionTracker.typingInterval
        let last = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 10)))
        func stamps(after seconds: TimeInterval, recency: Date? = nil, other: Date?) -> Bool {
            TabInteractionTracker.typingStamps(
                at: last.addingTimeInterval(seconds), last: last, recency: recency ?? last,
                newestOther: other, calendar: calendar)
        }
        // Never twice within the interval, even below a more recent tab.
        #expect(!stamps(after: 0, other: last.addingTimeInterval(1)))
        #expect(!stamps(after: interval - 0.1, other: last.addingTimeInterval(1)))
        // Afterwards only below another tab, or level with it.
        #expect(stamps(after: interval, other: last.addingTimeInterval(1)))
        #expect(stamps(after: 60, other: last))
        // Already the most recent tab: every later keystroke changes nothing.
        #expect(!stamps(after: 60, other: last.addingTimeInterval(-1)))
        #expect(!stamps(after: 3_600, other: nil))
        // An agent's activity put the tab on top without the user typing.
        #expect(!stamps(after: 60, recency: last.addingTimeInterval(30), other: last.addingTimeInterval(10)))
        // The first typing of a new day moves the tab to Today.
        #expect(stamps(after: 14 * 3_600, other: nil))
        #expect(stamps(after: 14 * 3_600, other: last.addingTimeInterval(-1)))

        // The other tabs are not looked at while typing is throttled.
        var asked = 0
        func newest() -> Date? { asked += 1; return nil }
        _ = TabInteractionTracker.typingStamps(at: last.addingTimeInterval(1), last: last, recency: last,
                                               newestOther: newest(), calendar: calendar)
        #expect(asked == 0)
    }

    @Test func selectingATabDoesNotStampItButLeavingAfterAVisitDoes() throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let controller = try terminal(created: created)
        let neighbour = try terminal()
        defer { close([controller, neighbour]) }
        let own = ObjectIdentifier(controller)
        let other = ObjectIdentifier(neighbour)
        let visit = TabInteractionTracker.visitInterval
        func at(_ seconds: TimeInterval) -> Date { created.addingTimeInterval(seconds) }

        // A tab without a saved date was last used when it was created.
        #expect(controller.tabLastInteractionAt == created)

        // Activation still dates the Tabs view's recently used order, and only that.
        let activated = controller.tabLastActivatedAt
        controller.markTabActivated()
        #expect(controller.tabLastActivatedAt >= activated)
        #expect(controller.tabLastInteractionAt == created)

        // Becoming selected, and being passed through, stamp nothing.
        controller.noteTabSelectionChanged(from: other, to: own, uptime: 1_000, now: at(10))
        #expect(controller.tabLastInteractionAt == created)
        controller.noteTabSelectionChanged(from: own, to: other, uptime: 1_000 + visit / 2, now: at(11))
        #expect(controller.tabLastInteractionAt == created)

        // Visited and left.
        controller.noteTabSelectionChanged(from: other, to: own, uptime: 2_000, now: at(20))
        #expect(controller.tabLastInteractionAt == created)
        controller.noteTabSelectionChanged(from: own, to: other, uptime: 2_000 + visit, now: at(30))
        #expect(controller.tabLastInteractionAt == at(30))
        #expect(TabInboxModel.item(for: controller).lastInteractionAt == at(30))

        // A window that goes away is not a tab the user left.
        controller.noteTabSelectionChanged(from: other, to: own, uptime: 3_000, now: at(40))
        controller.noteTabSelectionChanged(from: own, to: nil, uptime: 4_000, now: at(50))
        #expect(controller.tabLastInteractionAt == at(30))
        // Nor is another tab losing the selection.
        controller.noteTabSelectionChanged(from: other, to: nil, uptime: 5_000, now: at(60))
        #expect(controller.tabLastInteractionAt == at(30))
    }

    @Test func realTabSwitchStampsTheTabThatWasLeftNotTheOneSelected() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        let group = try #require(first.window?.tabGroup)

        // Start a visit of the first tab, whichever tab the fixture left selected.
        first.selectVerticalTab(first)
        try #require(group.selectedWindow === first.window)
        let firstBefore = first.tabLastInteractionAt
        // Selecting again right away is passing through: nothing is stamped.
        first.selectVerticalTab(second)
        try #require(group.selectedWindow === second.window)
        #expect(first.tabLastInteractionAt == firstBefore)
        first.selectVerticalTab(first)
        #expect(first.tabLastInteractionAt == firstBefore)

        try await Task.sleep(for: .seconds(TabInteractionTracker.visitInterval + 0.2))
        let secondBefore = second.tabLastInteractionAt
        let left = Date()
        first.selectVerticalTab(second)
        try #require(group.selectedWindow === second.window)
        #expect(first.tabLastInteractionAt >= left)
        // The tab the user arrived at keeps its place.
        #expect(second.tabLastInteractionAt == secondBefore)
    }

    @Test func typingMovesTheDateOnlyBelowAnotherTabAndAtMostEveryFewSeconds() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        first.selectVerticalTab(first)
        try #require(first.tabControllers.contains { $0 === second })
        try #require(second.tabControllers.contains { $0 === first })
        let interval = TabInteractionTracker.typingInterval
        // Dates from here on, later than anything the fixture stamped.
        let start = Date().addingTimeInterval(10)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        // Around midnight the first typing of a day stamps by design.
        guard Calendar.current.isDate(at(300), inSameDayAs: first.tabCreatedAt) else { return }
        second.recordTabInteraction(at: at(0))

        // The most recent tab stays where it is, whatever is typed into it.
        second.noteTabTyping(at: at(60))
        #expect(second.tabLastInteractionAt == at(0))

        // The tab below it moves up with the first keystroke.
        first.noteTabTyping(at: at(60))
        #expect(first.tabLastInteractionAt == at(60))
        #expect(first.tabInboxRecency > second.tabInboxRecency)

        // Another tab took the top again; typing is still throttled.
        second.recordTabInteraction(at: at(61))
        first.noteTabTyping(at: at(62))
        first.noteTabTyping(at: at(60 + interval - 0.5))
        #expect(first.tabLastInteractionAt == at(60))
        first.noteTabTyping(at: at(60 + interval + 0.5))
        #expect(first.tabLastInteractionAt == at(60 + interval + 0.5))

        // On top again: nothing is published for further keystrokes.
        var published = 0
        let observation = first.$tabLastInteractionAt.dropFirst().sink { _ in published += 1 }
        defer { observation.cancel() }
        for seconds in stride(from: 100.0, through: 200.0, by: 10) { first.noteTabTyping(at: at(seconds)) }
        #expect(published == 0)
        #expect(first.tabLastInteractionAt == at(60 + interval + 0.5))
    }

    @Test func interactionDateIsSavedWithTheTabAndOlderStateFallsBackToCreation() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let used = Date(timeIntervalSince1970: 1_790_050_000)
        let original = try terminal(created: created)
        var restored: [TerminalController] = []
        defer { close([original] + restored) }
        original.recordTabInteraction(at: used)

        // The workspace session, as written to disk.
        let archive = TerminalWorkspaceSessionState(original)
        #expect(archive.tabCreatedAt == created)
        #expect(archive.tabLastInteractionAt == used)
        let data = try JSONEncoder().encode(archive)
        let reread = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: data)
        #expect(reread.tabLastInteractionAt == used)
        #expect(reread.tabCreatedAt == created)
        #expect(reread.tabSessionID == archive.tabSessionID)
        let state = try archive.instantiate(restoreSessions: false)
        #expect(state.tabLastInteractionAt == used)
        let current = TerminalController(app, withSurfaceTree: state.surfaceTree, tabCreatedAt: state.tabCreatedAt,
                                         tabLastInteractionAt: state.tabLastInteractionAt)
        restored.append(current)
        #expect(current.tabCreatedAt == created)
        #expect(current.tabLastInteractionAt == used)
        #expect(TerminalWorkspaceSessionState(current).tabLastInteractionAt == used)

        // State saved before the field existed has no such key and still decodes.
        var older = archive
        older.tabLastInteractionAt = nil
        let olderData = try JSONEncoder().encode(older)
        func keys(_ json: Data) throws -> Set<String> {
            Set(try #require(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys)
        }
        #expect(try keys(data).contains("tabLastInteractionAt"))
        #expect(try !keys(olderData).contains("tabLastInteractionAt"))
        let decoded = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: olderData)
        #expect(decoded.tabLastInteractionAt == nil)
        #expect(decoded.tabCreatedAt == created)
        let olderState = try decoded.instantiate(restoreSessions: false)
        #expect(olderState.tabLastInteractionAt == nil)
        let legacy = TerminalController(app, withSurfaceTree: olderState.surfaceTree,
                                        tabCreatedAt: olderState.tabCreatedAt,
                                        tabLastInteractionAt: olderState.tabLastInteractionAt)
        restored.append(legacy)
        #expect(legacy.tabLastInteractionAt == created)

        // The native window restoration state carries it too.
        #expect(TerminalRestorableState(from: original).tabLastInteractionAt == used)
        #expect(TerminalRestorableState(from: legacy).tabLastInteractionAt == created)
    }

    @Test func presentationNotificationRefreshesInboxRowWithoutStampingInteractionDate() async throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let controller = try terminal(created: created)
        defer { close([controller]) }
        let tab = GhosttyOrganizedTab(controller: controller, actualIndex: 1)
        let row = NativeInboxRowView(frame: NSRect(x: 0, y: 0, width: 234, height: 34))
        row.configure(tab: tab, selected: true, canClose: false) { item in
            let name = item.controller.titleOverride
            return GhosttyTabPresentation(
                title: name ?? "~/code/project",
                remoteBreadcrumb: nil,
                subtitle: name == nil ? nil : "~/code/project",
                shortcut: "⌘1",
                icon: .systemSymbol("terminal"),
                activity: nil,
                selected: true,
                hovered: false
            )
        }
        row.layoutSubtreeIfNeeded()
        #expect(row.preferredHeight == 34)
        #expect(!row.showsSubtitle)
        #expect(controller.tabLastInteractionAt == created)

        controller.titleOverride = "Fix sidebar pills"
        NotificationCenter.default.post(
            name: Notification.Name("GhosttyTabPresentationDidChange"),
            object: controller
        )
        try await Task.sleep(for: .milliseconds(30))
        row.layoutSubtreeIfNeeded()
        #expect(row.showsSubtitle)
        #expect(row.preferredHeight == 48)
        #expect(row.titleLabel.stringValue == "Fix sidebar pills")
        #expect(row.subtitleLabel.stringValue == "~/code/project")
        #expect(controller.tabLastInteractionAt == created)
    }
}
