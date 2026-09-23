import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct TerminalHistoryTableTests {
    @Test func compactRowsHaveBoundedHeightAndRequireAnchors() {
        let coordinator = TerminalHistoryTable.Coordinator()
        let item = InspectorHistoryItem(id: "prompt", kind: .agentPrompt,
                                       text: String(repeating: "Long prompt 中文 ", count: 50))
        coordinator.items = [item]
        let table = NSTableView()
        coordinator.table = table
        coordinator.updateWidth(320)
        let longHeight = coordinator.tableView(table, heightOfRow: 0)
        #expect(longHeight <= 108)
        coordinator.items = [.init(id: "short", kind: .agentPrompt, text: "resume")]
        #expect(coordinator.tableView(table, heightOfRow: 0) < longHeight)
        #expect(coordinator.tableView(table, heightOfRow: 0) < 60)
        #expect(!TerminalHistoryTable.Coordinator.canJump(item))
        #expect(TerminalHistoryTable.Coordinator.canJump(.init(
            id: "any-opaque-id", kind: .command, text: "ll",
            location: .command(surfaceID: UUID(), executionID: 1, epoch: UUID())
        )))
    }

    @Test func hostedHistoryScrollsAndCopiesWithoutOverlapping() async throws {
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
        #expect(table.rect(ofRow: 1).minY >= table.rect(ofRow: 0).maxY)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(table.copyText?() == items[0].text)
        let expanded = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? TerminalHistoryTable.HistoryCell)
        #expect(!expanded.jump.isEnabled)
        #expect(expanded.jump.image != nil)
        #expect(table.style == .plain)
        expanded.jump.performClick(nil)
        #expect(jumped.isEmpty)
        #expect(expanded.subviews.count == 3)
    }

    @Test func compactInfoHostsPortsAndHistoryTogether() async throws {
        let texts = [
            "看看这个模块的实现，重点检查多轮对话的定位和不同 pane 之间的隔离。",
            "Please review the implementation. Preserve the complete prompt when copying, even when this preview wraps onto several lines.",
            "继续",
            String(repeating: "长文本预览应当正常换行，不覆盖下一条记录。", count: 20),
        ]
        let items = (0..<16).map { index in
            InspectorHistoryItem(id: "fixture-\(index)", kind: .agentPrompt,
                                 text: texts[index % texts.count], timestamp: Date(timeIntervalSince1970: 1_790_079_600 - Double(index * 90)))
        }
        let info = InspectorInfoContent(portForwards: .init(hostAlias: "dev-server", items: []),
                                        historyItems: items, isAgentSession: true, agentName: "Claude")
        let host = NSHostingView(rootView: InspectorInfoView(info: info, dividerColor: .gray.opacity(0.2), perform: { _ in })
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScroll(in: host))
        #expect(scroll.contentSize.height > 300)
        let table = try #require(scroll.documentView as? TerminalHistoryTable.HistoryTable)
        #expect(table.numberOfRows == 16)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(table.copyText?() == texts[1])
        // Opt-in visual artifact, with no filesystem writes in normal test runs.
        if let path = ProcessInfo.processInfo.environment["OMG_HISTORY_SNAPSHOT"],
           let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? TerminalHistoryTable.HistoryScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }

    @Test func reloadPreservesSelectionAndScrollButNeverSelectsAnotherOccurrence() {
        let coordinator = TerminalHistoryTable.Coordinator()
        let table = TerminalHistoryTable.HistoryTable(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.headerView = nil
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        let items = (0..<40).map { InspectorHistoryItem(id: "row-\($0)", kind: .command, text: "ll") }
        coordinator.update(items: items, strings: .init(language: .english))
        table.selectRowIndexes(IndexSet(integer: 15), byExtendingSelection: false)
        table.scrollRowToVisible(15)
        let oldTop = table.row(at: scroll.contentView.bounds.origin)
        coordinator.update(items: [.init(id: "new", kind: .command, text: "ll")] + items,
                           strings: .init(language: .english))
        #expect(table.selectedRow == 16)
        #expect(table.row(at: scroll.contentView.bounds.origin) == oldTop + 1)
        coordinator.update(items: items.filter { $0.id != "row-15" }, strings: .init(language: .english))
        #expect(table.selectedRow == -1)
        #expect(!TerminalHistoryTable.Coordinator.canJump(.init(id: "command:fake:1", kind: .command, text: "ll")))
    }

    @Test func emptyPortsStayCompactAndPopulatedPortsAreBounded() {
        #expect(InfoHistoryLayout.portHeight(count: 0) == 64)
        #expect(InfoHistoryLayout.portHeight(count: 1) > 64)
        #expect(InfoHistoryLayout.portHeight(count: 100) <= 180)
    }

    @Test func labelFramesStayWithinRow() {
        let cell = TerminalHistoryTable.HistoryCell(frame: NSRect(x: 0, y: 0, width: 260, height: 116))
        cell.layout()
        #expect(cell.bounds.contains(cell.text.frame))
        #expect(cell.bounds.contains(cell.date.frame))
        #expect(!cell.text.frame.intersects(cell.date.frame))
        #expect(!cell.text.frame.intersects(cell.jump.frame))
        #expect(cell.text.frame.minY == TerminalHistoryTable.Metrics.verticalInset)
        #expect(cell.text.frame.maxY + TerminalHistoryTable.Metrics.textDateGap == cell.date.frame.minY)
        #expect(cell.bounds.maxY - cell.date.frame.maxY == TerminalHistoryTable.Metrics.verticalInset)
        #expect(cell.jump.frame.maxX <= cell.bounds.maxX)

        let shortCell = TerminalHistoryTable.HistoryCell(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        shortCell.layout()
        #expect(shortCell.text.frame.maxY < shortCell.date.frame.minY)
        #expect(shortCell.bounds.contains(shortCell.date.frame))
        #expect(shortCell.bounds.maxY - shortCell.date.frame.maxY == TerminalHistoryTable.Metrics.verticalInset)
    }
}
