import AppKit
import Combine
import SwiftUI

/// Row geometry of the tab list. The Tabs view follows the row density
/// setting; the inbox has roomier rows.
struct NativeTabRowMetrics: Equatable {
    /// Height of a tab row with a title only.
    var rowHeight: CGFloat
    /// Height of a section header row.
    var headerHeight: CGFloat
    var titleFontSize: CGFloat = 13
    var headerFontSize: CGFloat = 11
    var subtitleFontSize: CGFloat = 11
    /// Height of the subtitle's line of text at `subtitleFontSize`.
    var subtitleLineHeight: CGFloat = 14
    /// Gap between the title and the subtitle below it.
    var subtitleSpacing: CGFloat = 0
    /// Rows of a group start at the list's edge instead of under its header,
    /// and a header without an icon of its own shows none.
    var flattensGroups = false
    /// The subtitle starts under the icon and runs the width of the row.
    var subtitleSpansRow = false
    /// A row with a name and a subtitle sets the name slightly heavier.
    var emphasizesNames = false
    var shortcutFontSize: CGFloat = 10

    /// What a row gains for its subtitle.
    var subtitleBlockHeight: CGFloat { subtitleSpacing + subtitleLineHeight }
    var twoLineRowHeight: CGFloat { rowHeight + subtitleBlockHeight }

    func height(twoLine: Bool) -> CGFloat { twoLine ? twoLineRowHeight : rowHeight }

    /// The Tabs view: every row follows `tabs.rowDensity`.
    static func tabs(rowHeight: CGFloat) -> Self {
        .init(rowHeight: rowHeight, headerHeight: rowHeight)
    }

    /// The inbox: 38 pt rows, 58 pt with a subtitle, laid out flat so a name
    /// and the place below it have the whole row.
    static let inbox = Self(rowHeight: 38, headerHeight: 30, titleFontSize: 14, headerFontSize: 12,
                            subtitleFontSize: 12, subtitleLineHeight: 16, subtitleSpacing: 4,
                            flattensGroups: true, subtitleSpansRow: true, emphasizesNames: true,
                            shortcutFontSize: 11)
}

/// AppKit presentation over the existing native-window tab model.
/// Stable nodes keep selection-only updates from rebuilding the outline.
struct NativeTabOutlineConfiguration {
    let groups: [GhosttyTabGroupPresentation]
    let selectedID: ObjectIdentifier?
    let layoutState: VerticalTabWindowLayoutState
    let controller: TerminalController
    let metrics: NativeTabRowMetrics
    /// False while the rows show a display-only order (the inbox): no row can
    /// be dragged and no drop can be placed relative to a row.
    var allowsReordering = true
    /// A cheap answer to "does this tab's row have a subtitle", asked for every
    /// tab on every update. Without it the full presentation is resolved.
    var showsSubtitle: ((GhosttyOrganizedTab) -> Bool)?
    let presentation: (GhosttyOrganizedTab) -> GhosttyTabPresentation?

    func isTwoLine(_ tab: GhosttyOrganizedTab) -> Bool {
        showsSubtitle?(tab) ?? (presentation(tab)?.showsSubtitle == true)
    }
}

@MainActor
final class NativeTabNode: NSObject {
    let key: String
    var title: String?
    var icon: GhosttyTabIcon?
    var tab: GhosttyOrganizedTab?
    var count: Int?
    /// The row shows a subtitle below its title and is taller for it.
    var isTwoLine = false
    var children: [NativeTabNode] = []
    init(key: String) { self.key = key }
}

