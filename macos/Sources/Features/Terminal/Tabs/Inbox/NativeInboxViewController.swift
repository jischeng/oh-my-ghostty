import AppKit

/// Configuration for the flipped-document AppKit Inbox view.
struct NativeInboxConfiguration {
    let groups: [GhosttyTabGroupPresentation]
    let selectedID: ObjectIdentifier?
    let layoutState: VerticalTabWindowLayoutState
    let controller: TerminalController
    let presentation: (GhosttyOrganizedTab) -> GhosttyTabPresentation?
}

/// Flipped document view hosting reusable Inbox section headers and session rows.
@MainActor
final class NativeInboxDocumentView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Dedicated AppKit Inbox view controller laying out reusable `NativeInboxSectionHeaderView`
/// and `NativeInboxRowView` frames deterministically inside a transparent `NSScrollView`
/// without `NSOutlineView` disclosure gutters or synchronous row-height re-entrancy.
@MainActor
final class NativeInboxViewController: NSViewController {
    let scrollView = NSScrollView()
    let documentView = NativeInboxDocumentView()
    private(set) var configuration: NativeInboxConfiguration

    private var headerViews: [String: NativeInboxSectionHeaderView] = [:]
    private var rowViews: [UUID: NativeInboxRowView] = [:]
    private(set) var orderedItemKeys: [String] = []
    private(set) var visibleTabs: [GhosttyOrganizedTab] = []

    private weak var hoveredRow: NativeInboxRowView?
    private weak var hoveredHeader: NativeInboxSectionHeaderView?
    private var hoverTrackingArea: NSTrackingArea?
    private var clipBoundsObserver: NSObjectProtocol?
    private var clipFrameObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var lastSelectedID: ObjectIdentifier?
    private var pointer: NativeTabListPointer?

    /// Invoked when an active pointer leaves the Inbox scroll view so held display order can apply.
    var pointerDidLeave: (() -> Void)?
    /// Test seam for pointer-hold stability in unit tests without a desktop cursor.
    var holdsOrderOverride: Bool?

    var isPointerHoldingOrder: Bool {
        holdsOrderOverride ?? pointer?.holdsOrder ?? false
    }

