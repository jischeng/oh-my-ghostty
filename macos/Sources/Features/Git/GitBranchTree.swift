import AppKit
import SwiftUI

final class GitBranchNode: NSObject {
    let id: String
    let title: String
    var branch: GitBranchInfo?
    var children: [GitBranchNode] = []

    init(id: String, title: String, branch: GitBranchInfo? = nil) {
        self.id = id; self.title = title; self.branch = branch
    }

    static func build(_ branches: [GitBranchInfo]) -> [GitBranchNode] {
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
        return [local, remote]
    }
}

struct GitBranchTree: NSViewRepresentable {
    let branches: [GitBranchInfo]
    let isBusy: Bool
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
        context.coordinator.update(branches: branches, isBusy: isBusy, perform: perform)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(branches: branches, isBusy: isBusy, perform: perform)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var tree: NSOutlineView?
        private var roots: [GitBranchNode] = []
        private var branches: [GitBranchInfo] = []
        private var busy = false
        private var perform: (InspectorGitAction) -> Void
        init(perform: @escaping (InspectorGitAction) -> Void) { self.perform = perform }

        func update(branches: [GitBranchInfo], isBusy: Bool, perform: @escaping (InspectorGitAction) -> Void) {
            self.perform = perform
            busy = isBusy
            guard self.branches != branches || roots.isEmpty, let tree else { return }
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
            roots = GitBranchNode.build(branches)
            tree.reloadData()
            func containsCurrent(_ node: GitBranchNode) -> Bool {
                node.branch?.isCurrent == true || node.children.contains(where: containsCurrent)
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
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? GitBranchNode else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView()
            let name = NSTextField(labelWithString: node.title)
            name.font = .systemFont(ofSize: 11, weight: node.branch?.isCurrent == true ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let symbol = node.branch.map { $0.isCurrent ? "checkmark.circle.fill" : ($0.isRemote ? "network" : "arrow.triangle.branch") }
                ?? (node.id == "remote" ? "network" : "folder")
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            icon.contentTintColor = node.branch?.isCurrent == true ? .controlAccentColor : .secondaryLabelColor
            for view in [icon, name] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 14),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.toolTip = node.branch.map { "\($0.name)\n\($0.upstream) \($0.tracking)" } ?? node.title
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
            if let branch = node.branch { perform(.browseBranch(branch.id)) } else if tree.isItemExpanded(node) { tree.collapseItem(node) } else { tree.expandItem(node) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let branch = clickedBranch else { return }
            func add(_ title: String, action: Selector, tag: Int = 0, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.tag = tag; item.isEnabled = enabled
                item.representedObject = branch.id
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            add("Show History", action: #selector(historyFromMenu(_:)))
            menu.addItem(.separator())
            add(branch.isRemote ? "Checkout Tracking Branch…" : "Switch Branch",
                action: #selector(branchAction(_:)), tag: 0, enabled: !busy && !branch.isCurrent)
            add("New Branch from Here…", action: #selector(branchAction(_:)), tag: 1, enabled: !busy)
            if !branch.isRemote {
                add("Push…", action: #selector(branchAction(_:)), tag: 2, enabled: !busy)
                add("Set Upstream…", action: #selector(branchAction(_:)), tag: 3, enabled: !busy)
            }
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
