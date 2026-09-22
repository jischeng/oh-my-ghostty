import AppKit
import SwiftUI

struct TerminalHistoryTable: NSViewRepresentable {
    let items: [InspectorHistoryItem]
    let jump: (InspectorHistoryItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = HistoryTable()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 58
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
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
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.jump = jump
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [InspectorHistoryItem] = []
        var jump: ((InspectorHistoryItem) -> Void)?
        weak var table: NSTableView?
        private let formatter: DateFormatter = {
            let value = DateFormatter()
            value.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return value
        }()
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        @objc func activate() {
            guard let table, items.indices.contains(table.clickedRow) else { return }
            jump?(items[table.clickedRow])
        }
        @objc func jumpButton(_ sender: NSButton) {
            guard items.indices.contains(sender.tag) else { return }
            jump?(items[sender.tag])
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let cell = NSTableCellView()
            let text = NSTextField(wrappingLabelWithString: item.text)
            text.maximumNumberOfLines = 2
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: 12)
            let date = NSTextField(labelWithString: item.timestamp.map(formatter.string(from:)) ?? "")
            date.font = .systemFont(ofSize: 10)
            date.textColor = .secondaryLabelColor
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Jump")!, target: self, action: #selector(jumpButton(_:)))
            button.tag = row
            button.isBordered = false
            let labels = NSStackView(views: [text, date])
            labels.orientation = .vertical
            labels.alignment = .leading
            let stack = NSStackView(views: [labels, button])
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24)
            ])
            return cell
        }
    }
}