@MainActor
final class NativeTabOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let tabType = NSPasteboard.PasteboardType("com.jischeng.omg.native-sidebar-tab")
    let outline: NativeTabOutline
    let scrollView = NSScrollView()
    var configuration: NativeTabOutlineConfiguration
    var roots: [NativeTabNode] = []
    var nodes: [String: NativeTabNode] = [:]
    var structure: [String] = []
    var updating = false
    var lastSelectedID: ObjectIdentifier?
    private var selectionChangeGeneration = 0
    private(set) var reloadCount = 0
    private(set) var moveCount = 0
    private(set) var membershipUpdateCount = 0
    private(set) var heightUpdateCount = 0
    private var pointer: NativeTabListPointer?
    private var pendingHeightNodes: [NativeTabNode] = []
    /// The pointer left the list; a held display order can be applied.
    var pointerDidLeave: (() -> Void)?
    /// Test seam for the pointer state, which needs a real desktop pointer.
    var holdsOrderOverride: Bool?

    /// Rows should not move under an active pointer. Reordering by the user's
    /// own drag is unaffected; this only concerns orders that change by themselves.
    var isPointerHoldingOrder: Bool { holdsOrderOverride ?? pointer?.holdsOrder ?? false }

    /// Insert/delete without reloading existing cells when survivor order is
    /// unchanged (the normal new-tab/close-tab path).
    private func updateMembership(from old: [String], to new: [String], parent: NativeTabNode?) -> Bool {
        guard old != new else { return true }
        let oldSet = Set(old)
        let newSet = Set(new)
        guard old.filter(newSet.contains) == new.filter(oldSet.contains) else { return false }
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
        let inserted = IndexSet(new.indices.filter { !oldSet.contains(new[$0]) })
        guard !removed.isEmpty || !inserted.isEmpty else { return false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outline.beginUpdates()
            if !removed.isEmpty { outline.removeItems(at: removed, inParent: parent, withAnimation: []) }
            if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: parent, withAnimation: []) }
            outline.endUpdates()
        }
        membershipUpdateCount += 1
        return true
    }

    /// Recognize one drag move in either direction, rather than shifting all
    /// intervening rows. AppKit owns the row movement and selection tracking.
    static func singleMove(from old: [String], to new: [String]) -> (Int, Int)? {
        guard old.count == new.count, Set(old) == Set(new), old != new,
              let first = old.indices.first(where: { old[$0] != new[$0] }) else { return nil }
        for source in [first, old.firstIndex(of: new[first])].compactMap({ $0 }) {
            guard let destination = new.firstIndex(of: old[source]) else { continue }
            var candidate = old
            candidate.insert(candidate.remove(at: source), at: destination)
            if candidate == new { return (source, destination) }
        }
        return nil
    }

    init(_ parent: NativeTabOutlineConfiguration) {
        self.configuration = parent
        outline = NativeTabOutline()
        super.init(nibName: nil, bundle: nil)
        outline.activateSelectedRow = { [weak self] in self?.activateSelectedRow() }
        outline.didBeginMouseTracking = { [weak self] in self?.selectionChangeGeneration += 1 }
        outline.didBeginDrag = { [weak self] in self?.selectionChangeGeneration += 1 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let scroll = scrollView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        outline.autoresizingMask = [.width]
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        // Source-list style installs a system material behind the terminal's
        // transparent theme. Keep native table interaction without that material.
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(activateClickedRow)
        outline.registerForDraggedTypes([Self.tabType, .ghosttySurfaceId])
        outline.contextMenu = { [weak self] row in self?.menu(for: row) }
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel(ChromeStrings.current.tabs)
        scroll.documentView = outline
        view = scroll
        let pointer = NativeTabListPointer(view: scroll)
        pointer.onExit = { [weak self] in self?.pointerDidLeave?() }
        self.pointer = pointer
    }

    private func activateSelectedRow() {
        activate(row: outline.selectedRow)
    }

    @objc private func activateClickedRow() {
        guard let item = outline.item(atRow: outline.clickedRow) as? NativeTabNode else { return }
        let generation = selectionChangeGeneration
        // Main-queue blocks can run inside AppKit's mouse/drag tracking loop.
        // Moving the live outline to another tab there strands that loop.
        RunLoop.main.perform(inModes: [.default]) { [weak self, weak item] in
            guard let self, self.selectionChangeGeneration == generation,
                  let item,
                  !self.outline.isDraggingTab else { return }
            self.activate(row: self.outline.row(forItem: item))
        }
    }

    private func activate(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) as? NativeTabNode,
              let tab = item.tab else { return }
        let controller = tab.controller
        selectionChangeGeneration += 1
        lastSelectedID = tab.id
        controller.selectVerticalTab(controller)
        if let surface = controller.focusedSurface ?? controller.surfaceTree.first {
            Ghostty.moveFocus(to: surface)
        }
    }

    func update(_ value: NativeTabOutlineConfiguration) {
        let metricsChanged = configuration.metrics != value.metrics
        configuration = value
        outline.setAccessibilityLabel(ChromeStrings.current.tabs)
        updating = true
        defer { updating = false }
        let oldRoots = roots.map(\.key)
        let oldChildren = Dictionary(uniqueKeysWithValues: roots.filter { $0.tab == nil }.map {
            ($0.key, $0.children.map(\.key))
        })
        var nextNodes: [String: NativeTabNode] = [:]
        var nextRoots: [NativeTabNode] = []
        var nextStructure: [String] = []
        var resized: [NativeTabNode] = []
        func node(_ key: String) -> NativeTabNode {
            let result = nodes[key] ?? NativeTabNode(key: key)
            nextNodes[key] = result
            return result
        }
        for group in value.groups {
            let children = group.tabs.map { tab -> NativeTabNode in
                let key = "tab:\(tab.controller.tabSessionID)"
                let known = nodes[key] != nil
                let item = node(key)
                item.tab = tab
                // New rows get their height from the delegate on insertion;
                // rows already in the outline need an explicit height update.
                let twoLine = value.isTwoLine(tab)
                if item.isTwoLine != twoLine {
                    item.isTwoLine = twoLine
                    if known { resized.append(item) }
                }
                nextStructure.append("\(group.id)/\(item.key)")
                return item
            }
            if let title = group.title {
                let item = node("group:\(group.id)")
                item.title = title
                item.icon = group.icon
                item.count = group.count
                item.children = children
                nextRoots.append(item)
                nextStructure.append(item.key)
            } else {
                nextRoots.append(contentsOf: children)
            }
        }
        roots = nextRoots
        nodes = nextNodes
        // Flat <-> grouped transitions always take the reload path below, so
        // existing cell views pick up the new leading inset.
        outline.reservesDisclosureSpace = roots.contains { $0.tab == nil }
        outline.flattensGroupRows = value.metrics.flattensGroups
        outline.rowHeight = value.metrics.rowHeight
        if structure != nextStructure {
            structure = nextStructure
            let newRoots = roots.map(\.key)
            let changedGroups = roots.filter {
                $0.tab == nil && oldChildren[$0.key] != $0.children.map(\.key)
            }
            if oldChildren.isEmpty, roots.allSatisfy({ $0.tab != nil }),
               let (source, destination) = Self.singleMove(from: oldRoots, to: newRoots) {
                outline.moveItem(at: source, inParent: nil, to: destination, inParent: nil)
                moveCount += 1
            } else if oldRoots == newRoots, changedGroups.count == 1,
                      let group = changedGroups.first, let old = oldChildren[group.key],
                      let (source, destination) = Self.singleMove(from: old, to: group.children.map(\.key)) {
                outline.moveItem(at: source, inParent: group, to: destination, inParent: group)
                moveCount += 1
            } else if oldChildren.isEmpty, roots.allSatisfy({ $0.tab != nil }),
                      updateMembership(from: oldRoots, to: newRoots, parent: nil) {
                // Native insertion/removal preserves existing row views.
            } else if oldRoots == newRoots, changedGroups.count == 1,
                      let group = changedGroups.first, let old = oldChildren[group.key],
                      updateMembership(from: old, to: group.children.map(\.key), parent: group) {
                // Same operation inside an existing project/date group.
            } else {
                outline.reloadData()
                reloadCount += 1
            }
        }
        for group in value.groups where group.title != nil {
            guard let item = nodes["group:\(group.id)"] else { continue }
            let selected = group.tabs.contains { ObjectIdentifier($0.controller) == value.selectedID }
            if !value.layoutState.collapsedGroupIDs.contains(group.id) || selected {
                outline.expandItem(item)
            } else {
                outline.collapseItem(item)
            }
        }
        if metricsChanged, outline.numberOfRows > 0 {
            noteHeights(IndexSet(integersIn: 0..<outline.numberOfRows))
        } else {
            noteHeights(IndexSet(resized.map { outline.row(forItem: $0) }.filter { $0 >= 0 }))
        }
        if let selected = nodes.values.first(where: {
            $0.tab.map { ObjectIdentifier($0.controller) == value.selectedID } ?? false
        }) {
            let row = outline.row(forItem: selected)
            if row >= 0 {
                if outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                let rowRect = outline.rect(ofRow: row)
                let outsideViewport = rowRect.minY < outline.visibleRect.minY ||
                    rowRect.maxY > outline.visibleRect.maxY
                if lastSelectedID != value.selectedID, outsideViewport,
                   !value.layoutState.sidebarHost.restorePendingScrollPosition() {
                    outline.scrollRowToVisible(row)
                }
            }
        }
        lastSelectedID = value.selectedID
        outline.enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
        // Update only instantiated cells; offscreen rows are configured on demand.
        let visible = outline.rows(in: outline.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<NSMaxRange(visible) {
                guard let item = outline.item(atRow: row) as? NativeTabNode,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeTabCell else {
                    continue
                }
                configure(cell, item: item)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NativeTabNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? NativeTabNode)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NativeTabNode)?.tab == nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { NativeTabRowView() }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let metrics = configuration.metrics
        guard let node = item as? NativeTabNode else { return metrics.rowHeight }
        return node.tab == nil ? metrics.headerHeight : metrics.height(twoLine: node.isTwoLine)
    }

    private func noteHeights(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outline.noteHeightOfRows(withIndexesChanged: rows)
        }
        heightUpdateCount += 1
        // Rows moved without a pointer event; re-evaluate the hovered row.
        outline.refreshHover()
    }

    /// A cell refreshes itself when its tab changes. When that adds or removes
    /// the subtitle, its row height follows without a sidebar refresh.
    private func rowLayoutChanged(_ item: NativeTabNode?) {
        guard let item else { return }
        pendingHeightNodes.append(item)
        guard pendingHeightNodes.count == 1 else { return }
        // Never resize rows from inside the table's own layout pass.
        DispatchQueue.main.async { [weak self] in self?.syncPendingRowHeights() }
    }

    private func syncPendingRowHeights() {
        let pending = pendingHeightNodes
        pendingHeightNodes.removeAll()
        var rows = IndexSet()
        for node in pending {
            guard nodes[node.key] === node, let tab = node.tab else { continue }
            let twoLine = configuration.isTwoLine(tab)
            guard node.isTwoLine != twoLine else { continue }
            node.isTwoLine = twoLine
            let row = outline.row(forItem: node)
            if row >= 0 { rows.insert(row) }
        }
        noteHeights(rows)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NativeTabNode)?.tab != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NativeTabNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("native-tab-cell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NativeTabCell) ?? NativeTabCell()
        cell.identifier = identifier
        configure(cell, item: item)
        return cell
    }

    private func configure(_ cell: NativeTabCell, item: NativeTabNode) {
        cell.configure(tab: item.tab, title: item.title, presentation: configuration.presentation,
                       groupIcon: item.icon, count: item.count, metrics: configuration.metrics,
                       canClose: configuration.groups.reduce(0) { $0 + $1.tabs.count } > 1,
                       selected: item.tab?.id == configuration.selectedID,
                       select: { [weak self, weak item] in
            guard let self, let item else { return }
            self.activate(row: self.outline.row(forItem: item))
        }, close: { [weak self, weak item] in
            guard let self, let tab = item?.tab else { return }
            self.configuration.controller.closeVerticalTab(tab.controller)
        }, layoutChanged: { [weak self, weak item] in
            self?.rowLayoutChanged(item)
        })
    }

    private func menu(for row: Int) -> NSMenu? {
        guard let tab = (outline.item(atRow: row) as? NativeTabNode)?.tab?.controller else { return nil }
        let strings = ChromeStrings.current
        return NativeActionMenu.make([
            .action(strings.newTab, symbol: "plus") { [weak tab] in tab?.newVerticalTab() },
            .action(strings.renameTab, symbol: "pencil") { [weak tab] in tab?.promptTabTitle() },
            .separator,
            .action(strings.moveTabToNewWindow, symbol: "macwindow",
                    enabled: (tab.workspaceTabWindows.count) > 1) { [weak tab] in
                guard let window = tab?.window else { return }
                NSApp.sendAction(NSSelectorFromString("moveTabToNewWindow:"), to: window, from: nil)
            },
            .action(strings.closeOtherTabs, enabled: configuration.controller.tabControllers.count > 1) { [weak tab] in
                tab?.closeOtherTabs(nil)
            },
            .action(strings.closeTab, symbol: "xmark") { [weak tab] in tab?.closeTab(nil) },
        ])
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let item = outline.item(atRow: outline.selectedRow) as? NativeTabNode,
              let tab = item.tab else { return }
        // AppKit sends selection notifications inside mouseDown tracking.
        // The completed click path activates after super.mouseDown returns;
        // drag selection must never reparent the host during its preview.
        guard outline.isNavigatingWithKeyboard, !outline.isDraggingTab else { return }
        // Keyboard row changes select the matching native tab after AppKit
        // finishes dispatching the selection notification.
        let id = tab.id
        let generation = selectionChangeGeneration
        // A clicked row is already visible. Do not scroll again when native
        // window selection feeds back through the presentation snapshot.
        lastSelectedID = id
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, self.selectionChangeGeneration == generation,
                  let tab = item?.tab,
                  let selected = self.outline.item(atRow: self.outline.selectedRow) as? NativeTabNode,
                  selected.tab?.id == id else { return }
            self.configuration.controller.selectVerticalTab(tab.controller)
            self.outline.window?.makeFirstResponder(self.outline)
            // Native tab activation also schedules terminal focus repair.
            // Finish keyboard navigation after that handoff, unless a newer
            // pointer/activation gesture or tab selection superseded it.
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, self.selectionChangeGeneration == generation,
                      let tab = item?.tab, let window = self.outline.window,
                      window === tab.controller.window, window.isKeyWindow,
                      (self.outline.item(atRow: self.outline.selectedRow) as? NativeTabNode)?.tab?.id == id else { return }
                window.makeFirstResponder(self.outline)
            }
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { saveExpansion(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { saveExpansion(notification, collapsed: true) }

    private func saveExpansion(_ notification: Notification, collapsed: Bool) {
        guard !updating, let node = notification.userInfo?["NSObject"] as? NativeTabNode else { return }
        let id = String(node.key.dropFirst("group:".count))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.configuration.layoutState.collapsedGroupIDs.contains(id) != collapsed else { return }
            self.configuration.layoutState.toggleGroup(id)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Without a writer AppKit never starts a drag, so a display-only
        // order cannot switch the user's tab ordering to manual.
        guard configuration.allowsReordering, let tab = (item as? NativeTabNode)?.tab else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(tab.controller.tabSessionID.uuidString, forType: Self.tabType)
        return writer
    }

    private func drop(_ info: NSDraggingInfo, item: Any?, index: Int) -> (TerminalController, Int)? {
        guard let sourceView = info.draggingSource as? NSOutlineView, sourceView === outline,
              let raw = info.draggingPasteboard.string(forType: Self.tabType),
              let id = UUID(uuidString: raw) else { return nil }
        return resolveDrop(sourceID: id, item: item, index: index)
    }

    private func destination(item: Any?, index: Int) -> (TerminalController, VerticalTabDropPolicy.Placement)? {
        if index == NSOutlineViewDropOnItemIndex, let tab = (item as? NativeTabNode)?.tab {
            return (tab.controller, .after)
        }
        if index == NSOutlineViewDropOnItemIndex, let tab = (item as? NativeTabNode)?.children.last?.tab {
            return (tab.controller, .after)
        }
        let children = (item as? NativeTabNode)?.children ?? roots
        guard index >= 0, index <= children.count else { return nil }
        if index < children.count, let tab = children[index].tab ?? children[index].children.first?.tab {
            return (tab.controller, .before)
        }
        guard let tab = children.last?.tab ?? children.last?.children.last?.tab else { return nil }
        return (tab.controller, .after)
    }

    private func externalTab(_ info: NSDraggingInfo) -> TerminalController? {
        guard let source = info.draggingSource as? NativeTabOutline, source !== outline,
              let raw = info.draggingPasteboard.string(forType: Self.tabType), let id = UUID(uuidString: raw) else { return nil }
        return configuration.controller.workspaceCoordinator.liveControllers.first {
            $0.tabSessionID == id && $0.workspaceID == configuration.controller.workspaceID && $0.isAvailableForWorkspace
        }
    }

    private func surface(_ info: NSDraggingInfo) -> Ghostty.SurfaceView? {
        guard info.draggingSource != nil,
              let data = info.draggingPasteboard.data(forType: .ghosttySurfaceId), data.count == 16 else { return nil }
        return Ghostty.SurfaceView.find(uuid: data.withUnsafeBytes { $0.loadUnaligned(as: UUID.self) })
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        outline.dragBegan()
        guard configuration.allowsReordering else { return }
        configuration.controller.beginManualTabDrag()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Drag selection is only AppKit feedback. On cancellation as well as
        // success, restore the row corresponding to the actual selected tab.
        update(configuration)
        outline.dragEnded()
    }

    func resolveDrop(sourceID id: UUID, item: Any?, index: Int) -> (TerminalController, Int)? {
        guard configuration.allowsReordering, index >= 0,
              let group = configuration.groups.first(where: { $0.tabs.contains { $0.controller.tabSessionID == id } }),
              let source = group.tabs.first(where: { $0.controller.tabSessionID == id }) else { return nil }
        let children: [NativeTabNode]
        if let item = item as? NativeTabNode {
            guard item.key == "group:\(group.id)" else { return nil }
            children = item.children
        } else {
            guard group.title == nil else { return nil }
            children = roots
        }
        let workspaceWindows = configuration.controller.workspaceTabWindows
        guard index <= children.count,
              let sourceWindow = source.controller.window,
              workspaceWindows.contains(sourceWindow) else { return nil }
        // Drop indexes are relative to the current workspace's projected list,
        // even when AppKit's retained native group contains other workspaces.
        let target = index < children.count ? children[index] : children.last
        guard let targetWindow = target?.tab?.controller.window,
              let targetIndex = workspaceWindows.firstIndex(of: targetWindow) else { return nil }
        return (source.controller, targetIndex + (index == children.count ? 1 : 0))
    }

    func insertionProposal(item: Any?, index: Int, point: NSPoint) -> (NativeTabNode?, Int) {
        guard index == NSOutlineViewDropOnItemIndex else { return (item as? NativeTabNode, index) }
        guard let node = item as? NativeTabNode else { return (nil, roots.count) }
        guard node.tab != nil else { return (node, node.children.count) }
        let parent = outline.parent(forItem: node) as? NativeTabNode
        let children = parent?.children ?? roots
        guard let childIndex = children.firstIndex(where: { $0 === node }) else { return (parent, -1) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return (parent, -1) }
        return (parent, childIndex + (point.y < outline.rect(ofRow: row).midY ? 0 : 1))
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Every drop here is placed relative to a row, which has no native
        // position in a display-only order.
        guard configuration.allowsReordering else { return [] }
        let (item, index) = insertionProposal(item: item, index: index, point: outline.convert(info.draggingLocation, from: nil))
        outline.setDropItem(item, dropChildIndex: index)
        if drop(info, item: item, index: index) != nil { return .move }
        guard destination(item: item, index: index) != nil else { return [] }
        if let source = externalTab(info), !source.sharesNativeTabGroup(with: configuration.controller) { return .move }
        if let surface = surface(info),
           let owner = BaseTerminalController.controller(owning: surface) as? TerminalController,
           owner.workspaceID == configuration.controller.workspaceID,
           owner.surfaceTree.isSplit || !owner.sharesNativeTabGroup(with: configuration.controller) { return .move }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard configuration.allowsReordering else { return false }
        let (item, index) = insertionProposal(item: item, index: index, point: outline.convert(info.draggingLocation, from: nil))
        guard let (source, insertion) = drop(info, item: item, index: index) else {
            guard let (target, placement) = destination(item: item, index: index) else { return false }
            if let source = externalTab(info) {
                (info.draggingSource as? NativeTabOutline ?? outline).afterDragEnds { [weak self] in
                    _ = self?.configuration.controller.attachNativeTab(source, relativeTo: target, placement: placement)
                }
                return true
            }
            if let surface = surface(info),
               let owner = BaseTerminalController.controller(owning: surface) as? TerminalController,
               owner.workspaceID == configuration.controller.workspaceID {
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    _ = self?.configuration.controller.moveSurfaceToNewTab(surface, relativeTo: target, placement: placement)
                }
                return true
            }
            return false
        }
        // NSWindowTabGroup removal/insertion may run blocking AppKit window
        // animations. Commit after CoreDrag releases the source window.
        outline.afterDragEnds { [weak self] in
            guard let self, configuration.controller.reorderTab(source, toInsertionIndex: insertion) else { return }
            let groups = GhosttyTabOrganizationModel().groups(
                tabs: configuration.controller.tabControllers,
                grouping: configuration.layoutState.groupingMode,
                ordering: configuration.layoutState.orderingMode
            )
            update(NativeTabOutlineConfiguration(
                groups: groups, selectedID: configuration.layoutState.tabSnapshot.selectedID,
                layoutState: configuration.layoutState, controller: configuration.controller,
                metrics: configuration.metrics, showsSubtitle: configuration.showsSubtitle,
                presentation: configuration.presentation
            ))
        }
        return true
    }
}
/// Adds a deliberate terminal activation gesture while leaving row navigation
/// and drag tracking to AppKit.
@MainActor
final class NativeTabOutline: NSOutlineView {
    var activateSelectedRow: (() -> Void)?
    var didBeginMouseTracking: (() -> Void)?
    var didBeginDrag: (() -> Void)?
    private(set) var isNavigatingWithKeyboard = false
    private(set) var isDraggingTab = false
    private weak var mouseDownResponder: NSResponder?
    private var dragDiagnosticMonitor: Any?
    private var completedDragActions: [() -> Void] = []
    private var mouseGestureTimestamp: TimeInterval?
    private var earlyMouseUp: NSEvent?
    var contextMenu: ((Int) -> NSMenu?)?
    /// NSOutlineView reserves a disclosure-triangle gutter in the outline
    /// column even for level-0 leaves. A flat tab list has no disclosure
    /// buttons, so give its cells the full row width instead.
    var reservesDisclosureSpace = true
    /// Tab rows inside a group take the full row width, as in a flat list;
    /// only the group's header keeps the disclosure gutter.
    var flattensGroupRows = false
    /// Matches the trailing inset so icons and shortcuts sit evenly inside the row highlight.
    static let flatLeadingInset: CGFloat = 4
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard row >= 0, column >= 0, column < tableColumns.count,
              tableColumns[column] === outlineTableColumn else { return frame }
        let isFlattenedTab = flattensGroupRows && (item(atRow: row) as? NativeTabNode)?.tab != nil
        guard !reservesDisclosureSpace || isFlattenedTab else { return frame }
        let minX = rect(ofRow: row).minX + Self.flatLeadingInset
        return NSRect(x: minX, y: frame.minY, width: frame.maxX - minX, height: frame.height)
    }
    private lazy var hover = NativeTableHover(table: self)
    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.update() }
    /// Rows can move or resize under a resting pointer.
    func refreshHover() { hover.update() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover.update()
        guard dragDiagnosticMonitor == nil else { return }
        dragDiagnosticMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown],
            handler: WeakLocalEventMonitor.handler(for: self) { outline, event in
                outline.observeDragRelease(event)
                if outline.isDraggingTab || (event.type != .keyDown && event.window === outline.window) {
                    NativeTabDragDiagnostics.record("delivered", outline: outline, event: event)
                }
                return event
            })
    }
    override func viewDidHide() { super.viewDidHide(); hover.clear() }
    override func viewDidUnhide() { super.viewDidUnhide(); hover.didUnhide() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(row(at: convert(event.locationInWindow, from: nil))) }

    override func mouseDown(with event: NSEvent) {
        NativeTabDragDiagnostics.record("mouseDown-enter", outline: self, event: event)
        beginMouseGesture(event)
        mouseDownResponder = window?.firstResponder
        didBeginMouseTracking?()
        super.mouseDown(with: event)
        NativeTabDragDiagnostics.record("mouseDown-return", outline: self, event: event)
    }

    func dragBegan() {
        isDraggingTab = true
        NativeTabDragDiagnostics.record("drag-began", outline: self)
        didBeginDrag?()
        // AppKit starts CoreDrag from a run-loop observer. A short gesture can
        // deliver its mouse-up before that observer runs. Return that exact
        // release to CoreDrag once; never synthesize or wait for another click.
        if let release = takeEarlyDragRelease() {
            NativeTabDragDiagnostics.record("release-replayed", outline: self, event: release)
            NSApp.postEvent(release, atStart: false)
        }
    }

    func dragEnded() {
        NativeTabDragDiagnostics.record("drag-ended", outline: self)
        isDraggingTab = false
        mouseGestureTimestamp = nil
        earlyMouseUp = nil
        if let previous = mouseDownResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        }
        mouseDownResponder = nil
        let actions = completedDragActions
        completedDragActions.removeAll()
        for action in actions { RunLoop.main.perform(inModes: [.default], block: action) }
    }

    func observeDragRelease(_ event: NSEvent) {
        guard event.window === window, event.type == .leftMouseUp, !isDraggingTab,
              let began = mouseGestureTimestamp, event.timestamp >= began else { return }
        earlyMouseUp = event
    }

    func beginMouseGesture(_ event: NSEvent) {
        mouseGestureTimestamp = event.timestamp
        earlyMouseUp = nil
    }

    func takeEarlyDragRelease() -> NSEvent? {
        defer { earlyMouseUp = nil }
        return earlyMouseUp
    }

    func afterDragEnds(_ action: @escaping () -> Void) {
        if isDraggingTab {
            completedDragActions.append(action)
        } else {
            RunLoop.main.perform(inModes: [.default], block: action)
        }
    }

    deinit {
        if let dragDiagnosticMonitor { NSEvent.removeMonitor(dragDiagnosticMonitor) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            activateSelectedRow?()
            return
        }
        isNavigatingWithKeyboard = true
        defer { isNavigatingWithKeyboard = false }
        super.keyDown(with: event)
    }
}

