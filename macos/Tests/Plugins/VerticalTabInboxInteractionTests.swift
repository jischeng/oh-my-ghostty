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

    @Test func typingStampsImmediatelyWhenOvertakingAndAvoidsTopTabChurn() throws {
        let interval = TabInteractionTracker.typingInterval
        let created = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9)))
        let last = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 10)))
        func stamps(after seconds: TimeInterval, createdAt: Date? = nil, recency: Date? = nil, other: Date?) -> Bool {
            TabInteractionTracker.typingStamps(
                at: last.addingTimeInterval(seconds), createdAt: createdAt ?? created,
                last: last, recency: recency ?? last, newestOther: other, calendar: calendar
            )
        }
        // Non-advancing timestamps never stamp.
        #expect(!stamps(after: 0, other: last.addingTimeInterval(1)))
        // First real input after session creation always stamps immediately.
        #expect(stamps(after: 0.2, createdAt: last, other: nil))
        // Moving a lower tab to or above `other` stamps immediately without a 5s dead zone.
        #expect(stamps(after: 1.5, other: last.addingTimeInterval(1)))
        #expect(stamps(after: 60, other: last))
        // Synthetic future `other` dates remain throttled by typingInterval.
        #expect(!stamps(after: 1, other: last.addingTimeInterval(10)))
        #expect(stamps(after: interval, other: last.addingTimeInterval(10)))
        // Already the sole most-recent tab today: further keystrokes publish nothing.
        #expect(!stamps(after: 60, other: last.addingTimeInterval(-1)))
        #expect(!stamps(after: 3_600, other: nil))
        // An agent's activity put the tab on top without the user typing.
        #expect(!stamps(after: 60, recency: last.addingTimeInterval(30), other: last.addingTimeInterval(10)))
        // The first input of a new day moves the tab to Today.
        #expect(stamps(after: 14 * 3_600, other: nil))
        #expect(stamps(after: 14 * 3_600, other: last.addingTimeInterval(-1)))
    }

    @Test func passiveSelectionAndViewingOverTwoSecondsLeavesRecencyUnchangedInInboxAndTabs() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        try await Task.sleep(for: .milliseconds(20))
        let second = try fixture.tab(parent: first)
        try await Task.sleep(for: .milliseconds(20))
        let third = try fixture.tab(parent: first)
        let controllers = [first, second, third]
        let group = try #require(first.window?.tabGroup)

        let firstBefore = first.tabLastInteractionAt
        let secondBefore = second.tabLastInteractionAt
        let thirdBefore = third.tabLastInteractionAt
        #expect(firstBefore == first.tabCreatedAt)
        #expect(secondBefore == second.tabCreatedAt)
        #expect(thirdBefore == third.tabCreatedAt)

        func inboxOrder() -> [Int] {
            TabInboxModel.groups(
                tabs: controllers, grouping: .none, ordering: .recentlyUsed
            ).flatMap(\.tabs).map(\.actualIndex)
        }
        func tabsOrder() -> [Int] {
            GhosttyTabOrganizationModel().groups(
                tabs: controllers, grouping: .none, ordering: .recentlyUsed
            ).flatMap(\.tabs).map(\.actualIndex)
        }
        #expect(inboxOrder() == [3, 2, 1])
        #expect(tabsOrder() == [3, 2, 1])

        // Select the oldest tab, dwell for >2s without typing, then switch away.
        first.selectVerticalTab(first)
        first.markTabActivated()
        try #require(group.selectedWindow === first.window)
        try await Task.sleep(for: .milliseconds(2_100))

        first.selectVerticalTab(second)
        second.markTabActivated()
        try #require(group.selectedWindow === second.window)

        #expect(first.tabLastInteractionAt == firstBefore)
        #expect(second.tabLastInteractionAt == secondBefore)
        #expect(third.tabLastInteractionAt == thirdBefore)
        #expect(inboxOrder() == [3, 2, 1])
        #expect(tabsOrder() == [3, 2, 1])
    }

    @Test func terminalInputAndQuickInputMoveTabToTopOfRecentlyUsedInInboxAndTabs() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        try await Task.sleep(for: .milliseconds(20))
        let second = try fixture.tab(parent: first)
        try await Task.sleep(for: .milliseconds(20))
        let third = try fixture.tab(parent: first)
        let controllers = [first, second, third]
        for controller in controllers {
            if let surface = controller.surfaceTree.first {
                surface.runtimeDescriptor = nil
                surface.runtimeInlineSession = nil
            }
        }

        func inboxOrder() -> [Int] {
            TabInboxModel.groups(
                tabs: controllers, grouping: .none, ordering: .recentlyUsed
            ).flatMap(\.tabs).map(\.actualIndex)
        }
        func tabsOrder() -> [Int] {
            GhosttyTabOrganizationModel().groups(
                tabs: controllers, grouping: .none, ordering: .recentlyUsed
            ).flatMap(\.tabs).map(\.actualIndex)
        }
        #expect(inboxOrder() == [3, 2, 1])
        #expect(tabsOrder() == [3, 2, 1])

        // 1. Typing / insertText in the first tab moves it to the top of both .inbox and .tabs.
        let firstBefore = first.tabLastInteractionAt
        let firstSurface = try #require(first.surfaceTree.first)
        firstSurface.insertText("echo hello\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(first.tabLastInteractionAt > firstBefore)
        #expect(inboxOrder() == [1, 3, 2])
        #expect(tabsOrder() == [1, 3, 2])

        // 2. Quick Input submission in the second tab updates tabLastInteractionAt and moves it to the top.
        let secondBefore = second.tabLastInteractionAt
        let secondSurface = try #require(second.surfaceTree.first)
        if !ProgrammaticInputGuard.isGlobalSecureInputActive {
            var completed = false
            let submitted = second.submitQuickInputText(
                "pwd",
                to: secondSurface.id,
                restoreFocus: false
            ) {
                completed = true
            }
            #expect(submitted)
            for _ in 0..<50 where !completed {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(completed)
        } else {
            second.noteTerminalInput()
        }
        #expect(second.tabLastInteractionAt > secondBefore)
        #expect(inboxOrder() == [2, 1, 3])
        #expect(tabsOrder() == [2, 1, 3])
    }

    @Test func typingMovesTheDateOnlyBelowAnotherTabAndAvoidsTopTabSpam() throws {
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

        // Already the most recent tab after initial interaction: further keystrokes keep its date.
        second.noteTerminalInput(at: at(60))
        #expect(second.tabLastInteractionAt == at(0))

        // The tab below it moves up immediately with the first keystroke.
        first.noteTerminalInput(at: at(60))
        #expect(first.tabLastInteractionAt == at(60))
        #expect(first.tabInboxRecency > second.tabInboxRecency)

        // Another tab receives a synthetic future timestamp; repeated keystrokes before `other` throttle.
        second.recordTabInteraction(at: at(70))
        first.noteTerminalInput(at: at(62))
        first.noteTerminalInput(at: at(60 + interval - 0.5))
        #expect(first.tabLastInteractionAt == at(60))
        first.noteTerminalInput(at: at(71))
        #expect(first.tabLastInteractionAt == at(71))

        // On top again: nothing is published for further keystrokes.
        var published = 0
        let observation = first.tabLastInteractionAtPublisher.dropFirst().sink { _ in published += 1 }
        defer { observation.cancel() }
        for seconds in stride(from: 100.0, through: 200.0, by: 10) { first.noteTerminalInput(at: at(seconds)) }
        #expect(published == 0)
        #expect(first.tabLastInteractionAt == at(71))
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
        let row = NativeInboxRowView(frame: NSRect(x: 0, y: 0, width: 234, height: 36))
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
        let singleLineHeight = row.preferredHeight
        #expect(singleLineHeight == 36)
        #expect(!row.showsSubtitle)
        #expect(row.shortcutLabel.isHidden)
        row.isCommandHeld = true
        #expect(!row.shortcutLabel.isHidden)
        row.isCommandHeld = false
        #expect(row.shortcutLabel.isHidden)
        #expect(controller.tabLastInteractionAt == created)

        controller.titleOverride = "Fix sidebar pills"
        NotificationCenter.default.post(
            name: Notification.Name("GhosttyTabPresentationDidChange"),
            object: controller
        )
        try await Task.sleep(for: .milliseconds(30))
        row.layoutSubtreeIfNeeded()
        #expect(row.showsSubtitle)
        #expect(row.preferredHeight > singleLineHeight)
        #expect(row.titleLabel.stringValue == "Fix sidebar pills")
        #expect(row.subtitleLabel.stringValue == "~/code/project")
        #expect(controller.tabLastInteractionAt == created)
    }
}
