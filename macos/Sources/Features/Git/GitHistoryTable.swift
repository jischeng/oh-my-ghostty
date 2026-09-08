import AppKit
import SwiftUI

struct GitHistoryTable: NSViewRepresentable {
    let commits: [GitHistoryCommit]
    let selectedCommitID: GitCommitID?
    let onSelect: (GitCommitID) -> Void
    let onOpen: (GitCommitID) -> Void
    let onShowInTerminal: (GitCommitID) -> Void

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelect: onSelect,
            onOpen: onOpen,
            onShowInTerminal: onShowInTerminal
        )
    }

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
        table.rowHeight = 62
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("git-history"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelectedCommit)
        table.menu = context.coordinator.makeContextMenu()
        scrollView.documentView = table
        context.coordinator.tableView = table
        context.coordinator.update(
            commits: commits,
            selectedCommitID: selectedCommitID,
            onSelect: onSelect,
            onOpen: onOpen,
            onShowInTerminal: onShowInTerminal
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            commits: commits,
            selectedCommitID: selectedCommitID,
            onSelect: onSelect,
            onOpen: onOpen,
            onShowInTerminal: onShowInTerminal
        )
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var commits: [GitHistoryCommit] = []
        private var graphRows: [GitGraphRow] = []
        private var selectedCommitID: GitCommitID?
        private var onSelect: (GitCommitID) -> Void
        private var onOpen: (GitCommitID) -> Void
        private var onShowInTerminal: (GitCommitID) -> Void
        private let dateFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
            return formatter
        }()

        init(
            onSelect: @escaping (GitCommitID) -> Void,
            onOpen: @escaping (GitCommitID) -> Void,
            onShowInTerminal: @escaping (GitCommitID) -> Void
        ) {
            self.onSelect = onSelect
            self.onOpen = onOpen
            self.onShowInTerminal = onShowInTerminal
        }

        func update(
            commits: [GitHistoryCommit],
            selectedCommitID: GitCommitID?,
            onSelect: @escaping (GitCommitID) -> Void,
            onOpen: @escaping (GitCommitID) -> Void,
            onShowInTerminal: @escaping (GitCommitID) -> Void
        ) {
            let changed = self.commits != commits || self.selectedCommitID != selectedCommitID
            self.commits = commits
            if changed {
                var layout = GitGraphLayout()
                graphRows = commits.map {
                    layout.append(commitID: $0.id, parentIDs: $0.parentIDs)
                }
            }
            self.selectedCommitID = selectedCommitID
            self.onSelect = onSelect
            self.onOpen = onOpen
            self.onShowInTerminal = onShowInTerminal
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
            cell.configure(
                commit: commits[row],
                graphRow: graphRows[row],
                date: dateFormatter.string(from: commits[row].authoredAt)
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, tableView.selectedRow >= 0, commits.indices.contains(tableView.selectedRow) else { return }
            onSelect(commits[tableView.selectedRow].id)
        }

        @objc func openSelectedCommit() {
            guard let commitID = clickedCommitID else { return }
            onOpen(commitID)
        }

        @objc private func showSelectedCommitInTerminal() {
            guard let commitID = clickedCommitID else { return }
            onShowInTerminal(commitID)
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            let open = NSMenuItem(
                title: "Open Commit in Editor",
                action: #selector(openSelectedCommit),
                keyEquivalent: ""
            )
            open.target = self
            menu.addItem(open)
            return menu
        }

        private var clickedCommitID: GitCommitID? {
            guard let tableView else { return nil }
            let row = tableView.clickedRow >= 0
                ? tableView.clickedRow
                : tableView.selectedRow
            guard commits.indices.contains(row) else { return nil }
            return commits[row].id
        }
    }
}

private final class GitHistoryCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("git-history-cell")
    private let subject = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let refs = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let graph = GitGraphCellView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        subject.font = .systemFont(ofSize: 12, weight: .medium)
        subject.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        refs.lineBreakMode = .byTruncatingTail
        for label in [subject, detail, refs] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.maximumNumberOfLines = 1
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(subject)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(refs)
        graph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(graph)
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo: leadingAnchor),
            graph.topAnchor.constraint(equalTo: topAnchor),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor),
            graph.widthAnchor.constraint(equalToConstant: 48),
            subject.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            refs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(commit: GitHistoryCommit, graphRow: GitGraphRow, date: String) {
        graph.configure(row: graphRow)
        subject.stringValue = commit.subject.isEmpty ? "(no subject)" : commit.subject
        detail.stringValue = "\(commit.id.shortSHA)  \(commit.authorName)  \(date)"
        let badges = NSMutableAttributedString()
        for decoration in commit.refDecorations {
            let color: NSColor
            let prefix: String
            switch decoration.kind {
            case .currentBranch: color = .systemBlue; prefix = "● "
            case .localBranch: color = .systemGreen; prefix = "⑂ "
            case .remoteBranch: color = .systemPurple; prefix = "↗ "
            case .tag: color = .systemOrange; prefix = "Tag: "
            case .head: color = .systemBlue; prefix = "◎ "
            }
            badges.append(NSAttributedString(string: prefix + decoration.name + "  ", attributes: [
                .foregroundColor: color, .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            ]))
        }
        refs.attributedStringValue = badges
        refs.toolTip = commit.refDecorations.map { "\($0.kind.rawValue): \($0.name)" }.joined(separator: "\n")
        toolTip = "\(commit.subject)\n\(detail.stringValue)\n\(refs.toolTip ?? "")"
    }
}
