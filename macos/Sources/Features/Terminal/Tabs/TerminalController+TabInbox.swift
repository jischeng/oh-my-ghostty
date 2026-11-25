import AppKit

/// When a tab counts as used by the user. Recently used ordering lists tabs by
/// real terminal input, Quick Input submission, or meaningful agent activity —
/// never by passive tab selection, viewing, or leaving.
struct TabInteractionTracker {
    /// Throttles repeated stamps against synthetic future dates.
    static let typingInterval: TimeInterval = 5

    /// Whether terminal input at `now` moves the interaction date. `last` is
    /// `tabLastInteractionAt`, `createdAt` is `tabCreatedAt`, `recency` is the
    /// date Recently Used orders the tab by, and `newestOther` is the highest
    /// recency date among the other tabs in the group.
    static func typingStamps(
        at now: Date,
        createdAt: Date = .distantPast,
        last: Date,
        recency: Date,
        newestOther: @autoclosure () -> Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard now > last else { return false }
        // First real input after session creation always records interaction.
        if last <= createdAt { return true }
        // Date sections are calendar days: the first input of a day counts.
        guard calendar.isDate(recency, inSameDayAs: now) else { return true }
        // Already the sole most-recent tab: a newer date would move nothing.
        guard let other = newestOther(), other >= recency else { return false }
        return now >= other || now.timeIntervalSince(last) >= typingInterval
    }
}

extension TerminalController {
    // MARK: Shortcut order

    /// True while the inbox order is the one on screen. `goto_tab` and the
    /// shortcut labels then count its rows; with the sidebar hidden, in the
    /// horizontal layout, or before a sidebar listed the inbox, they keep
    /// the native order.
    var tabShortcutsFollowInbox: Bool {
        OhMyGhosttySettings.shared.tabSidebarViewMode == .inbox && tabLayout == .vertical &&
            tabLayoutState.isSidebarVisible && !tabLayoutState.inboxDisplayOrder.isEmpty
    }

    /// `tabs` in the order `goto_tab` counts them: the inbox rows from the
    /// top, tabs of collapsed sections included, or `tabs` unchanged.
    func tabsInShortcutOrder(_ tabs: [TerminalController]) -> [TerminalController] {
        guard tabShortcutsFollowInbox else { return tabs }
        let live = Set(tabs.map(ObjectIdentifier.init))
        let displayed = tabLayoutState.inboxDisplayOrder.controllers.filter { live.contains(ObjectIdentifier($0)) }
        guard !displayed.isEmpty else { return tabs }
        let listed = Set(displayed.map(ObjectIdentifier.init))
        // A tab the sidebar has not listed yet follows the listed ones.
        return displayed + tabs.filter { !listed.contains(ObjectIdentifier($0)) }
    }

    func tabWindowsInShortcutOrder(_ windows: [NSWindow]) -> [NSWindow] {
        guard tabShortcutsFollowInbox else { return windows }
        let controllers = windows.compactMap { $0.windowController as? TerminalController }
        guard controllers.count == windows.count else { return windows }
        let ordered = tabsInShortcutOrder(controllers).compactMap(\.window)
        return ordered.count == windows.count ? ordered : windows
    }

    // MARK: Interaction

    /// The date the inbox orders this tab by when it lists recently used tabs first.
    var tabInboxRecency: Date {
        TabInboxModel.recency(createdAt: tabCreatedAt, lastInteractionAt: tabLastInteractionAt,
                              lastAgentActivityAt: tabLastAgentActivityAt)
    }

    /// Key and mouse presses on this tab's terminals arrive here. Only key
    /// input makes the tab recently used; a click may just have focused a pane.
    func noteTabInteractionFromUserInput() {
        guard NSApp.currentEvent?.type == .keyDown else { return }
        noteTerminalInput()
    }

    /// Real user terminal input (`keyDown`, `insertText`, paste, or Quick Input
    /// submission) into one of this tab's terminals.
    func noteTerminalInput(at now: Date = Date()) {
        guard TabInteractionTracker.typingStamps(
            at: now, createdAt: tabCreatedAt, last: tabLastInteractionAt, recency: tabInboxRecency,
            newestOther: tabControllers.lazy.filter { $0 !== self }.map { $0.tabInboxRecency }.max()
        ) else { return }
        stampTabInteraction(at: now)
    }

    func noteTabTyping(at now: Date = Date()) {
        noteTerminalInput(at: now)
    }

    /// Records meaningful agent activity state transitions (`working` start or
    /// `done`/`needsAttention`/`error` arrival). Clearing or acknowledging back
    /// to `.idle` or `nil` never stamps recency.
    func noteTabAgentActivityTransition(
        from previous: TabActivityState?,
        to next: TabActivityState?,
        at now: Date = Date()
    ) {
        guard TabInboxModel.shouldRecordAgentActivityTransition(from: previous, to: next) else { return }
        recordTabAgentActivity(at: now)
    }

    private func stampTabInteraction(at date: Date) {
        recordTabInteraction(at: date)
        // Saved with the tab, like its creation date, at the next natural
        // checkpoint. A keystroke never forces a session write of its own.
        invalidateRestorableState()
    }
}
