import AppKit
import SwiftUI

struct GitHistoryTable: NSViewRepresentable {
    let commits: [GitHistoryCommit]
    let selectedCommitID: GitCommitID?
    var headCommitID: GitCommitID?
    var expandedCommits: [GitCommitID: GitCommitExpansion] = [:]
    var hasMore = false
    var isLoading = false
    var automaticLoadingAllowed = true
    let onSelect: (GitCommitID) -> Void
    let onOpen: (GitCommitID) -> Void
    let onShowInTerminal: (GitCommitID) -> Void
    var onOpenFile: (GitCommitID, GitDiffFile) -> Void = { _, _ in }
    var onLoadMore: () -> Void = {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: .init("git-history"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clickedRow)
        table.doubleAction = #selector(Coordinator.openSelectedCommit)
        table.menu = context.coordinator.makeContextMenu()
        scroll.documentView = table
        context.coordinator.attach(table: table, scroll: scroll)
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private enum Row {
            case commit(Int)
            case details(Int)
            case file(Int, GitDiffFile)
            var commitIndex: Int {
                switch self {
                case .commit(let index), .details(let index), .file(let index, _): index
                }
            }
            var suffix: String {
                switch self {
                case .commit: "commit"
                case .details: "details"
                case .file(_, let file): file.id
                }
            }
        }
        weak var tableView: NSTableView?
        private var content: GitHistoryTable?
        private var rows: [Row] = []
        private var graphRows: [GitGraphRow] = []
        private var heights: [CGFloat] = []
        private var graphWidth: CGFloat = 15
        private var laneCount = 1
        private var measuredWidth: CGFloat = 0
        private var updating = false
        private var requestedCount: Int?
        private var observers: [NSObjectProtocol] = []
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter
        }()

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(table: NSTableView, scroll: NSScrollView) {
            tableView = table
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll.contentView,
                                                                         queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.viewportChanged() }
                })
            }
        }

        func update(_ new: GitHistoryTable) {
            let changed = content?.commits != new.commits || content?.expandedCommits != new.expandedCommits ||
                content?.headCommitID != new.headCommitID
            if content?.commits != new.commits { requestedCount = nil }
            let previous = content
            content = new
            guard let table = tableView else { return }
            updating = true
            defer {
                updating = false
                DispatchQueue.main.async { [weak self] in self?.viewportChanged() }
            }
            if changed {
                let top = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
                let anchor = rows.indices.contains(top) ? rows[top] : nil
                let anchorID = anchor.flatMap { row in previous?.commits[safe: row.commitIndex]?.id }
                let offset = top >= 0 ? table.visibleRect.minY - table.rect(ofRow: top).minY : 0
                var layout = GitGraphLayout()
                graphRows = new.commits.map { layout.append(commitID: $0.id, parentIDs: $0.parentIDs) }
                laneCount = max(1, graphRows.map(\.requiredLaneCount).max() ?? 1)
                graphWidth = min(31, GitGraphCellView.preferredWidth(laneCount: laneCount))
                rows = []
                for (index, commit) in new.commits.enumerated() {
                    rows.append(.commit(index))
                    if let details = new.expandedCommits[commit.id] {
                        rows.append(.details(index))
                        rows.append(contentsOf: details.files.map { .file(index, $0) })
                    }
                }
                measureRows()
                table.reloadData()
                if let anchorID, let index = rows.firstIndex(where: {
                    new.commits[$0.commitIndex].id == anchorID && $0.suffix == anchor?.suffix
                }), let clip = table.enclosingScrollView?.contentView {
                    clip.scroll(to: NSPoint(x: 0, y: max(0, table.rect(ofRow: index).minY + offset)))
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            if let selected = new.selectedCommitID {
                let selectedRow = table.selectedRow
                let alreadySelected = rows.indices.contains(selectedRow) &&
                    new.commits[rows[selectedRow].commitIndex].id == selected
                if !alreadySelected, let index = rows.firstIndex(where: {
                    if case .commit = $0 { return new.commits[$0.commitIndex].id == selected }
                    return false
                }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
        }

        private func measureRows() {
            guard let content, let table = tableView else { return }
            measuredWidth = max(1, table.enclosingScrollView?.contentSize.width ?? table.bounds.width)
            let width = max(1, measuredWidth - graphWidth - 29)
            heights = rows.map { row in
                let commit = content.commits[row.commitIndex]
                switch row {
                case .commit:
                    let badges = GitRefBadgesView.height(for: commit.refDecorations, width: width)
                    return 64 + (badges > 0 ? badges + 4 : 0)
                case .details:
                    let text = content.expandedCommits[commit.id]?.detailText ?? ""
                    return GitHistoryChildCell.detailHeight(text, width: width)
                case .file: return 26
                }
            }
        }

        private func viewportChanged() {
            guard !updating, let table = tableView else { return }
            let width = max(1, table.enclosingScrollView?.contentSize.width ?? table.bounds.width)
            if abs(width - measuredWidth) > 0.5 {
                updating = true
                measureRows()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                table.enumerateAvailableRowViews { view, _ in view.needsLayout = true }
                updating = false
            }
            requestMoreIfNeeded()
        }

        func requestMoreIfNeeded() {
            guard !updating, let content, let table = tableView,
                  content.hasMore, !content.isLoading, content.automaticLoadingAllowed,
                  !content.commits.isEmpty, table.visibleRect.height > 0 else { return }
            guard table.visibleRect.maxY >= table.bounds.height - 100 else { requestedCount = nil; return }
            guard requestedCount != content.commits.count else { return }
            requestedCount = content.commits.count
            content.onLoadMore()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights[safe: row] ?? 40 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let content, rows.indices.contains(row) else { return nil }
            let item = rows[row]
            let commit = content.commits[item.commitIndex]
            let graph = graphRows[item.commitIndex]
            switch item {
            case .commit:
                let cell = (tableView.makeView(withIdentifier: .init("git-commit"), owner: nil) as? GitHistoryCell) ?? GitHistoryCell()
                cell.identifier = .init("git-commit")
                cell.configure(commit: commit, graph: graph, graphLayout: (graphWidth, laneCount),
                               date: dateFormatter.string(from: commit.authoredAt),
                               state: (head: content.headCommitID == commit.id ||
                                   (content.headCommitID == nil && commit.refDecorations.contains { $0.kind == .head || $0.kind == .currentBranch }),
                                       expanded: content.expandedCommits[commit.id] != nil),
                               toggle: { [weak self] in self?.content?.onOpen(commit.id) })
                return cell
            case .details, .file:
                let cell = (tableView.makeView(withIdentifier: .init("git-child"), owner: nil) as? GitHistoryChildCell) ?? GitHistoryChildCell()
                cell.identifier = .init("git-child")
                let file: GitDiffFile?
                if case .file(_, let value) = item { file = value } else { file = nil }
                cell.configure(graph: graph, graphWidth: graphWidth, laneCount: laneCount,
                               details: content.expandedCommits[commit.id], file: file)
                return cell
            }
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = tableView, rows.indices.contains(table.selectedRow), let content else { return }
            content.onSelect(content.commits[rows[table.selectedRow].commitIndex].id)
        }
        func activateRow(_ index: Int, doubleClick: Bool) {
            guard let content, rows.indices.contains(index) else { return }
            switch rows[index] {
            case .file(let commit, let file) where !doubleClick: content.onOpenFile(content.commits[commit].id, file)
            case .commit(let commit) where doubleClick: content.onOpen(content.commits[commit].id)
            default: break
            }
        }
        @objc func clickedRow() {
            guard let table = tableView else { return }
            activateRow(table.clickedRow, doubleClick: false)
        }
        @objc func openSelectedCommit() {
            guard let table = tableView else { return }
            activateRow(table.clickedRow >= 0 ? table.clickedRow : table.selectedRow, doubleClick: true)
        }
        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Expand / Collapse Commit", action: #selector(openSelectedCommit), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }
    }
}

private final class GitHistoryCell: NSTableCellView {
    private let subject = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let hashLabel = NSTextField(labelWithString: "")
    private let headLabel = NSTextField(labelWithString: "HEAD")
    private let badges = GitRefBadgesView()
    private let graph = GitGraphCellView()
    private let disclosure = NSButton()
    private var graphWidth: CGFloat = 15
    private var toggle: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        subject.font = .systemFont(ofSize: 12)
        author.font = .systemFont(ofSize: 11, weight: .medium)
        date.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        hashLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hashLabel.alignment = .right
        date.textColor = .secondaryLabelColor
        hashLabel.textColor = .secondaryLabelColor
        headLabel.font = .systemFont(ofSize: 8, weight: .semibold)
        headLabel.alignment = .center
        headLabel.textColor = .controlAccentColor
        headLabel.wantsLayer = true
        headLabel.layer?.cornerRadius = 3
        for label in [subject, author, date, hashLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleNone
        disclosure.controlSize = .small
        disclosure.focusRingType = .none
        disclosure.setButtonType(.momentaryChange)
        disclosure.target = self
        disclosure.action = #selector(toggleCommit)
        [graph, disclosure, subject, date, author, hashLabel, headLabel, badges].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    @objc private func toggleCommit() { toggle() }

    func configure(commit: GitHistoryCommit, graph: GitGraphRow, graphLayout: (width: CGFloat, lanes: Int),
                   date: String, state: (head: Bool, expanded: Bool), toggle: @escaping () -> Void) {
        self.graphWidth = graphLayout.width
        self.toggle = toggle
        self.graph.configure(row: graph, isHead: state.head, laneCount: graphLayout.lanes)
        subject.stringValue = commit.subject.isEmpty ? "(no subject)" : commit.subject
        self.date.stringValue = date
        author.stringValue = commit.authorName
        hashLabel.stringValue = commit.id.shortSHA
        headLabel.isHidden = !state.head
        headLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        badges.configure(commit.refDecorations)
        disclosure.image = NSImage(systemSymbolName: state.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: state.expanded ? "Collapse commit" : "Expand commit")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toolTip = "\(commit.subject)\n\(commit.id.rawValue)\n\(commit.authorName) · \(date)"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: graphWidth, height: bounds.height)
        disclosure.frame = NSRect(x: graphWidth, y: 5, width: 18, height: 18)
        let x = graphWidth + 21
        let width = max(1, bounds.width - x - 8)
        let hashWidth: CGFloat = 52
        date.frame = NSRect(x: x, y: 7, width: max(1, width - hashWidth - 6), height: 14)
        hashLabel.frame = NSRect(x: x + width - hashWidth, y: 7, width: hashWidth, height: 14)
        author.frame = NSRect(x: x, y: 24, width: max(1, width - (headLabel.isHidden ? 0 : 38)), height: 15)
        headLabel.frame = NSRect(x: x + width - 32, y: 25, width: 32, height: 13)
        subject.frame = NSRect(x: x, y: 42, width: width, height: 17)
        badges.frame = NSRect(x: x, y: 63, width: width, height: max(0, bounds.height - 66))
    }
}

private final class GitHistoryChildCell: NSTableCellView {
    private let graph = GitGraphCellView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var graphWidth: CGFloat = 15
    private var isFile = false
    static func detailHeight(_ text: String, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text)
        cell.attributedStringValue = attributedDetail(text)
        cell.wraps = true
        cell.isScrollable = false
        cell.usesSingleLineMode = false
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude))
        return max(28, ceil(size.height) + 18)
    }
    private static func attributedDetail(_ text: String) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let separator = (text as NSString).range(of: "\n\nMessage\n")
        if separator.location != NSNotFound {
            let start = NSMaxRange(separator)
            value.addAttribute(.foregroundColor, value: NSColor.labelColor,
                               range: NSRange(location: start, length: value.length - start))
            for title in ["Author", "Date", "Commit", "Message"] {
                let range = (text as NSString).range(of: title)
                value.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .semibold), range: range)
            }
        }
        return value
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(graph); addSubview(label)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    func configure(graph: GitGraphRow, graphWidth: CGFloat, laneCount: Int,
                   details: GitCommitExpansion?, file: GitDiffFile?) {
        self.graphWidth = graphWidth
        self.graph.configure(row: graph, continuation: true, laneCount: laneCount)
        isFile = file != nil
        label.isSelectable = !isFile
        label.maximumNumberOfLines = isFile ? 1 : 0
        label.lineBreakMode = isFile ? .byTruncatingMiddle : .byWordWrapping
        if let file {
            let text = NSMutableAttributedString(string: file.status + "  ", attributes: [
                .foregroundColor: file.kind.color,
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            ])
            text.append(NSAttributedString(string: file.displayPath, attributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11),
            ]))
            label.attributedStringValue = text
        } else {
            label.attributedStringValue = Self.attributedDetail(details?.detailText ?? "")
        }
        toolTip = file.map { $0.kind.label + " · " + $0.displayPath } ?? details?.detailText
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: graphWidth, height: bounds.height)
        label.frame = NSRect(x: graphWidth + 21, y: isFile ? 5 : 7,
                             width: max(1, bounds.width - graphWidth - 29), height: max(1, bounds.height - (isFile ? 8 : 14)))
    }
}
