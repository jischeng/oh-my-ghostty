import Foundation
import Testing
@testable import Ghostty

@MainActor
struct QuickInputGlobalPresentationTests {
    @Test func showDismissAndPinAreGlobalButDraftsRemainIndependent() {
        let global = QuickInputGlobalPresentation()
        let first = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let second = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let firstPane = UUID()
        let secondPane = UUID()
        first.bindGlobalTarget { firstPane }
        second.bindGlobalTarget { secondPane }
        first.present(for: firstPane)
        #expect(first.isPresented && second.isPresented && global.isPresented)
        #expect(second.targetSurfaceID == secondPane)
        first.draft = "first draft"
        second.draft = "second draft"
        first.togglePinned()
        #expect(first.isPinned && second.isPinned && global.isPinned)
        first.completeSubmission(clearDraft: true)
        #expect(first.isPresented && second.isPresented)
        #expect(first.draft.isEmpty && second.draft == "second draft")
        second.dismiss()
        #expect(!first.isPresented && !second.isPresented && !global.isPresented)
        #expect(first.isPinned && second.isPinned)
        let third = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let thirdPane = UUID()
        third.bindGlobalTarget { thirdPane }
        #expect(!third.isPresented && third.isPinned)
        second.present(for: secondPane)
        #expect(first.isPresented && second.isPresented && third.isPresented)
        #expect(second.draft == "second draft")
        third.togglePinned()
        #expect(!first.isPinned && !second.isPinned && !third.isPinned)
        second.completeSubmission(clearDraft: false)
        #expect(!first.isPresented && !second.isPresented && !third.isPresented)
    }

    @Test func newTabInheritsVisibilityAndRemovingPaneDoesNotCloseOtherTabs() {
        let global = QuickInputGlobalPresentation()
        let firstPane = UUID()
        let first = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        first.bindGlobalTarget { firstPane }
        first.present(for: firstPane)
        let second = AgentQuickInputModel(dockHeight: 252, globalPresentation: global)
        let secondPane = UUID()
        second.bindGlobalTarget { secondPane }
        #expect(second.isPresented && second.targetSurfaceID == secondPane)
        second.removeState(for: secondPane)
        #expect(global.isPresented && first.isPresented)
        var focusedPane = UUID()
        second.bindGlobalTarget { focusedPane }
        #expect(second.isPresented && second.targetSurfaceID == focusedPane)
        second.draft = "previous pane draft"
        let previous = focusedPane
        focusedPane = UUID()
        second.bindGlobalTarget { focusedPane }
        #expect(second.targetSurfaceID == focusedPane && second.draft.isEmpty)
        #expect(second.state(for: previous)?.draft == "previous pane draft")
        first.dismiss()
        #expect(!second.isPresented)
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