    init(_ configuration: NativeInboxConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let clipBoundsObserver { NotificationCenter.default.removeObserver(clipBoundsObserver) }
        if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.setAccessibilityLabel(ChromeStrings.current.inbox)
        scrollView.documentView = documentView

        documentView.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPointerHover() }
        }
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutItems() }
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        hoverTrackingArea = area
        scrollView.addTrackingArea(area)

        let pointer = NativeTabListPointer(view: scrollView)
        pointer.onExit = { [weak self] in
            self?.clearHover()
            self?.pointerDidLeave?()
        }
        self.pointer = pointer

        view = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        observeWindowIfNeeded()
        relayoutItems()
    }

    func rowView(for controller: TerminalController) -> NativeInboxRowView? {
        rowViews[controller.tabSessionID]
    }

    func headerView(for groupID: String) -> NativeInboxSectionHeaderView? {
        headerViews[groupID]
    }

    func update(_ next: NativeInboxConfiguration) {
        configuration = next
        guard isViewLoaded else { return }
        scrollView.setAccessibilityLabel(ChromeStrings.current.inbox)
        observeWindowIfNeeded()
        rebuildAndLayoutItems()
    }

    private func observeWindowIfNeeded() {
        let window = view.window
        guard observedWindow !== window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        observedWindow = window
        guard let window else {
            clearHover()
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSWindow.didResignKeyNotification {
                        self?.clearHover()
                    } else {
                        self?.refreshPointerHover()
                    }
                }
            })
        }
    }

    private func rebuildAndLayoutItems() {
        let totalTabs = configuration.groups.reduce(0) { $0 + $1.tabs.count }
        let canClose = totalTabs > 1
        let collapsed = configuration.layoutState.collapsedGroupIDs
        var activeHeaderIDs = Set<String>()
        var activeTabIDs = Set<UUID>()

        for group in configuration.groups {
            let groupCollapsed = group.title != nil && collapsed.contains(group.id)
            if let title = group.title {
                activeHeaderIDs.insert(group.id)
                let header = headerViews[group.id] ?? {
                    let created = NativeInboxSectionHeaderView()
                    headerViews[group.id] = created
                    documentView.addSubview(created)
                    return created
                }()
                let groupID = group.id
                header.onToggle = { [weak self] in
                    self?.toggleSection(groupID)
                }
                header.configure(
                    id: group.id,
                    title: title,
                    count: group.count,
                    collapsed: groupCollapsed,
                    animated: header.superview != nil && header.groupID == group.id
                )
                header.isHidden = false
            }

            guard !groupCollapsed else { continue }
            for tab in group.tabs {
                let id = tab.controller.tabSessionID
                activeTabIDs.insert(id)
                let row = rowViews[id] ?? {
                    let created = NativeInboxRowView()
                    rowViews[id] = created
                    documentView.addSubview(created)
                    return created
                }()
                let selected = tab.id == configuration.selectedID
                row.selectAction = { [weak self] in
                    self?.activate(tab: tab)
                }
                row.doubleClickAction = { [weak self] in
                    self?.activateAndRename(tab: tab)
                }
                row.closeAction = { [weak self] in
                    self?.configuration.controller.closeVerticalTab(tab.controller)
                }
                row.contextMenuProvider = { [weak self] in
                    guard let self else { return nil }
                    return NativeTabContextMenu.make(for: tab.controller, host: self.configuration.controller)
                }
                row.onHeightPreferenceChange = { [weak self] in
                    self?.relayoutItems()
                }
                row.configure(
                    tab: tab,
                    selected: selected,
                    canClose: canClose,
                    presentation: configuration.presentation
                )
                row.isHidden = false
            }
        }

        for (id, header) in headerViews where !activeHeaderIDs.contains(id) {
            if hoveredHeader === header { hoveredHeader = nil }
            header.removeFromSuperview()
            headerViews.removeValue(forKey: id)
        }
        for (id, row) in rowViews where !activeTabIDs.contains(id) {
            if hoveredRow === row { hoveredRow = nil }
            row.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }

        relayoutItems()
        scrollSelectedRowToVisibleIfNeeded()
        lastSelectedID = configuration.selectedID
        refreshPointerHover()
    }

    func relayoutItems() {
        guard isViewLoaded else { return }
        let clipSize = scrollView.contentView.bounds.size
        let panelWidth = max(clipSize.width, view.bounds.width)
        let rowWidth = max(0, panelWidth - NativeInboxMetrics.sidebarHorizontalMargin * 2)
        let x = NativeInboxMetrics.sidebarHorizontalMargin
        let collapsed = configuration.layoutState.collapsedGroupIDs

        var y = NativeInboxMetrics.topContentPadding
        var renderedAnySection = false
        var nextKeys: [String] = []
        var nextVisibleTabs: [GhosttyOrganizedTab] = []

        for group in configuration.groups {
            let groupCollapsed = group.title != nil && collapsed.contains(group.id)
            if group.title != nil, let header = headerViews[group.id] {
                if renderedAnySection {
                    y += NativeInboxMetrics.sectionTopMargin
                }
                renderedAnySection = true
                header.frame = NSRect(
                    x: x,
                    y: y,
                    width: rowWidth,
                    height: NativeInboxMetrics.sectionHeaderHeight
                )
                header.layoutSubtreeIfNeeded()
                y += NativeInboxMetrics.sectionHeaderHeight
                nextKeys.append("group:\(group.id)")
                if !groupCollapsed && !group.tabs.isEmpty {
                    y += NativeInboxMetrics.sectionBottomGap
                }
            }

            guard !groupCollapsed else { continue }
            for (index, tab) in group.tabs.enumerated() {
                guard let row = rowViews[tab.controller.tabSessionID] else { continue }
                if index > 0 {
                    y += NativeInboxMetrics.rowVerticalGap
                }
                let height = row.preferredHeight
                row.frame = NSRect(x: x, y: y, width: rowWidth, height: height)
                row.layoutSubtreeIfNeeded()
                y += height
                nextKeys.append("tab:\(tab.controller.tabSessionID)")
                nextVisibleTabs.append(tab)
            }
        }

        orderedItemKeys = nextKeys
        visibleTabs = nextVisibleTabs
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: panelWidth,
            height: max(clipSize.height, y + NativeInboxMetrics.bottomContentPadding)
        )
    }

    private func toggleSection(_ groupID: String) {
        configuration.layoutState.toggleGroup(groupID)
    }

    private func activate(tab: GhosttyOrganizedTab) {
        let controller = tab.controller
        lastSelectedID = tab.id
        controller.selectVerticalTab(controller)
        if let surface = controller.focusedSurface ?? controller.surfaceTree.first {
            Ghostty.moveFocus(to: surface)
        }
    }

    private func activateAndRename(tab: GhosttyOrganizedTab) {
        activate(tab: tab)
        tab.controller.promptTabTitle()
    }

    private func scrollSelectedRowToVisibleIfNeeded() {
        guard lastSelectedID != configuration.selectedID,
              let selectedTab = visibleTabs.first(where: { $0.id == configuration.selectedID }),
              let row = rowViews[selectedTab.controller.tabSessionID] else { return }
        let visible = documentView.visibleRect
        guard !visible.isEmpty,
              row.frame.minY < visible.minY || row.frame.maxY > visible.maxY else { return }
        documentView.scrollToVisible(row.frame.insetBy(dx: 0, dy: -4))
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // Up arrow
            stepSelection(by: -1)
            return true
        case 125: // Down arrow
            stepSelection(by: 1)
            return true
        case 36, 76: // Return / Enter
            if let selected = visibleTabs.first(where: { $0.id == configuration.selectedID }) {
                activate(tab: selected)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func stepSelection(by delta: Int) {
        guard !visibleTabs.isEmpty else { return }
        let currentIndex = visibleTabs.firstIndex { $0.id == configuration.selectedID } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), visibleTabs.count - 1)
        guard nextIndex != currentIndex else { return }
        let target = visibleTabs[nextIndex]
        lastSelectedID = target.id
        configuration.controller.selectVerticalTab(target.controller)
        windowMakeDocumentFirstResponder()
    }

    private func windowMakeDocumentFirstResponder() {
        guard let window = view.window else { return }
        window.makeFirstResponder(documentView)
    }

    // MARK: - Container-level Hover Routing

    func updateHover(at documentPoint: NSPoint?) {
        guard let point = documentPoint else {
            clearHover()
            return
        }
        if let row = visibleTabs.lazy
            .compactMap({ rowViews[$0.controller.tabSessionID] })
            .first(where: { !$0.isHidden && $0.frame.contains(point) }) {
            if hoveredHeader != nil {
                hoveredHeader?.isHovered = false
                hoveredHeader = nil
            }
            if hoveredRow !== row {
                hoveredRow?.isHovered = false
                hoveredRow = row
            }
            row.isHovered = true
            let local = documentView.convert(point, to: row)
            row.isCloseHovered = row.closeButtonHitRect.contains(local)
            return
        }

        if hoveredRow != nil {
            hoveredRow?.isHovered = false
            hoveredRow = nil
        }

        if let header = headerViews.values.first(where: { !$0.isHidden && $0.frame.contains(point) }) {
            if hoveredHeader !== header {
                hoveredHeader?.isHovered = false
                hoveredHeader = header
            }
            header.isHovered = true
        } else if hoveredHeader != nil {
            hoveredHeader?.isHovered = false
            hoveredHeader = nil
        }
    }

    func clearHover() {
        hoveredRow?.isHovered = false
        hoveredRow = nil
        hoveredHeader?.isHovered = false
        hoveredHeader = nil
    }

    private func refreshPointerHover() {
        guard let window = scrollView.window,
              window.isKeyWindow,
              window.isVisible,
              !scrollView.isHiddenOrHasHiddenAncestor,
              NativePointerLocation.contains(scrollView) else {
            clearHover()
            return
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let scrollPoint = scrollView.convert(windowPoint, from: nil)
        guard scrollView.visibleRect.contains(scrollPoint) else {
            clearHover()
            return
        }
        updateHover(at: documentView.convert(windowPoint, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard NativePointerLocation.contains(scrollView, event: event) else {
            clearHover()
            return
        }
        updateHover(at: documentView.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }
}
