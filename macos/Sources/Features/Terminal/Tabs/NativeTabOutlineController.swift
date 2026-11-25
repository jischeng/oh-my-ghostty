import AppKit
import Combine
import QuartzCore
import SwiftUI

private let tabPresentationDidChangeNotification = Notification.Name("GhosttyTabPresentationDidChange")

/// AppKit presentation over the existing native-window tab model for the single-line Tabs view.
/// Stable nodes keep selection-only updates from rebuilding the outline.
struct NativeTabOutlineConfiguration {
    let groups: [GhosttyTabGroupPresentation]
    let selectedID: ObjectIdentifier?
    let layoutState: VerticalTabWindowLayoutState
    let controller: TerminalController
    let rowHeight: CGFloat
    let presentation: (GhosttyOrganizedTab) -> GhosttyTabPresentation?
}

@MainActor
final class NativeTabNode: NSObject {
    let key: String
    var title: String?
    var icon: GhosttyTabIcon?
    var tab: GhosttyOrganizedTab?
    var children: [NativeTabNode] = []
    init(key: String) { self.key = key }
}

/// Shared native tab context menu used by both the Tabs outline and the Inbox view.
enum NativeTabContextMenu {
    @MainActor
    static func make(for tab: TerminalController, host: TerminalController) -> NSMenu {
        let strings = ChromeStrings.current
        let workspaces = tab.workspaceCoordinator.store.workspaces
        let isRenaming = tab.isGeneratingTabTitle
        var entries: [NativeMenuEntry] = [
            .action(strings.newTab, symbol: "plus") { [weak tab] in tab?.newVerticalTab() },
            .action(strings.renameTab, symbol: "pencil") { [weak tab] in tab?.promptTabTitle() },
            .action(
                isRenaming ? strings.renamingTab : strings.autoRenameTab,
                symbol: "sparkles",
                enabled: !isRenaming
            ) { [weak tab] in tab?.autoRenameTab(force: true) },
            .separator,
        ]
        if workspaces.count > 1 {
            let currentWorkspaceID = tab.workspaceID
            let moveEntries = workspaces.map { workspace in
                NativeMenuEntry.action(
                    workspace.name,
                    symbol: workspace.symbol,
                    enabled: workspace.id != currentWorkspaceID,
                    checked: workspace.id == currentWorkspaceID
                ) { [weak tab] in
                    guard let tab else { return }
                    _ = tab.workspaceCoordinator.move(tab, to: workspace.id)
                }
            }
            entries.append(.submenu(strings.moveToWorkspace, entries: moveEntries))
        }
        entries.append(contentsOf: [
            .action(
                strings.moveTabToNewWindow,
                symbol: "macwindow",
                enabled: tab.workspaceTabWindows.count > 1
            ) { [weak tab] in
                guard let window = tab?.window else { return }
                NSApp.sendAction(NSSelectorFromString("moveTabToNewWindow:"), to: window, from: nil)
            },
            .action(
                strings.closeOtherTabs,
                enabled: host.tabControllers.count > 1
            ) { [weak tab] in
                tab?.closeOtherTabs(nil)
            },
            .action(strings.closeTab, symbol: "xmark") { [weak tab] in
                tab?.closeTab(nil)
            },
        ])
        return NativeActionMenu.make(entries)
    }
}

