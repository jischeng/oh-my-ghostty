import AppKit

/// When a tab counts as used by the user. The inbox lists recently used tabs
/// first, and a tab must not jump to the top just because it was selected.
struct TabInteractionTracker {
    /// Typing moves a tab's interaction date at most this often.
    static let typingInterval: TimeInterval = 5
    /// A tab selected for less than this was passed through, not visited:
    /// restoring a session or attaching a new tab selects tabs for an instant.
    static let visitInterval: TimeInterval = 1

    /// System uptime at which the tab became the selected one.
    private(set) var selectedSince: TimeInterval?

    /// Records a change of the selected tab. True when the user leaves this
    /// tab after a visit.
    mutating func selectionChanged(wasSelected: Bool, isSelected: Bool, uptime: TimeInterval) -> Bool {
        if isSelected {
            if !wasSelected || selectedSince == nil { selectedSince = uptime }
            return false
        }
        let since = selectedSince
        selectedSince = nil
        guard wasSelected, let since else { return false }
        return uptime - since >= Self.visitInterval
    }

    /// Whether typing at `now` moves the interaction date. `last` is that
    /// date, `recency` the date the inbox orders the tab by and `newestOther`
    /// the same for the most recent other tab.
    static func typingStamps(
        at now: Date,
        last: Date,
        recency: Date,
        newestOther: @autoclosure () -> Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard now.timeIntervalSince(last) >= typingInterval else { return false }
        // Date sections are calendar days: the first typing of a day counts.
        guard calendar.isDate(recency, inSameDayAs: now) else { return true }
        // Already the most recent tab: a newer date would move nothing.
        guard let other = newestOther() else { return false }
        return other >= recency
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

    /// Key and mouse presses on this tab's terminals arrive here. Only typing
    /// makes the tab recently used; a click may just have focused a pane.
    func noteTabInteractionFromUserInput() {
        guard NSApp.currentEvent?.type == .keyDown else { return }
        noteTabTyping()
    }

    /// The user typed into one of this tab's terminals. Most keystrokes
    /// change nothing: the date moves at most every few seconds, and only
    /// when that changes the tab's place or date section.
    func noteTabTyping(at now: Date = Date()) {
        guard TabInteractionTracker.typingStamps(
            at: now, last: tabLastInteractionAt, recency: tabInboxRecency,
            newestOther: tabControllers.lazy.filter { $0 !== self }.map { $0.tabInboxRecency }.max()
        ) else { return }
        stampTabInteraction(at: now)
    }

    /// The selected tab of this tab's group changed. Leaving a tab after a
    /// visit makes it recently used; becoming selected does not.
    func noteTabSelectionChanged(
        from old: ObjectIdentifier?,
        to new: ObjectIdentifier?,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        now: Date = Date()
    ) {
        let own = ObjectIdentifier(self)
        // Without a selection the window is going away; that is not leaving.
        let left = tabInteraction.selectionChanged(
            wasSelected: old == own && new != nil, isSelected: new == own, uptime: uptime)
        if left { stampTabInteraction(at: now) }
    }

    private func stampTabInteraction(at date: Date) {
        recordTabInteraction(at: date)
        // Saved with the tab, like its creation date, at the next natural
        // checkpoint. A keystroke never forces a session write of its own.
        invalidateRestorableState()
    }
}
