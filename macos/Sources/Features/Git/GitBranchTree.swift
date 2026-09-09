import AppKit
import SwiftUI

final class GitBranchNode: NSObject {
    let id: String
    let title: String
    var branch: GitBranchInfo?
    var worktree: GitWorktreeInfo?
    var children: [GitBranchNode] = []

    init(id: String, title: String, branch: GitBranchInfo? = nil) {
        self.id = id; self.title = title; self.branch = branch
    }

    static func build(_ branches: [GitBranchInfo], worktrees: [GitWorktreeInfo] = []) -> [GitBranchNode] {
        let local = GitBranchNode(id: "local", title: "Local")
        let remote = GitBranchNode(id: "remote", title: "Remotes")
        for branch in branches.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            var node = branch.isRemote ? remote : local
            let parts = branch.name.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                let leaf = index == parts.count - 1
                let id = leaf ? branch.id : node.id + "/" + part
                if let existing = node.children.first(where: { $0.id == id }) { node = existing } else {
                    let child = GitBranchNode(id: id, title: part, branch: leaf ? branch : nil)
                    node.children.append(child)
                    node = child
                }
            }
        }
        guard !worktrees.isEmpty else { return [local, remote] }
        let group = GitBranchNode(id: "worktrees", title: "Worktrees")
        group.children = worktrees.map { worktree in
            let name = (worktree.path as NSString).lastPathComponent
            let node = GitBranchNode(id: "worktree:" + worktree.path, title: worktree.branchName + " · " + name)
            node.worktree = worktree
            return node
        }
        return [local, remote, group]
    }
}

