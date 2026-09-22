import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct TerminalHistoryTableTests {
    @Test func longPromptRowsExpandAndWrapWithWidth() {
        let coordinator = TerminalHistoryTable.Coordinator()
        coordinator.items = [.init(id: "prompt", kind: .agentPrompt,
                                   text: String(repeating: "这是一个需要换行的长 Prompt。", count: 50))]
        let table = NSTableView()
        coordinator.table = table
        coordinator.updateWidth(320)
        let collapsed = coordinator.tableView(table, heightOfRow: 0)
        coordinator.expanded.insert("prompt")
        let expanded = coordinator.tableView(table, heightOfRow: 0)
        #expect(collapsed <= 116)
        #expect(expanded > collapsed)
        coordinator.updateWidth(200)
        #expect(coordinator.tableView(table, heightOfRow: 0) > expanded)
    }

    @Test func hostedHistoryScrollsAndExpandsWithoutOverlapping() async throws {
        let items = (0..<40).map { index in
            InspectorHistoryItem(id: "row-\(index)", kind: .agentPrompt,
                                 text: String(repeating: "Prompt \(index) 中文 long text. ", count: 30))
        }
        var jumped: [String] = []
        let host = NSHostingView(rootView: TerminalHistoryTable(items: items) { jumped.append($0.id) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScroll(in: host))
        let table = try #require(scroll.documentView as? TerminalHistoryTable.HistoryTable)
        #expect(table.numberOfRows == 40)
        #expect(table.bounds.height > scroll.contentSize.height)
        table.scrollRowToVisible(39)
        #expect(scroll.contentView.bounds.minY > 0)
        table.scrollRowToVisible(0)
        let before = table.rect(ofRow: 0).height
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? TerminalHistoryTable.HistoryCell)
        cell.expand.performClick(nil)
        host.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 0).height > before)
        #expect(table.rect(ofRow: 1).minY >= table.rect(ofRow: 0).maxY)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(table.copyText?() == items[0].text)
        let expanded = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? TerminalHistoryTable.HistoryCell)
        expanded.jump.performClick(nil)
        #expect(jumped == [items[0].id])
        expanded.expand.performClick(nil)
        host.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 0).height == before)
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? TerminalHistoryTable.HistoryScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }

    @Test func labelFramesStayWithinRow() {
        let cell = TerminalHistoryTable.HistoryCell(frame: NSRect(x: 0, y: 0, width: 260, height: 116))
        cell.layout()
        #expect(cell.bounds.contains(cell.text.frame))
        #expect(cell.bounds.contains(cell.date.frame))
        #expect(!cell.text.frame.intersects(cell.date.frame))
        #expect(cell.jump.frame.maxX <= cell.bounds.maxX)
    }
}
