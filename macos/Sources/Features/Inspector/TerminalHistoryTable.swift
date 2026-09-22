import AppKit
import SwiftUI

/// One vertically scrolling document; row geometry and text use the same width.
struct TerminalHistoryTable: NSViewRepresentable {
    let items: [InspectorHistoryItem]
    let jump: (InspectorHistoryItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = HistoryScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = HistoryTable()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("history"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.activate)
        table.copyText = { [weak coordinator = context.coordinator, weak table] in
            guard let coordinator, let table,
                  coordinator.items.indices.contains(table.selectedRow) else { return nil }
            return coordinator.items[table.selectedRow].text
        }
        context.coordinator.table = table
        scroll.documentView = table
        scroll.widthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.updateWidth(width)
        }
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.jump = jump
        coordinator.updateWidth(scroll.contentSize.width)
        guard coordinator.items != items else { return }
        let selected = coordinator.table.flatMap { table in
            coordinator.items.indices.contains(table.selectedRow)
                ? coordinator.items[table.selectedRow].id : nil
        }
        coordinator.items = items
        coordinator.table?.reloadData()
        if let selected, let index = items.firstIndex(where: { $0.id == selected }) {
            coordinator.table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    final class HistoryScrollView: NSScrollView {
        var widthChanged: ((CGFloat) -> Void)?
        override func layout() {
            super.layout()
            widthChanged?(contentSize.width)
        }
    }

    final class HistoryTable: NSTableView {
        var copyText: (() -> String?)?
        @objc func copy(_ sender: Any?) {
            guard let text = copyText?() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c", copyText?() != nil {
                copy(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    enum Metrics {
        static let font = NSFont.systemFont(ofSize: 12)
        static let previewHeight: CGFloat = 72
        static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            return max(18, ceil((text as NSString).boundingRect(
                with: NSSize(width: max(20, width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: style]
            ).height) + 4)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [InspectorHistoryItem] = []
        var jump: ((InspectorHistoryItem) -> Void)?
        weak var table: NSTableView?
        private var width: CGFloat = 300
        private let formatter: DateFormatter = {
            let value = DateFormatter()
            value.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return value
        }()
        func updateWidth(_ value: CGFloat) {
            guard value > 0, abs(width - value) > 0.5 else { return }
            width = value
            table?.tableColumns.first?.width = value
            table?.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: items.indices))
            table?.reloadData()
        }
        static func canJump(_ item: InspectorHistoryItem) -> Bool {
            item.kind == .command && item.id.hasPrefix("command:")
        }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let height = Metrics.textHeight(items[row].text, width: width - 8)
            return min(height, Metrics.previewHeight) + 26
        }
        @objc func activate() {
            guard let table, items.indices.contains(table.clickedRow) else { return }
            guard Self.canJump(items[table.clickedRow]) else { return }
            jump?(items[table.clickedRow])
        }
        @objc func jumpButton(_ sender: NSButton) {
            guard items.indices.contains(sender.tag) else { return }
            guard Self.canJump(items[sender.tag]) else { return }
            jump?(items[sender.tag])
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let cell = HistoryCell()
            cell.wantsLayer = true
            cell.layer?.masksToBounds = true
            cell.text.stringValue = item.text
            cell.text.maximumNumberOfLines = 4
            cell.date.stringValue = item.timestamp.map(formatter.string(from:)) ?? ""
            cell.jump.title = Self.canJump(item) ? "↗" : "—"
            cell.jump.isEnabled = Self.canJump(item)
            cell.jump.setAccessibilityLabel(Self.canJump(item) ? "跳转到输入位置" : "暂无终端位置锚点")
            cell.jump.toolTip = Self.canJump(item) ? "Jump / 跳转" : "No terminal anchor / 无终端位置锚点"
            cell.jump.target = self
            cell.jump.action = #selector(jumpButton(_:))
            cell.jump.tag = row
            return cell
        }
    }

    final class HistoryCell: NSTableCellView {
        let text = NSTextField(wrappingLabelWithString: "")
        let date = NSTextField(labelWithString: "")
        let jump = NSButton(title: "↗", target: nil, action: nil)
        override init(frame: NSRect) {
            super.init(frame: frame)
            text.font = Metrics.font
            text.lineBreakMode = .byWordWrapping
            date.font = .systemFont(ofSize: 10)
            date.textColor = .secondaryLabelColor
            date.lineBreakMode = .byTruncatingTail
            jump.isBordered = false
            jump.toolTip = "Jump / 跳转"
            for view in [text, date, jump] { addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.separatorColor.withAlphaComponent(0.25).setFill()
            NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: 0.5).fill()
        }
        override func layout() {
            super.layout()
            // Explicit bounded frames prevent a long label from painting across rows.
            text.frame = NSRect(x: 4, y: 22, width: max(20, bounds.width - 8), height: max(18, bounds.height - 26))
            date.frame = NSRect(x: 4, y: 4, width: max(20, bounds.width - 40), height: 16)
            jump.frame = NSRect(x: bounds.width - 30, y: 0, width: 24, height: 24)
        }
    }
}
