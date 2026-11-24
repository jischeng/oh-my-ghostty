import Foundation
import Testing
@testable import Ghostty

@MainActor
struct QuickInputGlobalPresentationTests {
    @Test func visibilityIsTabScopedWhilePinHeightAndDraftsFollowTheirScopes() {
        let global = QuickInputGlobalPresentation()
        let first = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let second = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let firstPane = UUID()
        let secondPane = UUID()
        first.bindGlobalTarget { firstPane }
        second.bindGlobalTarget { secondPane }
        first.present(for: firstPane)
        #expect(first.isPresented)
        #expect(!second.isPresented)
        #expect(first.targetSurfaceID == firstPane)
        #expect(first.focusRequestSurfaceID == firstPane)

        first.draft = "first draft"
        second.present(for: secondPane)
        second.draft = "second draft"
        first.togglePinned()
        #expect(first.isPinned && second.isPinned && global.isPinned)
        first.completeSubmission(clearDraft: true)
        #expect(first.isPresented && second.isPresented)
        #expect(first.draft.isEmpty && second.draft == "second draft")

        second.dismiss()
        #expect(first.isPresented)
        #expect(!second.isPresented)
        #expect(first.isPinned && second.isPinned)

        let third = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let thirdPane = UUID()
        third.bindGlobalTarget { thirdPane }
        #expect(!third.isPresented && third.isPinned)

        third.togglePinned()
        #expect(!first.isPinned && !second.isPinned && !third.isPinned)
        first.completeSubmission(clearDraft: false)
        #expect(!first.isPresented)
    }

    @Test func switchingSplitsWithinOpenTabMovesTargetWithoutStealingFocus() {
        let global = QuickInputGlobalPresentation()
        let tab = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let leftPane = UUID()
        let rightPane = UUID()
        var focusedPane = leftPane
        tab.bindGlobalTarget { focusedPane }
        tab.present(for: leftPane, requestFocus: true)
        #expect(tab.isPresented)
        #expect(tab.targetSurfaceID == leftPane)
        #expect(tab.focusRequestSurfaceID == leftPane)
        tab.draft = "left draft"

        // Switching to right pane moves the docked Quick Input without stealing terminal focus.
        focusedPane = rightPane
        tab.bindGlobalTarget { focusedPane }
        #expect(tab.isPresented)
        #expect(tab.targetSurfaceID == rightPane)
        #expect(tab.focusRequestSurfaceID == nil)
        #expect(tab.draft.isEmpty)
        #expect(tab.state(for: leftPane)?.draft == "left draft")

        // Removing the active pane closes Quick Input cleanly on that tab.
        tab.removeState(for: rightPane)
        #expect(!tab.isPresented)
        #expect(tab.targetSurfaceID == nil)
    }

    @Test func reopeningHistoryKeepsSelectionAndHoverIsKeyboardSelectionWithoutScrolling() {
        let store = QuickInputHistoryStore()
        let pane = UUID()
        let tab = UUID()
        for text in ["oldest", "middle", "newest"] { store.record(text, paneID: pane, tabID: tab) }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let presentation = QuickInputHistoryPresentation()
        presentation.open(entries: entries)
        #expect(presentation.selectedID == entries[0].id)
        presentation.moveSelection(by: 1, entries: entries)
        presentation.close()
        presentation.open(entries: entries)
        #expect(presentation.selectedID == entries[1].id)
        let scrollRevision = presentation.keyboardSelectionRevision
        presentation.hover(entries[2].id)
        #expect(presentation.selectedID == entries[2].id)
        #expect(presentation.keyboardSelectionRevision == scrollRevision)
        presentation.moveSelection(by: -1, entries: entries)
        #expect(presentation.selectedID == entries[1].id)
        #expect(presentation.keyboardSelectionRevision > scrollRevision)
        presentation.select(entries[2].id)
        presentation.close()
        presentation.open(entries: entries)
        #expect(presentation.selectedID == entries[2].id)
        presentation.close()
        presentation.open(entries: [entries[0]])
        #expect(presentation.selectedID == entries[0].id)
    }
}
