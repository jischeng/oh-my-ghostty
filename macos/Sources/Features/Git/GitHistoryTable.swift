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
    var isBusy = false
    let onSelect: (GitCommitID) -> Void
    let onOpen: (GitCommitID) -> Void
    let onShowInTerminal: (GitCommitID) -> Void
    var onOpenFile: (GitCommitID, GitDiffFile) -> Void = { _, _ in }
    var onLoadMore: () -> Void = {}
    var onCommitAction: (GitCommitOperation, GitCommitID) -> Void = { _, _ in }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = InspectorCopyTableView()
        table.copyValue = { [weak coordinator = context.coordinator] in coordinator?.selectedCopyValue() }
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private enum Row: Hashable {
            case commit(Int)
            case files(Int)
            case message(Int)
            case notice(Int)
            case file(Int, GitDiffFile)
            var commitIndex: Int {
                switch self {
                case .commit(let index), .files(let index), .message(let index), .notice(let index), .file(let index, _): index
                }
            }
            var suffix: String {
                switch self {
                case .commit: "commit"
                case .files: "files"
                case .message: "message"
                case .notice: "notice"
                case .file(_, let file): file.id
                }
            }
        }
        enum LocalChange { case files(GitCommitID), message(GitCommitID) }
        weak var tableView: NSTableView?
        private var content: GitHistoryTable?
        private var rows: [Row] = []
        private var graphRows: [GitGraphRow] = []
        private var heights: [CGFloat] = []
        private var graphColumns: [GitGraphColumnLayout] = []
        private var measuredWidth: CGFloat = 0
        private var updating = false
        private var requestedCount: Int?
        private var collapsedFiles = Set<GitCommitID>()
        private var messageExpansion: [GitCommitID: Bool] = [:]
        private var observers: [NSObjectProtocol] = []
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
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

        func update(_ new: GitHistoryTable, change: LocalChange? = nil) {
            let commitsChanged = content?.commits != new.commits
            let changed = commitsChanged || content?.expandedCommits != new.expandedCommits ||
                content?.headCommitID != new.headCommitID || change != nil
            if commitsChanged { requestedCount = nil }
            let previous = content
            collapsedFiles.formIntersection(new.expandedCommits.keys)
            messageExpansion = messageExpansion.filter { new.expandedCommits[$0.key] != nil }
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
                let oldRows = rows
                let oldHeights = heights
                if commitsChanged {
                    graphRows = GitGraphLayout.rows(for: new.commits)
                    graphColumns = graphRows.map { GitGraphColumnLayout(row: $0) }
                }
                rows = []
                for (index, commit) in new.commits.enumerated() {
                    rows.append(.commit(index))
                    if let details = new.expandedCommits[commit.id] {
                        if details.isLoading || details.error != nil {
                            rows.append(.notice(index))
                        } else {
                            rows.append(.files(index))
                            if !collapsedFiles.contains(commit.id) {
                                rows.append(contentsOf: details.files.map { .file(index, $0) })
                            }
                            if details.metadata?.body.isEmpty == false { rows.append(.message(index)) }
                        }
                    }
                }
                measureRows()
                if commitsChanged {
                    table.reloadData()
                } else {
                    updateVisibleRows(previous: previous, oldRows: oldRows, oldHeights: oldHeights, change: change)
                }
                if let anchorID, let index = rows.firstIndex(where: {
                    new.commits[$0.commitIndex].id == anchorID && $0.suffix == anchor?.suffix
                }), let clip = table.enclosingScrollView?.contentView {
                    clip.scroll(to: NSPoint(x: 0, y: max(0, table.rect(ofRow: index).minY + min(offset, max(0, table.rect(ofRow: index).height - 1)))))
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

        /// Preserve unrelated native cells and update only the changed block.
        private func updateVisibleRows(previous: GitHistoryTable?, oldRows: [Row], oldHeights: [CGFloat], change: LocalChange?) {
            guard let table = tableView, let content else { return }
            var prefix = 0
            while prefix < min(oldRows.count, rows.count), oldRows[prefix] == rows[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(oldRows.count, rows.count) - prefix,
                  oldRows[oldRows.count - suffix - 1] == rows[rows.count - suffix - 1] { suffix += 1 }
            let inserted = prefix..<(rows.count - suffix)
            var oldIndices: [Row: Int] = [:]
            for (index, row) in oldRows.enumerated() { oldIndices[row] = index }
            let changedCommits = Set(content.commits.filter {
                previous?.expandedCommits[$0.id] != content.expandedCommits[$0.id]
            }.map(\.id))
            var refresh = IndexSet()
            var resized = IndexSet()
            for (index, row) in rows.enumerated() where !inserted.contains(index) {
                guard let old = oldIndices[row] else { continue }
                if heights[index] != oldHeights[old] { resized.insert(index) }
                let id = content.commits[row.commitIndex].id
                switch row {
                case .commit:
                    if previous?.headCommitID != content.headCommitID ||
                        (previous?.expandedCommits[id] != nil) != (content.expandedCommits[id] != nil) { refresh.insert(index) }
                default:
                    if changedCommits.contains(id) { refresh.insert(index) }
                    switch (change, row) {
                    case (.files(let target), .files), (.message(let target), .message):
                        if target == id { refresh.insert(index) }
                    default: break
                    }
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                if oldRows.count - suffix > prefix || !inserted.isEmpty {
                    table.beginUpdates()
                    table.removeRows(at: IndexSet(integersIn: prefix..<(oldRows.count - suffix)), withAnimation: [])
                    table.insertRows(at: IndexSet(integersIn: inserted), withAnimation: [])
                    table.endUpdates()
                }
                if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                if !refresh.isEmpty { table.reloadData(forRowIndexes: refresh, columnIndexes: IndexSet(integer: 0)) }
            }
        }

        private func measureRows() {
            guard let content, let table = tableView else { return }
            measuredWidth = max(1, table.enclosingScrollView?.contentSize.width ?? table.bounds.width)
            heights = rows.map { row in
                let width = max(1, measuredWidth - graphColumns[row.commitIndex].contentX - 8)
                let commit = content.commits[row.commitIndex]
                switch row {
                case .commit:
                    return GitHistoryCell.height(commit: commit, refs: decorations(for: commit), width: width)
                default:
                    return GitHistoryDetailCell.height(for: childContent(for: row), width: width)
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
                cell.configure(commit: commit, graph: graph, graphLayout: graphColumns[item.commitIndex],
                               summary: (dateFormatter.string(from: commit.authoredAt), decorations(for: commit)),
                               state: (head: isHead(commit), expanded: content.expandedCommits[commit.id] != nil),
                               toggle: { [weak self] in self?.content?.onOpen(commit.id) },
                               contextMenu: { [weak self] in self?.makeContextMenu(commitID: commit.id) })
                return cell
            default:
                let cell = (tableView.makeView(withIdentifier: .init("git-child"), owner: nil) as? GitHistoryDetailCell) ?? GitHistoryDetailCell()
                cell.identifier = .init("git-child")
                let isLast = row + 1 == rows.count || rows[row + 1].commitIndex != item.commitIndex
                cell.configure(graph: graph, graphLayout: graphColumns[item.commitIndex], isLast: isLast,
                               content: childContent(for: item), action: { [weak self] in
                    self?.activateChild(item, commitID: commit.id)
                })
                return cell
            }
        }
        private func isHead(_ commit: GitHistoryCommit) -> Bool {
            if let head = content?.headCommitID { return head == commit.id }
            return commit.refDecorations.contains { $0.kind == .head || $0.kind == .currentBranch }
        }

        private func decorations(for commit: GitHistoryCommit) -> [GitRefDecoration] {
            var refs = commit.refDecorations.filter { $0.kind != .head }
            if isHead(commit) { refs.append(.init(name: "HEAD", kind: .head)) }
            return refs
        }

        private func childContent(for row: Row) -> GitHistoryDetailCell.Content {
            guard let content else { return .notice("", false) }
            let commit = content.commits[row.commitIndex]
            let details = content.expandedCommits[commit.id]
            switch row {
            case .files:
                return .files(details?.files.count ?? 0, details?.statistics, collapsedFiles.contains(commit.id))
            case .file(_, let file): return .file(file)
            case .message: return .message(details?.metadata?.body ?? "", messageExpansion[commit.id])
            default: return .notice(details?.error ?? "Loading changed files…", details?.error != nil)
            }
        }

        private func activateChild(_ row: Row, commitID: GitCommitID? = nil) {
            guard let content, let id = commitID ?? content.commits[safe: row.commitIndex]?.id,
                  let details = content.expandedCommits[id] else { return }
            switch row {
            case .files:
                if !collapsedFiles.insert(id).inserted { collapsedFiles.remove(id) }
            case .message:
                guard let index = content.commits.firstIndex(where: { $0.id == id }) else { return }
                let width = max(1, measuredWidth - graphColumns[index].contentX - 8)
                messageExpansion[id] = !GitHistoryDetailCell.messageIsExpanded(details.metadata?.body ?? "",
                    preference: messageExpansion[id], width: width)
            case .file(_, let file):
                guard details.files.contains(file) else { return }
                content.onOpenFile(id, file)
                return
            default: return
            }
            let change: LocalChange = if case .files = row { .files(id) } else { .message(id) }
            update(content, change: change)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = tableView, rows.indices.contains(table.selectedRow), let content else { return }
            content.onSelect(content.commits[rows[table.selectedRow].commitIndex].id)
        }
        func activateRow(_ index: Int, doubleClick: Bool) {
            guard let content, rows.indices.contains(index) else { return }
            switch rows[index] {
            case .commit(let commit) where doubleClick:
                content.onOpen(content.commits[commit].id)
            case .file(let commit, let file) where !doubleClick: content.onOpenFile(content.commits[commit].id, file)
            case .files where !doubleClick: activateChild(rows[index])
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
        func selectedCopyValue() -> String? {
            guard let table = tableView, rows.indices.contains(table.selectedRow), let content else { return nil }
            let row = rows[table.selectedRow]
            let commit = content.commits[row.commitIndex]
            switch row {
            case .file(_, let file): return file.path
            case .message: return content.expandedCommits[commit.id]?.metadata?.body
            default: return commit.subject
            }
        }
        func makeContextMenu(commitID: GitCommitID? = nil) -> NSMenu {
            let menu = GitHistoryContextMenu()
            menu.commitID = commitID
            menu.delegate = self
            return menu
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let menu = menu as? InspectorCopyMenu else { return }
            menu.removeAllItems()
            guard let table = tableView, let content else { return }
            let index: Int
            if let id = (menu as? GitHistoryContextMenu)?.commitID {
                guard let commitIndex = content.commits.firstIndex(where: { $0.id == id }),
                      let rowIndex = rows.firstIndex(where: { $0.commitIndex == commitIndex }) else { return }
                index = rowIndex
            } else { index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow }
            guard rows.indices.contains(index) else { return }
            let commit = content.commits[rows[index].commitIndex]
            menu.autoenablesItems = false
            for operation in GitCommitOperation.allCases {
                if operation == .details || operation == .cherryPick { menu.addItem(.separator()) }
                let item = NSMenuItem(title: operation.title, action: #selector(commitAction(_:)), keyEquivalent: "")
                item.target = self
                item.identifier = .init(operation.rawValue)
                item.representedObject = commit.id.rawValue
                item.isEnabled = !content.isBusy || !operation.modifiesRepository
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addCopyItems([("Copy Commit Hash", commit.id.rawValue)])
            var values = [("Copy subject", commit.subject), ("Copy author", commit.authorName),
                          ("Copy email", commit.authorEmail), ("Copy commit SHA", commit.id.rawValue),
                          ("Copy refs", decorations(for: commit).map(\.name).joined(separator: "\n"))]
            if let message = content.expandedCommits[commit.id]?.metadata?.message {
                values.append(("Copy full commit message", message))
            }
            if case .file(_, let file) = rows[index] { values.append(("Copy file path", file.path)) }
            let extra = NSMenuItem(title: "Copy More", action: nil, keyEquivalent: "")
            extra.submenu = InspectorCopyMenu(values: values.filter { !$0.1.isEmpty }, pasteboard: menu.pasteboard)
            menu.addItem(extra)
        }
        @objc private func commitAction(_ sender: NSMenuItem) {
            guard let raw = sender.identifier?.rawValue, let operation = GitCommitOperation(rawValue: raw),
                  let id = sender.representedObject as? String else { return }
            content?.onCommitAction(operation, GitCommitID(id))
        }
    }
}

private final class GitHistoryContextMenu: InspectorCopyMenu {
    var commitID: GitCommitID?
}
