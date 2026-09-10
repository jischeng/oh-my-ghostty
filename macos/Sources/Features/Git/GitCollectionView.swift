import AppKit
import SwiftUI

enum GitCollectionInteraction: Equatable { case changes, branches, picker }

final class GitCollectionController {
    var move: (Int) -> Void = { _ in }
    var activate: () -> Void = {}
}

final class GitCollectionTableView: InspectorCopyTableView {
    var moveSelection: (Int) -> Void = { _ in }
    var activateSelection: () -> Void = {}
    var cancel: () -> Void = {}
    var copySelection: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: moveSelection(-1)
        case 125: moveSelection(1)
        case 36, 76, 49: activateSelection()
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }
    @objc func copy(_ sender: Any?) { copySelection() }
}

/// All three Git collections use the same reusable native cells and row diff.
struct GitCollectionView: NSViewRepresentable {
    var source: GitCollectionSource
    var mode: GitCollectionMode = .list
    var query = ""
    var pending: Set<String> = []
    var canWrite = true
    var interaction: GitCollectionInteraction = .changes
    var state: GitCollectionState?
    var stateKey = ""
    var selectedID: String?
    var controller: GitCollectionController?
    var cancel: () -> Void = {}
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors

    func makeCoordinator() -> Coordinator { Coordinator() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = GitCollectionTableView()
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: .init("git-collection"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked)
        table.doubleAction = #selector(Coordinator.doubleClicked)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityIdentifier(stateKey)
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.saveAnchor() }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: GitCollectionTableView?
        private(set) var rows: [GitCollectionRow] = []
        private var nodes: [GitCollectionNode] = []
        private var input: GitCollectionView?
        private var fallbackState = GitCollectionState()
        private var filterCollapsed = Set<String>()
        private var updating = false
        private var state: GitCollectionState { input?.state ?? fallbackState }
        private var storageKey: String { (input?.stateKey ?? "") + "/" + (input?.mode.rawValue ?? "list") }

        func update(_ value: GitCollectionView) {
            let old = input
            let changedContext = old?.stateKey != value.stateKey
            let changedMode = old?.mode != value.mode
            let changedQuery = old?.query != value.query
            let rebuild = old?.source != value.source || changedMode || changedQuery || changedContext ||
                old?.pending != value.pending || old?.canWrite != value.canWrite
            if changedContext || changedMode { saveAnchor() }
            input = value
            guard let table else { return }
            table.cancel = value.cancel
            table.moveSelection = { [weak self] in self?.moveSelection($0) }
            table.activateSelection = { [weak self] in self?.activateSelected() }
            table.copySelection = { [weak self] in self?.copySelected() }
            table.copyValue = { [weak self] in self?.selectedCopyValue() }
            value.controller?.move = table.moveSelection
            value.controller?.activate = table.activateSelection
            if changedQuery { filterCollapsed.removeAll() }
            if rebuild {
                nodes = GitCollectionBuilder.nodes(source: value.source, mode: value.mode, query: value.query,
                                                   pending: value.pending, canWrite: value.canWrite)
                let collapsed = value.query.isEmpty ? state.collapsed[value.stateKey, default: []] : filterCollapsed
                let initial: String?
                if case .refs(let branches, _, _, _, _) = value.source { initial = branches.first(where: \.isCurrent)?.id } else { initial = nil }
                let selection = old == nil || changedContext || old?.selectedID != value.selectedID
                    ? value.selectedID ?? state.selected[value.stateKey] ?? initial
                    : state.selected[value.stateKey] ?? value.selectedID ?? initial
                apply(GitCollectionBuilder.rows(nodes, collapsed: collapsed), reset: changedContext || changedMode,
                      preferredSelection: selection)
                if value.interaction == .picker, old == nil || changedQuery, table.selectedRow >= 0 {
                    table.scrollRowToVisible(table.selectedRow)
                }
            }
            if old?.colors != value.colors {
                table.enumerateAvailableRowViews { view, index in
                    (view as? GitCollectionRowView)?.colors = value.colors
                    if self.rows.indices.contains(index), let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? GitCollectionCell {
                        self.configure(cell, row: self.rows[index])
                    }
                }
            }
            if value.selectedID != old?.selectedID, let selected = value.selectedID,
               let index = rows.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }

