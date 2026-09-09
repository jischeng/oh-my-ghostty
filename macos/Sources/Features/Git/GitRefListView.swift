import AppKit
import SwiftUI

/// Typed reference navigation. Selecting a leaf reveals its full name for
/// native selection/copy; folders never alter the underlying Git ref.
final class GitRefListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private(set) var refs: [GitRefDecoration] = []
    private(set) var roots: [GitReferenceNode] = []
    private(set) var tree = NSOutlineView()
    private let title = NSTextField(labelWithString: "References")
    private let scroll = NSScrollView()
    private let detailScroll = NSScrollView()
    private let detail = InspectorCopyableTextView()
    private let divider = NSBox()
    private var pendingScroll: Int?
    var pasteboard = NSPasteboard.general { didSet { detail.pasteboard = pasteboard } }
    override var isFlipped: Bool { true }

    static func height(for refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        min(380, max(180, CGFloat(refs.count + 4) * 26 + 80))
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let column = NSTableColumn(identifier: .init("ref"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        tree.addTableColumn(column)
        tree.outlineTableColumn = column
        tree.headerView = nil
        tree.backgroundColor = .clear
        tree.style = .plain
        tree.rowHeight = 24
        tree.intercellSpacing = .zero
        tree.indentationPerLevel = 12
        tree.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tree.dataSource = self
        tree.delegate = self
        let menu = InspectorCopyMenu()
        menu.delegate = self
        tree.menu = menu
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = tree
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = false
        detail.drawsBackground = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.textContainerInset = NSSize(width: 6, height: 5)
        detail.isHorizontallyResizable = false
        detail.isVerticallyResizable = true
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.documentView = detail
        divider.boxType = .separator
        [title, scroll, divider, detailScroll].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }

    func configure(_ refs: [GitRefDecoration], selected: GitRefDecoration? = nil) {
        guard self.refs != refs else { return }
        self.refs = refs
        roots = GitReferenceNode.build(refs)
        tree.reloadData()
        roots.forEach { tree.expandItem($0) }
        let target = selected ?? refs.first
        func path(in nodes: [GitReferenceNode]) -> [GitReferenceNode]? {
            for node in nodes {
                if node.ref == target { return [node] }
                if let rest = path(in: node.children) { return [node] + rest }
            }
            return nil
        }
        if let path = path(in: roots), let leaf = path.last {
            path.dropLast().forEach { tree.expandItem($0) }
            let index = tree.row(forItem: leaf)
            if index >= 0 {
                tree.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                pendingScroll = index
            }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard bounds.width > 12, bounds.height > 100 else { return }
        title.frame = NSRect(x: 10, y: 8, width: bounds.width - 20, height: 18)
        scroll.frame = NSRect(x: 6, y: 32, width: bounds.width - 12, height: max(1, bounds.height - 100))
        tree.setFrameSize(NSSize(width: scroll.contentSize.width, height: tree.frame.height))
        tree.tableColumns.first?.width = scroll.contentSize.width
        if let row = pendingScroll { pendingScroll = nil; tree.scrollRowToVisible(row) }
        divider.frame = NSRect(x: 10, y: bounds.height - 62, width: bounds.width - 20, height: 1)
        detailScroll.frame = NSRect(x: 6, y: bounds.height - 58, width: bounds.width - 12, height: 52)
        detail.setFrameSize(NSSize(width: detailScroll.contentSize.width, height: max(52, detail.frame.height)))
        if let container = detail.textContainer, let manager = detail.layoutManager {
            manager.ensureLayout(for: container)
            detail.setFrameSize(NSSize(width: detailScroll.contentSize.width, height: max(52, manager.usedRect(for: container).height + 10)))
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorCommandRouter.shared.unregister(owner: self)
        guard window != nil else { return }
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self.tree,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c",
                  let ref = (self.tree.item(atRow: self.tree.selectedRow) as? GitReferenceNode)?.ref else { return false }
            InspectorCopyMenu.copy(ref.name, to: self.pasteboard)
            return true
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? GitReferenceNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? GitReferenceNode)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? GitReferenceNode)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? GitReferenceNode else { return false }
        return node.isSection && node.ref == nil
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? GitReferenceNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title)
        label.font = .systemFont(ofSize: 11, weight: node.isSection ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = NSImageView()
        let kind = node.ref?.kind ?? node.kind
        let symbol = node.ref != nil || node.isSection ? GitRefBadgesView.symbol(for: kind) : "folder"
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        icon.contentTintColor = GitRefBadgesView.tint(for: kind)
        label.textColor = node.isSection ? .secondaryLabelColor : GitRefBadgesView.tint(for: kind)
        [icon, label].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.widthAnchor.constraint(equalToConstant: 14),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = node.ref?.name ?? node.title
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        detail.string = (tree.item(atRow: tree.selectedRow) as? GitReferenceNode)?.ref?.name ?? "Select a reference to view its full name."
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        needsLayout = true
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let menu = menu as? InspectorCopyMenu else { return }
        menu.removeAllItems()
        let row = tree.clickedRow >= 0 ? tree.clickedRow : tree.selectedRow
        guard let ref = (tree.item(atRow: row) as? GitReferenceNode)?.ref else { return }
        menu.pasteboard = pasteboard
        menu.addCopyItems([("Copy full ref name", ref.name)])
    }
}

struct GitRefBadgeRow: NSViewRepresentable {
    let refs: [GitRefDecoration]
    func makeNSView(context: Context) -> GitRefBadgesView { GitRefBadgesView() }
    func updateNSView(_ view: GitRefBadgesView, context: Context) { view.configure(refs) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitRefBadgesView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: refs.isEmpty ? 0 : 17)
    }
}

struct InspectorCopyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> InspectorCopyableTextField {
        let view = InspectorCopyableTextField(labelWithString: "")
        view.isSelectable = true
        view.font = .systemFont(ofSize: 10)
        view.textColor = .secondaryLabelColor
        view.lineBreakMode = .byTruncatingMiddle
        view.maximumNumberOfLines = 1
        return view
    }
    func updateNSView(_ view: InspectorCopyableTextField, context: Context) {
        if view.stringValue != text { view.stringValue = text }
        view.toolTip = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorCopyableTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 14)
    }
}
