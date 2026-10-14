import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct QuickInputHistoryNavigationTests {
    private let latest = QuickInputDraftSnapshot(text: "unfinished 🐱 draft", selection: NSRange(location: 3, length: 0))
    private let history = ["recent\nsecond line", "older"]

    @Test func twoPressEntryThenFastBrowsingRestoresLatestDraftAndCaret() {
        var navigation = QuickInputHistoryNavigation()
        #expect(navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false) == .consumed)
        #expect(navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: true) == .consumed)
        let first = navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false)
        #expect(first == .restore(snapshot(history[0])))
        #expect(navigation.isContinuous)
        #expect(navigation.navigate(.older, current: snapshot(history[0]), entries: history,
                                    atBoundary: false, isRepeat: true) == .restore(snapshot(history[1])))
        #expect(navigation.navigate(.older, current: snapshot(history[1]), entries: history,
                                    atBoundary: false, isRepeat: true) == .consumed)
        #expect(navigation.navigate(.newer, current: snapshot(history[1]), entries: history,
                                    atBoundary: false, isRepeat: false) == .restore(snapshot(history[0])))
        #expect(navigation.navigate(.newer, current: snapshot(history[0]), entries: history,
                                    atBoundary: false, isRepeat: false) == .restore(latest))
        #expect(navigation.navigate(.newer, current: latest, entries: history,
                                    atBoundary: true, isRepeat: false) == .consumed)
        #expect(navigation.navigate(.older, current: latest, entries: history,
                                    atBoundary: true, isRepeat: false) == .restore(snapshot(history[0])))
    }

    @Test func movementAndDirectionChangesRearmWithoutLosingSavedDraft() {
        var navigation = QuickInputHistoryNavigation()
        #expect(navigation.navigate(.older, current: latest, entries: history, atBoundary: false, isRepeat: false) == .unhandled)
        #expect(navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false) == .consumed)
        #expect(navigation.navigate(.newer, current: latest, entries: history, atBoundary: true, isRepeat: false) == .unhandled)
        #expect(navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false) == .consumed)
        #expect(navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false) == .restore(snapshot(history[0])))
        navigation.caretMoved()
        #expect(!navigation.isContinuous)
        #expect(navigation.navigate(.newer, current: snapshot(history[0]), entries: history, atBoundary: false, isRepeat: false) == .unhandled)
        #expect(navigation.navigate(.newer, current: snapshot(history[0]), entries: history, atBoundary: true, isRepeat: false) == .consumed)
        #expect(navigation.navigate(.newer, current: snapshot(history[0]), entries: history, atBoundary: true, isRepeat: false) == .restore(latest))
    }

    @Test func editingHistoryCreatesNewLatestDraftAndLeavesSentRecordUnchanged() throws {
        let model = AgentQuickInputModel(dockHeight: 252)
        let pane = UUID()
        model.present(for: pane)
        model.recordSentText("original sent", for: pane)
        model.draft = latest.text
        _ = model.navigateHistory(.older, current: latest, scope: .pane, atBoundary: true, isRepeat: false)
        _ = model.navigateHistory(.older, current: latest, scope: .pane, atBoundary: true, isRepeat: false)
        #expect(model.draft == "original sent")
        model.draft = "edited history, new draft"
        let edited = snapshot(model.draft)
        #expect(model.navigateHistory(.older, current: edited, scope: .pane, atBoundary: true, isRepeat: false) == .consumed)
        #expect(model.draft == edited.text)
        _ = model.navigateHistory(.older, current: edited, scope: .pane, atBoundary: true, isRepeat: false)
        #expect(model.draft == "original sent")
        #expect(model.navigateHistory(.newer, current: snapshot(model.draft), scope: .pane,
                                     atBoundary: false, isRepeat: false) == .restore(edited))
        #expect(model.draft == edited.text)
        #expect(model.targetHistory == ["original sent"])
        #expect(model.state(for: pane)?.draft == edited.text)
    }

    @Test func tabNavigationIncludesSiblingAndScopeChangeDoesNotLeakPaneDrafts() {
        let model = AgentQuickInputModel(dockHeight: 252)
        let pane = UUID()
        let sibling = UUID()
        model.present(for: pane)
        model.recordSentText("this pane", for: pane)
        model.recordSentText("sibling latest", for: sibling)
        model.draft = "unsent current"
        let draft = snapshot(model.draft)
        _ = model.navigateHistory(.older, current: draft, scope: .tab, atBoundary: true, isRepeat: false)
        _ = model.navigateHistory(.older, current: draft, scope: .tab, atBoundary: true, isRepeat: false)
        #expect(model.draft == "sibling latest")
        #expect(model.state(for: pane)?.draft == "unsent current")
        model.dismiss()
        model.present(for: pane)
        #expect(model.draft == "unsent current")
        model.present(for: UUID())
        #expect(model.draft.isEmpty)
        #expect(model.navigateHistory(.older, current: snapshot(""), scope: .pane,
                                     atBoundary: true, isRepeat: false) == .unhandled)
    }

    @Test func clearedHistoryReturnsNewestUnsentDraftInsteadOfBrowsingStaleSnapshot() {
        var navigation = QuickInputHistoryNavigation()
        _ = navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false)
        _ = navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false)
        #expect(navigation.navigate(.older, current: snapshot(history[0]), entries: [],
                                    atBoundary: true, isRepeat: false) == .restore(latest))
        #expect(!navigation.isContinuous)
    }

    @Test func expiredOrOutOfScopeSnapshotReturnsLatestDraftAndRearms() {
        var navigation = QuickInputHistoryNavigation()
        _ = navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false)
        _ = navigation.navigate(.older, current: latest, entries: history, atBoundary: true, isRepeat: false)
        #expect(navigation.navigate(.older, current: snapshot(history[0]), entries: [history[0]],
                                    atBoundary: false, isRepeat: false) == .restore(latest))
        #expect(!navigation.isContinuous)
        #expect(navigation.navigate(.older, current: latest, entries: [history[0]],
                                    atBoundary: true, isRepeat: false) == .consumed)
    }

    @Test func nativeBoundaryUsesWrappedLinesAndTrailingEmptyLine() {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 300))
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = NSSize(width: 80, height: 10_000)
        editor.string = "abcdefghijklmno\ntail\n"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.isOnHistoryBoundary(.older))
        #expect(!editor.isOnHistoryBoundary(.newer))
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        #expect(!editor.isOnHistoryBoundary(.older))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "tail").location, length: 0))
        #expect(!editor.isOnHistoryBoundary(.newer))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        #expect(editor.isOnHistoryBoundary(.newer))
        #expect(!editor.isOnHistoryBoundary(.older))
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(!editor.isOnHistoryBoundary(.older))
    }

    @Test func nativeSelectionNotificationsDoNotRearmContinuousBrowsing() async throws {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: UUID())
        let pane = try #require(model.targetSurfaceID)
        model.recordSentText("older", for: pane)
        model.recordSentText("recent\nsecond line", for: pane)
        model.draft = "latest\nunfinished"
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        editor.string = model.draft
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let coordinator = AgentQuickInputTextEditor.Coordinator(text: Binding(
            get: { model.draft }, set: { model.draft = $0 }
        ))
        coordinator.editor = editor
        editor.delegate = coordinator
        editor.onHistoryCaretMoved = model.historyCaretMoved
        editor.onNavigateHistory = { direction, current, boundary, repeated in
            model.navigateHistory(direction, current: current, scope: .tab,
                                  atBoundary: boundary, isRepeat: repeated)
        }
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        editor.keyDown(with: try event(126))
        #expect(model.draft == "latest\nunfinished")
        editor.keyDown(with: try event(126))
        #expect(model.draft == "recent\nsecond line")
        try await Task.sleep(for: .milliseconds(30))
        editor.keyDown(with: try event(126))
        #expect(model.draft == "older")
        editor.keyDown(with: try event(125))
        #expect(model.draft == "recent\nsecond line")
        editor.keyDown(with: try event(125))
        #expect(model.draft == "latest\nunfinished")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func nativeNavigationPreservesIMEAndModifiedArrowBehavior() throws {
        let editor = ComposerTextView()
        var calls = 0
        editor.onNavigateHistory = { _, _, _, _ in calls += 1; return .consumed }
        editor.keyDown(with: try event(126))
        #expect(calls == 1)
        editor.keyDown(with: try event(125))
        #expect(calls == 2)
        editor.keyDown(with: try event(126, modifiers: [.option]))
        #expect(calls == 2)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try event(126))
        #expect(calls == 2)
    }

    @Test func pinOnlyStopsAutomaticCloseIncludingQueueEditSave() throws {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: UUID())
        model.togglePinned()
        model.draft = "sent"
        model.completeSubmission(clearDraft: true)
        #expect(model.isPresented && model.isPinned && model.draft.isEmpty)
        model.draft = "queue me"
        let queued = try #require(model.enqueueDraft())
        model.completeSubmission(clearDraft: false)
        #expect(model.isPresented && model.targetQueue.count == 1)
        model.editQueuedItem(queued.id, for: try #require(model.targetSurfaceID))
        model.draft = "updated queued"
        #expect(model.confirmQueuedItemEdit(moveToEnd: false))
        #expect(model.isPresented)
        model.dismiss()
        #expect(!model.isPresented && model.isPinned)
        model.present(for: try #require(model.targetSurfaceID))
        model.editQueuedItem(queued.id, for: try #require(model.targetSurfaceID))
        model.dismiss()
        #expect(!model.isPresented)
        model.togglePinned()
        model.present(for: UUID())
        model.draft = "regular send"
        model.completeSubmission(clearDraft: true)
        #expect(!model.isPresented && model.draft.isEmpty)
    }

    @Test func menuInsertionModesNeverChangeStoredHistoryOrQueue() {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: UUID())
        model.draft = "existing"
        model.useHistoryText("picked", mode: .append)
        #expect(model.draft == "existing\npicked")
        model.useHistoryText("replacement", mode: .replace)
        #expect(model.draft == "replacement")
        #expect(model.targetQueue.isEmpty && model.targetHistory.isEmpty)
    }

    @Test func popupSelectionSearchEscapeAndTogglePreserveQuery() {
        let store = QuickInputHistoryStore()
        let pane = UUID()
        let tab = UUID()
        store.record("older", paneID: pane, tabID: tab)
        store.record("newest", paneID: pane, tabID: tab)
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let presentation = QuickInputHistoryPresentation()
        presentation.open(entries: entries)
        #expect(presentation.selectedID == entries[0].id)
        presentation.moveSelection(by: 1, entries: entries)
        #expect(presentation.selectedID == entries[1].id)
        presentation.moveSelection(by: -1, entries: entries)
        #expect(presentation.selectedID == entries[0].id)
        presentation.moveSelection(by: 1, entries: [entries[1]])
        #expect(presentation.selectedID == entries[1].id)
        presentation.beginSearch()
        presentation.query = "newest"
        presentation.close()
        presentation.open(entries: [entries[0]])
        #expect(presentation.query == "newest" && presentation.isSearching)
        #expect(!presentation.escape())
        #expect(presentation.isPresented && !presentation.isSearching)
        #expect(presentation.query == "newest")
        #expect(presentation.escape())
        #expect(!presentation.isPresented)
    }

    @Test func nativePopupTypingKeepsFirstCharacterAndRoutesSelectionAndShortcut() async throws {
        let editor = QuickInputHistorySearchTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        editor.isRichText = false
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        try await Task.sleep(for: .milliseconds(30))
        let presentation = QuickInputHistoryPresentation()
        let coordinator = QuickInputHistorySearchEditor.Coordinator(query: Binding(
            get: { presentation.query }, set: { presentation.query = $0 }
        ))
        editor.delegate = coordinator
        editor.onBeginSearch = { presentation.beginSearch(clearQuery: true) }
        var moved = 0
        var picked = 0
        var toggled = 0
        editor.onMove = { moved += $0 }
        editor.onSelect = { picked += 1 }
        editor.onToggle = { toggled += 1; presentation.close() }
        editor.keyDown(with: try event(0, characters: "a", windowNumber: window.windowNumber))
        editor.unmarkText()
        #expect(editor.string == "a")
        #expect(presentation.isSearching)
        #expect(presentation.query == "a")
        editor.keyDown(with: try event(125))
        #expect(moved == 1)
        editor.keyDown(with: try event(36, characters: "\r"))
        #expect(picked == 1)
        #expect(editor.performKeyEquivalent(with: try event(4, modifiers: [.command, .shift], characters: "h")))
        #expect(toggled == 1 && presentation.query == "a")
    }

    @Test func collapsedPopupNativeInputEntersSearchWithoutLosingFirstCharacter() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        model.present(for: pane)
        store.record("alpha", paneID: pane, tabID: model.historyTabID)
        model.toggleHistory(scope: .tab)
        let host = NSHostingView(rootView: QuickInputHistoryView(model: model, store: store, settings: settings) { _ in })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        host.display()
        try await Task.sleep(for: .milliseconds(60))
        func find(_ view: NSView) -> QuickInputHistorySearchTextView? {
            (view as? QuickInputHistorySearchTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let editor = try #require(find(host))
        #expect(!model.historyPresentation.isSearching)
        #expect(window.makeFirstResponder(editor))
        editor.keyDown(with: try event(0, characters: "a", windowNumber: window.windowNumber))
        editor.unmarkText()
        #expect(model.historyPresentation.isSearching)
        #expect(model.historyPresentation.query == "a")
        #expect(editor.string == "a")
    }

    @Test func closedHistoryCannotStealBackFocusFromComposer() async throws {
        var isOpen = false
        let search = QuickInputHistorySearchTextView(frame: .init(x: 0, y: 0, width: 300, height: 32))
        search.canRequestFocus = { isOpen }
        let composer = ComposerTextView(frame: .init(x: 0, y: 32, width: 300, height: 90))
        let container = NSView(frame: .init(x: 0, y: 0, width: 300, height: 122))
        container.addSubview(search)
        container.addSubview(composer)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(composer))
        search.requestKeyboardFocus()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder === composer)
        isOpen = true
        search.requestKeyboardFocus()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder === search)
        isOpen = false
        #expect(window.makeFirstResponder(composer))
        search.requestKeyboardFocus()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.firstResponder === composer)
    }

    @Test func regularFontKeepsTerminalFamilySizeAndRemovesBoldTrait() {
        let font = QuickInputTypography.font(family: "Menlo-Bold", size: 15)
        #expect(font.pointSize == 15)
        #expect(font.familyName == "Menlo")
        #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!font.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(QuickInputTypography.font(family: nil, size: 13).pointSize == 13)
        #expect(SettingsStrings(language: .simplifiedChinese).quickInputQueueTitle == "排队")
        #expect(OMGKeyboardShortcut.quickInputHistory.storageValue == "shift+command+h")
    }

    private func snapshot(_ text: String) -> QuickInputDraftSnapshot {
        .init(text: text, selection: NSRange(location: (text as NSString).length, length: 0))
    }

    private func event(_ key: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "",
                       windowNumber: Int = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key))
    }
}