        func saveAnchor() {
            guard input != nil, let anchor = anchor() else { return }
            state.scrollAnchors[storageKey] = anchor
        }
        private func anchor() -> (id: String, offset: CGFloat)? {
            guard let table, !rows.isEmpty else { return nil }
            let index = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
            guard rows.indices.contains(index) else { return nil }
            return (rows[index].id, table.visibleRect.minY - table.rect(ofRow: index).minY)
        }
        private func restore(_ anchor: (id: String, offset: CGFloat)?) {
            guard let anchor, let table, let scroll = table.enclosingScrollView,
                  let index = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
            let y = table.rect(ofRow: index).minY + anchor.offset
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, max(0, table.bounds.height - scroll.contentSize.height)))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func apply(_ next: [GitCollectionRow], reset: Bool, preferredSelection: String?) {
            guard let table, let input else { return }
            let previous = rows
            let oldIDs = previous.map(\.id)
            let newIDs = next.map(\.id)
            var saved = reset ? state.scrollAnchors[storageKey] : anchor()
            if !reset, let top = saved, !newIDs.contains(top.id), let first = oldIDs.firstIndex(of: top.id) {
                let survivors = Set(newIDs)
                if let index = (first..<oldIDs.count).first(where: { survivors.contains(oldIDs[$0]) }) {
                    saved = (oldIDs[index], table.visibleRect.minY - table.rect(ofRow: index).minY)
                }
            }
            updating = true
            defer { updating = false }
            rows = next
            if reset || previous.isEmpty {
                table.reloadData()
            } else {
                var removed = IndexSet()
                var inserted = IndexSet()
                let oldSet = Set(oldIDs)
                let newSet = Set(newIDs)
                // Sorted collections retain the relative order of surviving
                // rows. Avoid a quadratic diff when an external `git add .`
                // moves thousands of entries between index sides at once.
                if oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains) {
                    for (index, id) in oldIDs.enumerated() where !newSet.contains(id) { removed.insert(index) }
                    for (index, id) in newIDs.enumerated() where !oldSet.contains(id) { inserted.insert(index) }
                } else {
                    for change in newIDs.difference(from: oldIDs) {
                        switch change {
                        case .remove(let index, _, _): removed.insert(index)
                        case .insert(let index, _, _): inserted.insert(index)
                        }
                    }
                }
                let oldRows = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
                var updated = IndexSet()
                var resized = IndexSet()
                for (index, row) in next.enumerated() where !inserted.contains(index) {
                    if oldRows[row.id] != row { updated.insert(index) }
                    if oldRows[row.id]?.height != row.height { resized.insert(index) }
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    if !removed.isEmpty || !inserted.isEmpty {
                        table.beginUpdates()
                        table.removeRows(at: removed, withAnimation: [])
                        table.insertRows(at: inserted, withAnimation: [])
                        table.endUpdates()
                    }
                    if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                    if !updated.isEmpty { table.reloadData(forRowIndexes: updated, columnIndexes: IndexSet(integer: 0)) }
                }
            }
            if let selected = preferredSelection, let index = rows.firstIndex(where: { $0.id == selected && $0.item.isSelectable }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else if input.interaction == .picker, let index = rows.firstIndex(where: { $0.item.isSelectable && !$0.item.isFolder && $0.item.enabled }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            if rows.indices.contains(table.selectedRow) {
                state.selected[input.stateKey] = rows[table.selectedRow].id
            }
            restore(saved)
        }

        func toggleFolder(_ id: String) {
            guard let input else { return }
            if input.query.isEmpty {
                if !state.collapsed[input.stateKey, default: []].insert(id).inserted { state.collapsed[input.stateKey]?.remove(id) }
            } else if !filterCollapsed.insert(id).inserted { filterCollapsed.remove(id) }
            let collapsed = input.query.isEmpty ? state.collapsed[input.stateKey, default: []] : filterCollapsed
            apply(GitCollectionBuilder.rows(nodes, collapsed: collapsed), reset: false, preferredSelection: id)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].item.isSelectable }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = GitCollectionRowView()
            view.colors = input?.colors ?? .init()
            view.showsHighlight = rows[row].item.isSelectable
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: .init("git-collection-row"), owner: nil) as? GitCollectionCell ?? GitCollectionCell()
            cell.identifier = .init("git-collection-row")
            configure(cell, row: rows[row])
            return cell
        }
        private func configure(_ cell: GitCollectionCell, row: GitCollectionRow) {
            cell.configure(row, colors: input?.colors ?? .init(), toggle: { [weak self] in self?.toggleFolder(row.id) }, stage: { [weak self] file, staged in
                self?.input?.perform(.setFileStaged(file, staged))
            })
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, rows.indices.contains(table.selectedRow), let input else { return }
            state.selected[input.stateKey] = rows[table.selectedRow].id
        }
        func moveSelection(_ direction: Int) {
            guard let table else { return }
            let start = table.selectedRow < 0 ? (direction > 0 ? -1 : rows.count) : table.selectedRow
            var index = start + direction
            while rows.indices.contains(index) {
                let item = rows[index].item
                if item.isSelectable && !item.isFolder && item.enabled {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    table.scrollRowToVisible(index)
                    return
                }
                index += direction
            }
        }
        @objc func clicked() {
            guard let table, rows.indices.contains(table.clickedRow), let input else { return }
            if input.interaction == .picker || input.interaction == .changes {
                if !rows[table.clickedRow].item.isFolder { activate(row: table.clickedRow) }
            }
        }
        @objc func doubleClicked() {
            guard let table else { return }
            if input?.interaction != .picker { activate(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) }
        }
        func activateSelected() { if let table { activate(row: table.selectedRow) } }
        func activate(row index: Int) {
            guard rows.indices.contains(index), let input else { return }
            let item = rows[index].item
            guard item.enabled else { return }
            switch item.kind {
            case .folder: toggleFolder(item.id)
            case .file(let file, let section): input.perform(.openDiff(file, section.target))
            case .branch(let branch, _):
                if input.interaction == .branches, worktreesAvailable, let occupied = worktrees.first(where: { $0.branchRef == branch.id }), occupied.canOpen {
                    input.perform(.openWorktree(occupied.path))
                } else { input.perform(.browseBranch(branch.id)) }
            case .worktree(let worktree):
                if input.interaction == .picker { input.perform(.browseWorktree(worktree.path)) } else if worktree.canOpen { input.perform(.openWorktree(worktree.path)) }
            case .scope(let scope): input.perform(.selectHistoryScope(scope))
            default: break
            }
        }
        private var worktrees: [GitWorktreeInfo] {
            guard case .refs(_, let trees, _, _, _) = input?.source else { return [] }
            return trees
        }
        private var worktreesAvailable: Bool {
            guard case .refs(_, _, _, _, let error) = input?.source else { return false }
            return error == nil
        }
        private func copySelected() {
            if let value = selectedCopyValue() { InspectorCopyMenu.copy(value) }
        }
        private func selectedCopyValue() -> String? {
            guard let table, rows.indices.contains(table.selectedRow) else { return nil }
            let item = rows[table.selectedRow].item
            let text: String
            switch item.kind {
            case .file(let file, _): text = file.path
            case .branch(let branch, _): text = branch.name
            case .worktree(let tree): text = tree.path
            default: text = item.title
            }
            return text
        }

        private enum MenuCommand { case action(InspectorGitAction), copy(String) }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menu.autoenablesItems = false
            guard let table, let input else { return }
            let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard rows.indices.contains(index) else { return }
            let item = rows[index].item
            func add(_ title: String, _ command: MenuCommand, enabled: Bool = true) {
                let value = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                value.target = self; value.representedObject = command; value.isEnabled = enabled
                menu.addItem(value)
            }
            switch item.kind {
            case .branch(let branch, _):
                let occupied = worktrees.first { $0.branchRef == branch.id }
                if let occupied { add("Open Worktree in New Tab", .action(.openWorktree(occupied.path)), enabled: worktreesAvailable && occupied.canOpen) }
                add("Show History", .action(.browseBranch(branch.id)), enabled: item.enabled)
                add("New Worktree from Here…", .action(.createWorktree(branch.id)), enabled: input.canWrite && worktreesAvailable && item.enabled)
                menu.addItem(.separator())
                add(branch.isRemote ? "Checkout Tracking Branch…" : "Switch Branch", .action(.branchOperation(.checkout, branch.id)),
                    enabled: input.canWrite && item.enabled && !branch.isCurrent && occupied == nil)
                add("New Branch from Here…", .action(.branchOperation(.create, branch.id)), enabled: input.canWrite && item.enabled)
                if !branch.isRemote {
                    add("Push…", .action(.branchOperation(.push, branch.id)), enabled: input.canWrite && item.enabled)
                    add("Set Upstream…", .action(.branchOperation(.setUpstream, branch.id)), enabled: input.canWrite && item.enabled)
                }
                menu.addItem(.separator())
                add("Copy Branch Name", .copy(branch.name))
            case .worktree(let tree):
                add("Open in New Tab", .action(.openWorktree(tree.path)), enabled: item.enabled && tree.canOpen)
                add("Copy Worktree Path", .copy(tree.path))
                add("Remove Worktree…", .action(.removeWorktree(tree.path)), enabled: input.canWrite && item.enabled && tree.canRemove)
            case .file(let file, let section):
                add(section == .staged ? "Unstage File" : "Stage File", .action(.setFileStaged(file, section != .staged)), enabled: item.enabled)
                add("Open Diff", .action(.openDiff(file, section.target)))
                add("Copy Path", .copy(file.path))
            default: break
            }
        }
        @objc private func menuAction(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MenuCommand else { return }
            switch command {
            case .action(let action): input?.perform(action)
            case .copy(let value): InspectorCopyMenu.copy(value)
            }
        }
    }
}