struct GitBranchTree: NSViewRepresentable {
    let branches: [GitBranchInfo]
    var worktrees: [GitWorktreeInfo] = []
    let isBusy: Bool
    var branchesAvailable = true
    var worktreesAvailable = true
    let perform: (InspectorGitAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(perform: perform) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tree = NSOutlineView()
        let column = NSTableColumn(identifier: .init("branches"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        tree.addTableColumn(column)
        tree.outlineTableColumn = column
        tree.headerView = nil
        tree.rowHeight = 25
        tree.indentationPerLevel = 12
        tree.backgroundColor = .clear
        tree.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tree.dataSource = context.coordinator
        tree.delegate = context.coordinator
        tree.target = context.coordinator
        tree.doubleAction = #selector(Coordinator.openHistory)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tree.menu = menu
        scroll.documentView = tree
        context.coordinator.tree = tree
        context.coordinator.update(branches: branches, worktrees: worktrees, isBusy: isBusy,
                                   branchesAvailable: branchesAvailable, worktreesAvailable: worktreesAvailable, perform: perform)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(branches: branches, worktrees: worktrees, isBusy: isBusy,
                                   branchesAvailable: branchesAvailable, worktreesAvailable: worktreesAvailable, perform: perform)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var tree: NSOutlineView?
        private var roots: [GitBranchNode] = []
        private var branches: [GitBranchInfo] = []
        private var worktrees: [GitWorktreeInfo] = []
        private var busy = false
        private var branchesAvailable = true
        private var worktreesAvailable = true
        private var perform: (InspectorGitAction) -> Void
        init(perform: @escaping (InspectorGitAction) -> Void) { self.perform = perform }

        func update(branches: [GitBranchInfo], worktrees: [GitWorktreeInfo], isBusy: Bool,
                    branchesAvailable: Bool, worktreesAvailable: Bool, perform: @escaping (InspectorGitAction) -> Void) {
            self.perform = perform
            busy = isBusy
            self.branchesAvailable = branchesAvailable
            self.worktreesAvailable = worktreesAvailable
            guard self.branches != branches || self.worktrees != worktrees || roots.isEmpty, let tree else { return }
            let selected = (tree.item(atRow: tree.selectedRow) as? GitBranchNode)?.id
            var expanded = Set<String>()
            func visit(_ nodes: [GitBranchNode]) {
                for node in nodes {
                    if tree.isItemExpanded(node) { expanded.insert(node.id) }
                    visit(node.children)
                }
            }
            visit(roots)
            let first = self.branches.isEmpty
            self.branches = branches
            self.worktrees = worktrees
            roots = GitBranchNode.build(branches, worktrees: worktrees)
            tree.reloadData()
            func containsCurrent(_ node: GitBranchNode) -> Bool {
                node.branch?.isCurrent == true || node.worktree?.isCurrent == true || node.children.contains(where: containsCurrent)
            }
            func restore(_ nodes: [GitBranchNode]) {
                for node in nodes {
                    if expanded.contains(node.id) || (first && node.branch == nil && (!node.id.contains("/") || containsCurrent(node))) {
                        tree.expandItem(node)
                    }
                    if node.id == selected || (first && node.branch?.isCurrent == true), tree.row(forItem: node) >= 0 {
                        tree.selectRowIndexes(IndexSet(integer: tree.row(forItem: node)), byExtendingSelection: false)
                    }
                    restore(node.children)
                }
            }
            restore(roots)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? GitBranchNode)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? GitBranchNode)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !(item as? GitBranchNode)!.children.isEmpty
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? GitBranchNode)?.worktree == nil ? 25 : 42
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? GitBranchNode else { return nil }
            if let worktree = node.worktree { return GitWorktreeCell(worktree) }
            let cell = NSTableCellView()
            let icon = NSImageView()
            let occupied = node.branch.flatMap { branch in worktrees.first { $0.branchRef == branch.id } }
            let name = NSTextField(labelWithString: node.title + (occupied == nil ? "" : " · worktree"))
            name.font = .systemFont(ofSize: 11, weight: node.branch?.isCurrent == true || node.worktree?.isCurrent == true ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let symbol = node.worktree.map { $0.isCurrent ? "checkmark.circle.fill" : ($0.lockedReason != nil ? "lock.fill" : "folder") }
                ?? node.branch.map { $0.isCurrent ? "checkmark.circle.fill" : ($0.isRemote ? "network" : "arrow.triangle.branch") }
                ?? (node.id == "remote" ? "network" : "folder")
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            icon.contentTintColor = node.branch?.isCurrent == true || node.worktree?.isCurrent == true ? .controlAccentColor : .secondaryLabelColor
            for view in [icon, name] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 14),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.toolTip = node.branch.map { "\($0.name)\n\($0.upstream) \($0.tracking)" } ?? node.title
            if let occupied { cell.toolTip = (cell.toolTip ?? "") + "\nWorktree: " + occupied.path }
            return cell
        }

        private var clickedBranch: GitBranchInfo? {
            guard let tree else { return nil }
            let row = tree.clickedRow >= 0 ? tree.clickedRow : tree.selectedRow
            return (tree.item(atRow: row) as? GitBranchNode)?.branch
        }