@MainActor
final class NativeTabOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let tabType = NSPasteboard.PasteboardType("com.jischeng.omg.native-sidebar-tab")
    static let rowMoveAnimationDuration: TimeInterval = 0.16

    private struct ParentMoveBatch {
        let parent: NativeTabNode?
        let moves: [(Int, Int)]
    }

    let outline: NativeTabOutline
    let scrollView = NSScrollView()
    let commandMonitor = NativeCommandRevealMonitor()
    var configuration: NativeTabOutlineConfiguration
    var roots: [NativeTabNode] = []
    var nodes: [String: NativeTabNode] = [:]
    var structure: [String] = []
    var updating = false
    var lastSelectedID: ObjectIdentifier?
    var animationsEnabled = true
    /// Test seam for deterministic `⌘`-hold shortcut reveal in unit tests.
    var isCommandModifierHeldOverride: Bool? {
        get { commandMonitor.overrideValue }
        set { commandMonitor.overrideValue = newValue }
    }
    var isCommandHeld: Bool { commandMonitor.isCommandHeld }
    private var selectionChangeGeneration = 0
    private(set) var reloadCount = 0
    private(set) var moveCount = 0
    private(set) var animatedMoveCount = 0
    private(set) var membershipUpdateCount = 0

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

    /// Sequence of incremental `moveItem` steps transforming `old` into `new`
    /// when both arrays contain the exact same unique item keys.
    static func moveSequence(from old: [String], to new: [String]) -> [(Int, Int)]? {
        guard old.count == new.count, Set(old) == Set(new), old != new else { return nil }
        if let single = singleMove(from: old, to: new) {
            return [single]
        }
        var current = old
        var moves: [(Int, Int)] = []
        for targetIndex in new.indices {
            let wanted = new[targetIndex]
            guard let sourceIndex = current.firstIndex(of: wanted) else { return nil }
            if sourceIndex != targetIndex {
                let item = current.remove(at: sourceIndex)
                current.insert(item, at: targetIndex)
                moves.append((sourceIndex, targetIndex))
            }
        }
        return current == new ? moves : nil
    }

    private static func groupMoveBatches(
        changedGroups: [NativeTabNode],
        oldChildren: [String: [String]]
    ) -> [ParentMoveBatch]? {
        var batches: [ParentMoveBatch] = []
        for group in changedGroups {
            guard let old = oldChildren[group.key],
                  let moves = moveSequence(from: old, to: group.children.map(\.key)) else {
                return nil
            }
            batches.append(ParentMoveBatch(parent: group, moves: moves))
        }
        return batches.isEmpty ? nil : batches
    }

    private var shouldAnimateMoves: Bool {
        animationsEnabled &&
            outline.window?.isVisible == true &&
            !outline.isHiddenOrHasHiddenAncestor &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func applyMoveBatches(_ batches: [ParentMoveBatch]) {
        let totalMoves = batches.reduce(0) { $0 + $1.moves.count }
        guard totalMoves > 0 else { return }
        let animate = shouldAnimateMoves
        let timing = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1.0)
        NSAnimationContext.runAnimationGroup { context in
            if animate {
                context.duration = Self.rowMoveAnimationDuration
                context.timingFunction = timing
                context.allowsImplicitAnimation = true
            } else {
                context.duration = 0
            }
            outline.beginUpdates()
            for batch in batches {
                for (source, destination) in batch.moves {
                    outline.moveItem(at: source, inParent: batch.parent, to: destination, inParent: batch.parent)
                }
            }
            outline.endUpdates()
        }
        moveCount += totalMoves
        if animate {
            animatedMoveCount += 1
        }
    }

    init(_ parent: NativeTabOutlineConfiguration) {
        self.configuration = parent
        outline = NativeTabOutline()
        super.init(nibName: nil, bundle: nil)
        commandMonitor.hostView = outline
        commandMonitor.onChange = { [weak self] held in
            self?.updateCommandRevealOnAvailableCells(held)
        }
        outline.onWindowDidChange = { [weak self] in
            self?.commandMonitor.reconcileWindowFocus()
        }
        outline.activateSelectedRow = { [weak self] in self?.activateSelectedRow() }
        outline.didBeginMouseTracking = { [weak self] in self?.selectionChangeGeneration += 1 }
        outline.didBeginDrag = { [weak self] in self?.selectionChangeGeneration += 1 }
    }

    private func updateCommandRevealOnAvailableCells(_ held: Bool) {
        outline.enumerateAvailableRowViews { rowView, _ in
            guard rowView.numberOfColumns > 0,
                  let cell = rowView.view(atColumn: 0) as? NativeTabCell else { return }
            cell.isCommandHeld = held
        }
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
        let rowHeightChanged = configuration.rowHeight != value.rowHeight
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
        func node(_ key: String) -> NativeTabNode {
            let result = nodes[key] ?? NativeTabNode(key: key)
            nextNodes[key] = result
            return result
        }
        for group in value.groups {
            let children = group.tabs.map { tab -> NativeTabNode in
                let item = node("tab:\(tab.controller.tabSessionID)")
                item.tab = tab
                nextStructure.append("\(group.id)/\(item.key)")
                return item
            }
            if let title = group.title {
                let item = node("group:\(group.id)")
                item.title = title
                item.icon = group.icon
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
        outline.rowHeight = value.rowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        if structure != nextStructure {
            structure = nextStructure
            let newRoots = roots.map(\.key)
            let changedGroups = roots.filter {
                $0.tab == nil && oldChildren[$0.key] != $0.children.map(\.key)
            }
            if oldChildren.isEmpty, roots.allSatisfy({ $0.tab != nil }),
               let moves = Self.moveSequence(from: oldRoots, to: newRoots) {
                applyMoveBatches([ParentMoveBatch(parent: nil, moves: moves)])
            } else if !oldRoots.isEmpty, oldRoots == newRoots, !changedGroups.isEmpty,
                      roots.allSatisfy({ $0.tab == nil }),
                      let batches = Self.groupMoveBatches(changedGroups: changedGroups, oldChildren: oldChildren) {
                applyMoveBatches(batches)
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
        if rowHeightChanged, outline.numberOfRows > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
            }
            outline.refreshHover()
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

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        NativeTabRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        configuration.rowHeight
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
        cell.isCommandHeld = commandMonitor.isCommandHeld
        cell.configure(
            tab: item.tab,
            title: item.title,
            presentation: configuration.presentation,
            groupIcon: item.icon,
            canClose: configuration.groups.reduce(0) { $0 + $1.tabs.count } > 1,
            selected: item.tab?.id == configuration.selectedID,
            select: { [weak self, weak item] in
                guard let self, let item else { return }
                self.activate(row: self.outline.row(forItem: item))
            },
            close: { [weak self, weak item] in
                guard let self, let tab = item?.tab else { return }
                self.configuration.controller.closeVerticalTab(tab.controller)
            }
        )
    }

    private func menu(for row: Int) -> NSMenu? {
        guard let tab = (outline.item(atRow: row) as? NativeTabNode)?.tab?.controller else { return nil }
        return NativeTabContextMenu.make(for: tab, host: configuration.controller)
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
        guard let tab = (item as? NativeTabNode)?.tab else { return nil }
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
        guard index >= 0,
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
                groups: groups,
                selectedID: configuration.layoutState.tabSnapshot.selectedID,
                layoutState: configuration.layoutState,
                controller: configuration.controller,
                rowHeight: configuration.rowHeight,
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
    var onWindowDidChange: (() -> Void)?
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
    /// Places flat cells at `10pt` inside `NativeTabRowView.highlightRect` (`pill.minX = 2` + `10pt` = `12pt` with `stack.leading = 2`),
    /// matching `NativeInboxMetrics.rowHorizontalPadding` (`10pt`) to the exact pixel.
    static let flatLeadingInset: CGFloat = 10
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard !reservesDisclosureSpace, row >= 0, column >= 0, column < tableColumns.count,
              tableColumns[column] === outlineTableColumn else { return frame }
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
        onWindowDidChange?()
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

/// Whether the pointer is active over a display-ordered tab list. An order that
/// changes by itself waits until the pointer leaves, or rests, before moving rows.
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

    private func moved(with event: NSEvent) {
        guard let view, NativePointerLocation.contains(view, event: event) else {
            if inside {
                inside = false
                onExit?()
            }
            return
        }
        inside = true
        lastMovement = ProcessInfo.processInfo.systemUptime
    }

    func noteActivityIfInside() {
        guard inside else { return }
        lastMovement = ProcessInfo.processInfo.systemUptime
    }

    func cancel() {
        inside = false
    }

    // NSObject does not inherit NSResponder's Objective-C selector mapping.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { moved(with: event) }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) { moved(with: event) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        guard inside else { return }
        inside = false
        onExit?()
    }
}

final class NativeTabRowView: NativeHoverRowView {
    static let pillCornerRadius: CGFloat = NativeInboxMetrics.rowCornerRadius
    override var cornerRadius: CGFloat { Self.pillCornerRadius }
    var selectionRect: NSRect { highlightRect }

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
        let rect = selectionRect
        guard !rect.isEmpty else { return }
        let radius = cornerRadius
        OMGNativeTheme.resolve(for: self).selectedFill.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

/// Pure single-line AppKit cells observe their own title changes without invalidating the list.
@MainActor
final class NativeTabCell: NSTableCellView {
    static let iconSize: CGFloat = NativeInboxMetrics.iconSize
    static let iconToTitleSpacing: CGFloat = 7
    static let trailingInsetFromCellEdge: CGFloat = 12

    static func iconSizing(
        preferredLogoSize: CGFloat? = nil
    ) -> NativeTabIconView.CustomSizing {
        let resolvedLogoSize = preferredLogoSize ?? CGFloat(OhMyGhosttySettings.shared.tabIconSize)
        return NativeTabIconView.CustomSizing(
            composition: iconSize,
            singleLogo: min(iconSize, max(12, resolvedLogoSize)),
            symbolBonus: 1,
            paneSize: 8.5
        )
    }

    let icon = NativeTabIconView()
    let label = NSTextField(labelWithString: "")
    let shortcut = NSTextField(labelWithString: "")
    let status = NSImageView()
    let renamingSpinner = NativeProgressIndicator()
    let closeButton = NativeInboxCloseButton()
    let trailingSlot = NSView()
    private(set) var rowStack: NSStackView!
    private var trailingWidthConstraint: NSLayoutConstraint!
    private var closeAction: (() -> Void)?
    private var observations = Set<AnyCancellable>()
    private var surfaceObservations = Set<AnyCancellable>()
    private var configuredTab: GhosttyOrganizedTab?
    private var presentation: ((GhosttyOrganizedTab) -> GhosttyTabPresentation?)?
    private var selected = false
    private var selectAction: (() -> Void)?
    private var refreshScheduled = false
    private var canClose = false
    private(set) var hasStatusBadge = false
    private(set) var isRenamingTitle = false
    private(set) var trailingAccessory: NativeTabTrailingAccessory = .none

    var isCommandHeld = false {
        didSet {
            guard oldValue != isCommandHeld else { return }
            updateTrailingVisibility()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateHoverAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func updateSelection(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        if configuredTab != nil {
            label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        }
        guard let tab = configuredTab, let presentation, let value = presentation(tab) else { return }
        icon.configure(controller: tab.controller, icon: value.icon, selected: selected, activity: value.activity)
    }

    func updateHoverAppearance() {
        updateTrailingVisibility()
    }

    func updateTrailingVisibility() {
        guard configuredTab != nil else {
            isRenamingTitle = false
            trailingAccessory = .none
            closeButton.isHidden = true
            shortcut.isHidden = true
            renamingSpinner.setAnimating(false)
            renamingSpinner.isHidden = true
            status.isHidden = true
            trailingSlot.isHidden = true
            return
        }
        isRenamingTitle = configuredTab?.controller.isGeneratingTabTitle == true
        renamingSpinner.toolTip = ChromeStrings.current.renamingTab
        let hovered = (superview as? NativeHoverRowView)?.isHovered == true
        let next = NativeTabTrailingAccessory.resolve(
            isHovered: hovered,
            canClose: canClose,
            isCommandHeld: isCommandHeld,
            hasShortcut: !shortcut.stringValue.isEmpty,
            isRenaming: isRenamingTitle,
            hasStatus: hasStatusBadge
        )
        trailingAccessory = next
        closeButton.isHidden = next != .close
        shortcut.isHidden = next != .shortcut
        renamingSpinner.isHidden = next != .renaming
        renamingSpinner.setAnimating(next == .renaming)
        status.isHidden = next != .status
        switch next {
        case .close:
            trailingWidthConstraint.constant = NativeInboxMetrics.closeButtonSize
            trailingSlot.isHidden = false
        case .shortcut:
            trailingWidthConstraint.constant = max(
                NativeInboxMetrics.closeButtonSize,
                ceil(shortcut.fittingSize.width)
            )
            trailingSlot.isHidden = false
        case .renaming:
            trailingWidthConstraint.constant =
                (NativeInboxMetrics.closeButtonSize + NativeTabTrailingAccessory.renamingSpinnerSize) / 2
            trailingSlot.isHidden = false
        case .status:
            trailingWidthConstraint.constant =
                (NativeInboxMetrics.closeButtonSize + NativeInboxMetrics.statusBadgeSize) / 2
            trailingSlot.isHidden = false
        case .none:
            trailingSlot.isHidden = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.customSizing = Self.iconSizing()
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13, weight: .regular)
        shortcut.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcut.alignment = .right
        status.imageScaling = .scaleProportionallyDown
        renamingSpinner.style = .spinning
        renamingSpinner.controlSize = .small
        renamingSpinner.isDisplayedWhenStopped = false
        renamingSpinner.setContentHuggingPriority(.required, for: .horizontal)
        renamingSpinner.setContentHuggingPriority(.required, for: .vertical)
        renamingSpinner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        renamingSpinner.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        closeButton.onPress = { [weak self] in self?.closeTab() }
        closeButton.setAccessibilityLabel(ChromeStrings.current.closeTab)
        closeButton.isHidden = true
        shortcut.isHidden = true
        renamingSpinner.isHidden = true
        status.isHidden = true
        trailingSlot.isHidden = true

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        for view in [shortcut, status, renamingSpinner, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            trailingSlot.addSubview(view)
            view.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor).isActive = true
        }
        let statusTrailingOffset = -(NativeInboxMetrics.closeButtonSize - NativeInboxMetrics.statusBadgeSize) / 2
        let spinnerSize = NativeTabTrailingAccessory.renamingSpinnerSize
        let spinnerTrailingOffset = -(NativeInboxMetrics.closeButtonSize - spinnerSize) / 2
        let widthConstraint = trailingSlot.widthAnchor.constraint(
            equalToConstant: NativeInboxMetrics.closeButtonSize
        )
        trailingWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            widthConstraint,
            trailingSlot.heightAnchor.constraint(equalToConstant: NativeInboxMetrics.closeButtonSize),
            shortcut.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: NativeInboxMetrics.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: NativeInboxMetrics.closeButtonSize),
            renamingSpinner.trailingAnchor.constraint(
                equalTo: trailingSlot.trailingAnchor,
                constant: spinnerTrailingOffset
            ),
            renamingSpinner.widthAnchor.constraint(equalToConstant: spinnerSize),
            renamingSpinner.heightAnchor.constraint(equalToConstant: spinnerSize),
            status.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor, constant: statusTrailingOffset),
            status.widthAnchor.constraint(equalToConstant: NativeInboxMetrics.statusBadgeSize),
            status.heightAnchor.constraint(equalToConstant: NativeInboxMetrics.statusBadgeSize),
        ])

        let stack = NSStackView(views: [icon, label, trailingSlot])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 6
        stack.setCustomSpacing(Self.iconToTitleSpacing, after: icon)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(stack)
        rowStack = stack
        let trailingConstraint = stack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.trailingInsetFromCellEdge
        )
        trailingConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            trailingConstraint,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])

        applyTheme()
        // Do not register these as NSTableCellView's standard outlets: source
        // list cell layout can reposition them around our stack constraints.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyTheme() {
        let theme = OMGNativeTheme.resolve(for: self)
        label.textColor = theme.foreground
        shortcut.textColor = theme.foreground.withAlphaComponent(0.45)
    }

    // Row configuration keeps the native interaction callbacks explicit.
    // swiftlint:disable:next function_parameter_count
    func configure(
        tab: GhosttyOrganizedTab?,
        title: String?,
        presentation: @escaping (GhosttyOrganizedTab) -> GhosttyTabPresentation?,
        groupIcon: GhosttyTabIcon? = nil,
        canClose: Bool,
        selected: Bool,
        select: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        closeButton.setAccessibilityLabel(ChromeStrings.current.closeTab)
        let changedController = configuredTab?.controller !== tab?.controller
        if tab == nil || changedController {
            observations.removeAll()
            surfaceObservations.removeAll()
        }
        configuredTab = tab
        self.presentation = presentation
        self.selected = selected
        selectAction = select
        closeAction = close
        self.canClose = tab != nil && canClose
        guard let tab else {
            configuredTab = nil
            self.presentation = nil
            selectAction = nil
            hasStatusBadge = false
            label.stringValue = title ?? ""
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            applyTheme()
            icon.customSizing = Self.iconSizing()
            icon.isHidden = false
            icon.configure(controller: nil, icon: groupIcon ?? .systemSymbol("folder"), selected: false, activity: nil)
            shortcut.stringValue = ""
            status.image = nil
            status.toolTip = nil
            updateTrailingVisibility()
            toolTip = nil
            setAccessibilityLabel(title ?? "")
            return
        }
        if changedController {
            observe(tab.controller)
        }
        refreshNow()
    }

    private func observe(_ controller: TerminalController) {
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
        NotificationCenter.default.publisher(for: tabPresentationDidChangeNotification)
            .sink { [weak self, weak controller] note in
                guard let self, let controller else { return }
                if let sender = note.object as? BaseTerminalController, sender !== controller { return }
                if let surface = note.object as? Ghostty.SurfaceView,
                   !controller.surfaceTree.contains(where: { $0 === surface }) { return }
                self.scheduleRefresh()
            }
            .store(in: &observations)
        controller.agentConversationTitleCoordinator.generationStateChanges
            .sink { [weak self] in self?.scheduleRefresh() }
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
        let titleWeight: NSFont.Weight = (selected || value.selected) ? .medium : .regular
        label.font = .systemFont(ofSize: 13, weight: titleWeight)
        label.lineBreakMode = .byTruncatingMiddle
        icon.customSizing = Self.iconSizing()
        if icon.isHidden { icon.isHidden = false }
        toolTip = value.toolTip ?? AgentLogoStyle.toolTip(title: title, activity: value.activity)
        icon.configure(controller: tab.controller, icon: value.icon, selected: selected, activity: value.activity)
        label.stringValue = title
        applyTheme()
        let badge = AgentStatusBadge.resolve(value.activity)
        hasStatusBadge = badge != nil
        status.image = badge.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        status.contentTintColor = badge?.color
        status.toolTip = value.activity.map(AgentLogoStyle.localizedStatus)
        updateTrailingVisibility()
        setAccessibilityLabel(value.title)
    }

    @objc private func closeTab() { closeAction?() }
}