/// Whether the pointer is active over the tab list. An order that changes by
/// itself waits until the pointer leaves, or rests, before it moves rows.
@MainActor
final class NativeTabListPointer: NSObject {
    /// A resting pointer stops holding the order: it is usually parked over
    /// the sidebar while the user types in the terminal.
    static let restInterval: TimeInterval = 3
    private weak var view: NSView?
    private var inside = false
    private var lastMovement: TimeInterval = 0
    var onExit: (() -> Void)?

    init(view: NSView) {
        self.view = view
        super.init()
        view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    var holdsOrder: Bool {
        guard inside else { return false }
        // Moving the list to another native tab window can drop the exit event.
        guard let view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              view.visibleRect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else {
            inside = false
            return false
        }
        return ProcessInfo.processInfo.systemUptime - lastMovement < Self.restInterval
    }

    private func moved() {
        inside = true
        lastMovement = ProcessInfo.processInfo.systemUptime
    }

    // NSObject does not inherit NSResponder's Objective-C selector mapping.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { moved() }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) { moved() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        guard inside else { return }
        inside = false
        onExit?()
    }
}

private final class NativeTabRowView: NativeHoverRowView {
    override func hoverStateDidChange(_ hovered: Bool) {
        guard numberOfColumns > 0 else { return }
        (view(atColumn: 0) as? NativeTabCell)?.updateHoverAppearance()
    }
    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected, numberOfColumns > 0 else { return }
            (view(atColumn: 0) as? NativeTabCell)?.updateSelection(isSelected)
        }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        OMGNativeTheme.resolve(for: self).selectedFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// AppKit cells observe their own title changes instead of invalidating the list.
