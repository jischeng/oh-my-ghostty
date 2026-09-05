import AppKit
import SwiftUI

struct GitHistoryTable: NSViewRepresentable {
    let commits: [GitHistoryCommit]
    let selectedCommitID: GitCommitID?
    let onSelect: (GitCommitID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.rowHeight = 56
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("git-history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scrollView.documentView = table
        context.coordinator.tableView = table
        context.coordinator.update(commits: commits, selectedCommitID: selectedCommitID, onSelect: onSelect)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(commits: commits, selectedCommitID: selectedCommitID, onSelect: onSelect)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var commits: [GitHistoryCommit] = []
        private var selectedCommitID: GitCommitID?
        private var onSelect: (GitCommitID) -> Void
        private let dateFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
            return formatter
        }()

        init(onSelect: @escaping (GitCommitID) -> Void) { self.onSelect = onSelect }

        func update(commits: [GitHistoryCommit], selectedCommitID: GitCommitID?, onSelect: @escaping (GitCommitID) -> Void) {
            let changed = self.commits != commits || self.selectedCommitID != selectedCommitID
            self.commits = commits
            self.selectedCommitID = selectedCommitID
            self.onSelect = onSelect
            guard changed, let tableView else { return }
            tableView.reloadData()
            if let selectedCommitID, let row = commits.firstIndex(where: { $0.id == selectedCommitID }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard commits.indices.contains(row) else { return nil }
            let identifier = GitHistoryCell.reuseIdentifier
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? GitHistoryCell ?? GitHistoryCell()
            cell.identifier = identifier
            cell.configure(commit: commits[row], date: dateFormatter.string(from: commits[row].authoredAt))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, tableView.selectedRow >= 0, commits.indices.contains(tableView.selectedRow) else { return }
            onSelect(commits[tableView.selectedRow].id)
        }
    }
}

private final class GitHistoryCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("git-history-cell")
    private let subject = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let refs = NSStackView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        subject.font = .systemFont(ofSize: 12, weight: .medium)
        subject.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        refs.orientation = .horizontal
        refs.spacing = 4
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(subject)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(refs)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(commit: GitHistoryCommit, date: String) {
        subject.stringValue = commit.subject.isEmpty ? "(no subject)" : commit.subject
        detail.stringValue = "\(commit.id.shortSHA)  \(commit.authorName)  \(date)"
        refs.arrangedSubviews.forEach { refs.removeArrangedSubview($0); $0.removeFromSuperview() }
        for decoration in commit.refDecorations {
            let label = NSTextField(labelWithString: decoration.name)
            label.font = .systemFont(ofSize: 9, weight: .medium)
            label.textColor = .systemGreen
            label.drawsBackground = true
            label.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12)
            label.wantsLayer = true
            label.layer?.cornerRadius = 3
            label.alignment = .center
            refs.addArrangedSubview(label)
        }
    }
}