        @objc func openHistory() {
            guard let tree else { return }
            let row = tree.clickedRow >= 0 ? tree.clickedRow : tree.selectedRow
            guard let node = tree.item(atRow: row) as? GitBranchNode else { return }
            if let worktree = node.worktree {
                if worktreesAvailable && worktree.canOpen { perform(.openWorktree(worktree.path)) }
            } else if let branch = node.branch {
                if worktreesAvailable, let occupied = worktrees.first(where: { $0.branchRef == branch.id }), occupied.canOpen {
                    perform(.openWorktree(occupied.path))
                } else if branchesAvailable { perform(.browseBranch(branch.id)) }
            } else if tree.isItemExpanded(node) { tree.collapseItem(node) } else { tree.expandItem(node) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tree else { return }
            let row = tree.clickedRow >= 0 ? tree.clickedRow : tree.selectedRow
            if let worktree = (tree.item(atRow: row) as? GitBranchNode)?.worktree {
                worktreeMenu(menu, worktree: worktree)
                return
            }
            guard let branch = clickedBranch else { return }
            func add(_ title: String, action: Selector, tag: Int = 0, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.tag = tag; item.isEnabled = enabled
                item.representedObject = branch.id
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            let occupied = worktrees.first { $0.branchRef == branch.id }
            if let occupied {
                let item = NSMenuItem(title: "Open Worktree in New Tab", action: #selector(worktreeAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = occupied.path; item.tag = 0
                item.isEnabled = worktreesAvailable && occupied.canOpen
                menu.addItem(item)
            }
            add("Show History", action: #selector(historyFromMenu(_:)), enabled: branchesAvailable)
            add("New Worktree from Here…", action: #selector(createWorktree(_:)), enabled: !busy && branchesAvailable && worktreesAvailable)
            menu.addItem(.separator())
            add(branch.isRemote ? "Checkout Tracking Branch…" : "Switch Branch",
                action: #selector(branchAction(_:)), tag: 0, enabled: !busy && branchesAvailable && !branch.isCurrent && occupied == nil)
            add("New Branch from Here…", action: #selector(branchAction(_:)), tag: 1, enabled: !busy && branchesAvailable)
            if !branch.isRemote {
                add("Push…", action: #selector(branchAction(_:)), tag: 2, enabled: !busy && branchesAvailable)
                add("Set Upstream…", action: #selector(branchAction(_:)), tag: 3, enabled: !busy && branchesAvailable)
            }
        }

        private func worktreeMenu(_ menu: NSMenu, worktree: GitWorktreeInfo) {
            menu.autoenablesItems = false
            for (index, title) in ["Open in New Tab", "Copy Worktree Path", "Remove Worktree…"].enumerated() {
                let item = NSMenuItem(title: title, action: #selector(worktreeAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; item.representedObject = worktree.path
                item.isEnabled = index == 1 || (worktreesAvailable && (index == 0 ? worktree.canOpen : !busy && worktree.canRemove))
                menu.addItem(item)
            }
        }

        @objc private func worktreeAction(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            switch sender.tag {
            case 0: perform(.openWorktree(path))
            case 1: InspectorCopyMenu.copy(path)
            case 2: perform(.removeWorktree(path))
            default: break
            }
        }
        @objc private func createWorktree(_ sender: NSMenuItem) {
            if let ref = sender.representedObject as? String { perform(.createWorktree(ref)) }
        }

        @objc private func historyFromMenu(_ sender: NSMenuItem) {
            if let ref = sender.representedObject as? String { perform(.browseBranch(ref)) }
        }
        @objc private func branchAction(_ sender: NSMenuItem) {
            let operations: [GitBranchOperation] = [.checkout, .create, .push, .setUpstream]
            guard !busy, operations.indices.contains(sender.tag), let ref = sender.representedObject as? String else { return }
            perform(.branchOperation(operations[sender.tag], ref))
        }
    }
}

private final class GitWorktreeCell: NSTableCellView {
    init(_ worktree: GitWorktreeInfo) {
        super.init(frame: .zero)
        let states = [worktree.isCurrent ? "current" : nil, worktree.isDirty == true ? "dirty" : nil,
                      worktree.statusError != nil ? "status unavailable" : nil].compactMap { $0 }
        let title = NSTextField(labelWithString: ([worktree.branchName] + states).joined(separator: " · "))
        title.font = .systemFont(ofSize: 11, weight: worktree.isCurrent ? .semibold : .regular)
        let path = NSTextField(labelWithString: worktree.path)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        let symbol = worktree.isCurrent ? "checkmark.circle.fill" : (worktree.lockedReason != nil ? "lock.fill" : "folder")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = worktree.isDirty == true ? .systemOrange : (worktree.isCurrent ? .controlAccentColor : .secondaryLabelColor)
        for field in [title, path] { field.lineBreakMode = .byTruncatingMiddle; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for view in [icon, title, path] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5), title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor), path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            path.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
        toolTip = ([worktree.path, worktree.branchName] + states + [worktree.lockedReason, worktree.prunableReason, worktree.statusError].compactMap { $0 }).joined(separator: "\n")
        setAccessibilityLabel(toolTip)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