@MainActor
final class NativeTabCell: NSTableCellView {
    private var metrics = NativeTabRowMetrics.tabs(rowHeight: 28)
    private let icon = NativeTabIconView()
    private let label = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let status = NSImageView()
    private let closeButton = NativeActionControl()
    private var closeAction: (() -> Void)?
    private var observations = Set<AnyCancellable>()
    private var surfaceObservations = Set<AnyCancellable>()
    private var configuredTab: GhosttyOrganizedTab?
    private var presentation: ((GhosttyOrganizedTab) -> GhosttyTabPresentation?)?
    private var selected = false
    private var selectAction: (() -> Void)?
    private var refreshScheduled = false
    private var canClose = false
    private var stackCenterY: NSLayoutConstraint?
    private var subtitleTop: NSLayoutConstraint?
    /// The subtitle under the title, or under the icon across the whole row.
    private var subtitleUnderTitle: [NSLayoutConstraint] = []
    private var subtitleAcrossRow: [NSLayoutConstraint] = []
    private var layoutChanged: (() -> Void)?
    /// Subtitle visibility last rendered for the configured tab.
    private var renderedTwoLine: Bool?
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateHoverAppearance()
    }

    func updateSelection(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        guard let tab = configuredTab, let presentation, let value = presentation(tab) else { return }
        icon.configure(controller: tab.controller, icon: value.icon, selected: selected, activity: value.activity)
    }

    func updateHoverAppearance() {
        let hovered = (superview as? NativeHoverRowView)?.isHovered == true
        let showsClose = hovered && canClose
        if closeButton.isHidden != !showsClose { closeButton.isHidden = !showsClose }
        if shortcut.isHidden != showsClose { shortcut.isHidden = showsClose }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeButton.title = ""
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: metrics.titleFontSize)
        // Middle truncation keeps both the host and the directory tail.
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: metrics.subtitleFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.isHidden = true
        shortcut.font = .systemFont(ofSize: 10)
        shortcut.textColor = .secondaryLabelColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: ChromeStrings.current.closeTab)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel(ChromeStrings.current.closeTab)
        let trailing = NSView()
        for view in [shortcut, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            trailing.addSubview(view)
            NSLayoutConstraint.activate([
                view.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: trailing.centerYAnchor)
            ])
        }
        trailing.widthAnchor.constraint(equalToConstant: 28).isActive = true
        trailing.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let stack = NSStackView(views: [icon, label, status, trailing])
        stack.distribution = .fill
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        // The subtitle hangs below the title outside the stack, so the icon,
        // status and trailing slot stay on the title line and a single-line
        // row keeps its exact layout.
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(subtitle)
        let centerY = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        stackCenterY = centerY
        let subtitleTop = subtitle.topAnchor.constraint(equalTo: label.bottomAnchor, constant: metrics.subtitleSpacing)
        self.subtitleTop = subtitleTop
        // AppKit briefly sizes newly attached cells below their icon footprint.
        // Keep their content intact without unsatisfiable required constraints.
        let trailingConstraint = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)
        trailingConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            trailingConstraint,
            centerY,
            subtitleTop,
            icon.widthAnchor.constraint(equalToConstant: TabIconMetrics.footprint),
            icon.heightAnchor.constraint(equalToConstant: TabIconMetrics.footprint),
            status.widthAnchor.constraint(equalToConstant: 14),
            status.heightAnchor.constraint(equalToConstant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        subtitleUnderTitle = [
            subtitle.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: label.trailingAnchor)
        ]
        let acrossTrailing = subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)
        acrossTrailing.priority = .defaultHigh
        subtitleAcrossRow = [subtitle.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: 2), acrossTrailing]
        applySubtitlePlacement()
        // Do not register these as NSTableCellView's standard outlets: source
        // list cell layout can reposition them around our stack constraints.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applySubtitlePlacement() {
        NSLayoutConstraint.deactivate(metrics.subtitleSpansRow ? subtitleUnderTitle : subtitleAcrossRow)
        NSLayoutConstraint.activate(metrics.subtitleSpansRow ? subtitleAcrossRow : subtitleUnderTitle)
        // The directory's tail matters most when it runs the width of the row.
        subtitle.lineBreakMode = metrics.subtitleSpansRow ? .byTruncatingHead : .byTruncatingMiddle
    }

    // Row configuration keeps the native interaction callbacks explicit.
    // swiftlint:disable:next function_parameter_count
    func configure(tab: GhosttyOrganizedTab?, title: String?,
                   presentation: @escaping (GhosttyOrganizedTab) -> GhosttyTabPresentation?,
                   groupIcon: GhosttyTabIcon? = nil, count: Int? = nil,
                   metrics: NativeTabRowMetrics? = nil,
                   canClose: Bool, selected: Bool, select: @escaping () -> Void,
                   close: @escaping () -> Void, layoutChanged: (() -> Void)? = nil) {
        closeButton.setAccessibilityLabel(ChromeStrings.current.closeTab)
        if let metrics, metrics != self.metrics {
            self.metrics = metrics
            subtitle.font = .systemFont(ofSize: metrics.subtitleFontSize)
            subtitleTop?.constant = metrics.subtitleSpacing
            shortcut.font = .systemFont(ofSize: metrics.shortcutFontSize)
            applySubtitlePlacement()
        }
        let changedController = configuredTab?.controller !== tab?.controller
        if tab == nil || changedController {
            observations.removeAll()
            surfaceObservations.removeAll()
            // A recycled cell starts over; only a change of the same tab is reported.
            renderedTwoLine = nil
        }
        self.layoutChanged = layoutChanged
        configuredTab = tab
        self.presentation = presentation
        self.selected = selected
        selectAction = select
        closeAction = close
        self.canClose = tab != nil && canClose
        updateHoverAppearance()
        guard let tab else {
            configuredTab = nil
            self.presentation = nil
            selectAction = nil
            label.stringValue = title ?? ""
            label.font = .systemFont(ofSize: self.metrics.headerFontSize, weight: .semibold)
            let theme = OMGNativeTheme.resolve(for: self)
            // A flat list reads its headers as quiet section labels.
            label.textColor = self.metrics.flattensGroups ? theme.secondary : theme.foreground
            icon.isHidden = self.metrics.flattensGroups && groupIcon == nil
            icon.configure(controller: nil, icon: groupIcon ?? .systemSymbol("folder"), selected: false, activity: nil)
            // Section headers reuse the trailing slot for their tab count.
            shortcut.stringValue = count.map { "\($0)" } ?? ""
            shortcut.textColor = OMGNativeTheme.resolve(for: self).secondary
            status.isHidden = true
            setSubtitle(nil)
            toolTip = nil
            setAccessibilityLabel(count.map { "\(title ?? "") (\($0))" } ?? title ?? "")
            return
        }
        if changedController {
            observe(tab.controller)
        }
        refreshNow()
    }

    private func observe(_ controller: TerminalController) {
        // objectWillChange covers non-published presentation state such as the
        // title override and session context, alongside the published tree,
        // focus, and agent activity changes.
        controller.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &observations)
        controller.$surfaceTree
            .sink { [weak self] tree in
                guard let self else { return }
                self.observeSurfaces(in: tree)
                self.scheduleRefresh()
            }
            .store(in: &observations)
    }

    private func observeSurfaces(in tree: SplitTree<Ghostty.SurfaceView>) {
        surfaceObservations.removeAll()
        for surface in tree {
            surface.$title.sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &surfaceObservations)
            surface.$pwd.sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &surfaceObservations)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        guard let tab = configuredTab, let presentation,
              let value = presentation(tab) else { return }
        let selected = self.selected
        shortcut.stringValue = value.shortcut ?? ""
        let title = value.remoteBreadcrumb?.title ?? value.title
        let detail = value.showsSubtitle ? value.subtitle : nil
        label.font = .systemFont(ofSize: metrics.titleFontSize,
                                 weight: detail != nil && metrics.emphasizesNames ? .medium : .regular)
        // A name is read from its start; a path keeps its host and its tail.
        label.lineBreakMode = detail != nil ? .byTruncatingTail : .byTruncatingMiddle
        if icon.isHidden { icon.isHidden = false }
        toolTip = AgentLogoStyle.toolTip(title: detail.map { "\(title)\n\($0)" } ?? title, activity: value.activity)
        icon.configure(controller: tab.controller, icon: value.icon, selected: selected, activity: value.activity)
        label.stringValue = title
        let theme = OMGNativeTheme.resolve(for: self)
        label.textColor = theme.foreground
        subtitle.textColor = theme.secondary
        shortcut.textColor = theme.secondary
        setSubtitle(detail)
        if let renderedTwoLine, renderedTwoLine != (detail != nil) { layoutChanged?() }
        renderedTwoLine = detail != nil
        let badge = AgentStatusBadge.resolve(value.activity)
        status.isHidden = badge == nil
        status.image = badge.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        status.contentTintColor = badge?.color
        status.toolTip = value.activity.map(AgentLogoStyle.localizedStatus)
        setAccessibilityLabel(value.title)
    }

    private func setSubtitle(_ text: String?) {
        subtitle.stringValue = text ?? ""
        if subtitle.isHidden != (text == nil) { subtitle.isHidden = text == nil }
        // Title and subtitle stay centred in the row as one block.
        let offset = text == nil ? 0 : -metrics.subtitleBlockHeight / 2
        if stackCenterY?.constant != offset { stackCenterY?.constant = offset }
    }

    @objc private func closeTab() { closeAction?() }
}
