import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct QuickInputHistoryNativeTests {
    @Test func filteringRetainsSearchClientReconcilesSelectionAndMapsVerticalArrows() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)

        for index in 0..<50 {
            store.record("entry \(index)", paneID: pane, tabID: tab)
        }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let presentation = model.historyPresentation
        presentation.open(entries: entries)

        let host = NSHostingView(rootView: QuickInputHistoryView(
            model: model,
            store: store,
            settings: settings,
            onSelect: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func refresh() async {
            host.layoutSubtreeIfNeeded()
            host.display()
            try? await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
        }

        await refresh()
        let input = try #require(find(QuickInputHistorySearchTextView.self, in: host))
        #expect(window.makeFirstResponder(input))
        #expect(presentation.selectedID == entries[0].id)

        // Bottom-up capsule stack: pressing Up Arrow (126) moves upward to older entries[1]; Down Arrow (125) returns.
        input.keyDown(with: try keyEvent(126, windowNumber: window.windowNumber))
        #expect(presentation.selectedID == entries[1].id)
        input.keyDown(with: try keyEvent(125, windowNumber: window.windowNumber))
        #expect(presentation.selectedID == entries[0].id)

        // Filtering 100 -> matching subset -> 0 -> 100 keeps the same mounted input client.
        presentation.beginSearch()
        presentation.query = "entry 4"
        await refresh()
        #expect(find(QuickInputHistorySearchTextView.self, in: host) === input)
        let filtered = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab, query: "entry 4")
        #expect(presentation.selectedID == filtered.first?.id)

        presentation.query = "no-such-match-xyz"
        await refresh()
        #expect(presentation.selectedID == nil)

        presentation.query = ""
        await refresh()
        #expect(find(QuickInputHistorySearchTextView.self, in: host) === input)
        #expect(presentation.selectedID == entries[0].id)
    }

    @Test func hoveringCapsuleUpdatesSelectionWithoutDisruptingMarkedText() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)

        for index in 0..<20 {
            store.record("entry \(index)", paneID: pane, tabID: tab)
        }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let presentation = model.historyPresentation
        presentation.open(entries: entries)

        let host = NSHostingView(rootView: QuickInputHistoryView(
            model: model,
            store: store,
            settings: settings,
            onSelect: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        host.layoutSubtreeIfNeeded()
        host.display()
        try await Task.sleep(for: .milliseconds(40))

        let input = try #require(find(QuickInputHistorySearchTextView.self, in: host))
        #expect(window.makeFirstResponder(input))
        input.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        presentation.hover(entries[10].id)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))

        #expect(presentation.selectedID == entries[10].id)
        #expect(input.hasMarkedText())
        #expect(input.string == "拼")
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func keyEvent(_ keyCode: UInt16, windowNumber: Int) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
