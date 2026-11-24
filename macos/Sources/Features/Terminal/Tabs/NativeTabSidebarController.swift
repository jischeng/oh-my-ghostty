import AppKit
import Combine
import SwiftUI

struct NativeTabSidebarConfiguration {
    let controller: TerminalController
    let layoutState: VerticalTabWindowLayoutState
    let statusStore: TabActivityStore
    let backgroundColor: NSColor
    var backgroundOpacity: Double = 1
    var iconProvider = AnyGhosttyTabIconProvider(CompositeGhosttyTabIconProvider(overrides: []))
}

/// The window container retains this view; the group retains it weakly.
/// Its controller survives moving between native tab windows.
final class NativeTabSidebarHostingView: NSView {
    let sidebar: NativeTabSidebarController

    init(configuration: NativeTabSidebarConfiguration) {
        sidebar = NativeTabSidebarController(configuration: configuration)
        super.init(frame: .zero)
        let content = sidebar.view
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ configuration: NativeTabSidebarConfiguration) { sidebar.configure(configuration) }
}

final class NativeTabSidebarController: NSViewController, NSPopoverDelegate {
    private(set) var configuration: NativeTabSidebarConfiguration
    private(set) var list: NativeTabOutlineController!
    private let workspaceButton = TerminalWorkspaceHeaderButton()
    private let backgroundButton = SessionRuntimeBackgroundHeaderButton()
    private let inboxButton = TabInboxHeaderButton()
    private let optionsButton = NativeOptionsControl()
    private let backgroundPopover = NSPopover()
    private let organization = GhosttyTabOrganizationModel()
    private var subscriptions = Set<AnyCancellable>()
    private var metadataSubscriptions = Set<AnyCancellable>()
    private var tabIDs: [ObjectIdentifier] = []
    private var scheduled = false
    private var workspaceWidth: NSLayoutConstraint?
    private var backgroundWidth: NSLayoutConstraint?
    private let themeObserver = OMGNativeThemeObserver()
    private(set) var refreshCount = 0
    /// The inbox rows on screen. They can lag behind the fresh order while
    /// the pointer holds them in place.
    private var displayedInbox: (grouping: GhosttyTabGroupingMode, ordering: GhosttyTabOrderingMode,
                                 rows: [TabInboxRows<ObjectIdentifier>])?
    /// Titles and icons of the groups on screen. A held group can have left
    /// the fresh order and keeps the header it had.
    private var inboxHeaders: [String: TabInboxHeader] = [:]
    private(set) var inboxOrderIsPending = false
    private var inboxReleaseWorkItem: DispatchWorkItem?

    init(configuration: NativeTabSidebarConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        backgroundPopover.behavior = .transient
        backgroundPopover.animates = false
        backgroundPopover.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.clipsToBounds = true
        root.setAccessibilityIdentifier("native.tab.sidebar")
        let header = NSStackView(views: [workspaceButton, NSView(), backgroundButton, inboxButton, optionsButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        backgroundButton.target = self
        backgroundButton.action = #selector(toggleBackgroundPopover)
        optionsButton.configure(title: "", symbol: "ellipsis", help: ChromeStrings.current.organizeTabs,
                                enabled: true, style: .plain, identifier: "tabs.organize")
        inboxButton.onPress = { [weak self] in self?.toggleInbox() }
        configureInboxButton(ChromeStrings.current)
        list = NativeTabOutlineController(outlineConfiguration())
        list.pointerDidLeave = { [weak self] in self?.applyPendingInboxOrder() }
        addChild(list)
        let content = list.view
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(content)
        let width = workspaceButton.widthAnchor.constraint(equalToConstant: 160)
        width.priority = .defaultHigh
        workspaceWidth = width
        let bgWidth = backgroundButton.widthAnchor.constraint(equalToConstant: 26)
        backgroundWidth = bgWidth
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            bgWidth,
            backgroundButton.heightAnchor.constraint(equalToConstant: 24),
            inboxButton.widthAnchor.constraint(equalToConstant: 24),
            inboxButton.heightAnchor.constraint(equalToConstant: 24),
            optionsButton.widthAnchor.constraint(equalToConstant: 24),
            optionsButton.heightAnchor.constraint(equalToConstant: 24),
            workspaceButton.heightAnchor.constraint(equalToConstant: 28),
            width,
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        themeObserver.onChange = { [weak self] _ in self?.scheduleRefresh() }
        bind()
        refresh(force: true)
    }

    func configure(_ next: NativeTabSidebarConfiguration) {
        guard !next.controller.workspaceCoordinator.isTerminating else { return }
        let rebind = configuration.controller !== next.controller || configuration.layoutState !== next.layoutState ||
            configuration.statusStore !== next.statusStore
        if configuration.controller !== next.controller {
            optionsButton.dismiss()
            backgroundPopover.close()
            configuration.controller.workspacePopover.close()
        }
        if configuration.layoutState !== next.layoutState { forgetInboxOrder() }
        configuration = next
        guard isViewLoaded else { return }
        if rebind { bind() }
        refresh(force: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bgw = backgroundButton.preferredWidth
        backgroundWidth?.constant = bgw
        // Margins, the inbox and options buttons, and the header spacing.
        workspaceWidth?.constant = workspaceButton.fittingSize(proposedWidth: max(50, view.bounds.width - 84 - bgw)).width
    }

    private var isInbox: Bool { OhMyGhosttySettings.shared.tabSidebarViewMode == .inbox }

    /// Only the recency order depends on interaction and agent timestamps.
    private var inboxFollowsRecency: Bool {
        isInbox && OhMyGhosttySettings.shared.tabInboxOrderingMode == .recentlyUsed
    }

    /// Project groups follow each tab's directory. The inbox has its own grouping.
    private var groupsByProject: Bool {
        isInbox ? OhMyGhosttySettings.shared.tabInboxGroupingMode == .project
            : configuration.layoutState.groupingMode == .project
    }

    private func toggleInbox() {
        // Every sidebar observes the settings, so all windows switch together.
        let settings = OhMyGhosttySettings.shared
        settings.tabSidebarViewMode = settings.tabSidebarViewMode == .inbox ? .tabs : .inbox
    }

    private func configureInboxButton(_ strings: ChromeStrings) {
        let shown = isInbox
        // The inbox lists the waiting tabs itself; the dot is for the Tabs view.
        let attention = shown ? 0 : TabInboxModel.attentionCount(tabs: tabs, activities: configuration.statusStore)
        inboxButton.update(shown: shown, attention: attention, strings: strings)
    }

    private func applyPendingInboxOrder() {
        guard inboxOrderIsPending else { return }
        scheduleRefresh()
    }

    @objc private func toggleBackgroundPopover() {
        if backgroundPopover.isShown {
            backgroundPopover.close()
            backgroundButton.setPresentationActive(false)
            return
        }
        SessionRuntimeBackgroundStore.shared.refresh()
        let content = SessionRuntimeBackgroundPopover(controller: configuration.controller) { [weak self] in
            self?.backgroundPopover.close()
        }
        content.onPreferredSizeChange = { [weak popover = backgroundPopover] size in
            popover?.contentSize = size
        }
        content.bindTheme(to: configuration.controller.window)
        backgroundPopover.contentViewController = content
        backgroundPopover.contentSize = content.fittingSize()
        backgroundButton.setPresentationActive(true)
        backgroundPopover.show(relativeTo: backgroundButton.bounds, of: backgroundButton, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        backgroundButton.setPresentationActive(false)
    }

    private var tabs: [TerminalController] {
        let current = configuration.layoutState.tabSnapshot.controllers
        return current.isEmpty ? [configuration.controller] : current
    }

    private func bind() {
        subscriptions.removeAll()
        metadataSubscriptions.removeAll()
        tabIDs = []
        let config = configuration
        let changes: [AnyPublisher<Void, Never>] = [
            config.layoutState.objectWillChange.eraseToAnyPublisher(),
            config.layoutState.tabPresentation.objectWillChange.eraseToAnyPublisher(),
            config.statusStore.objectWillChange.eraseToAnyPublisher(),
            config.controller.objectWillChange.eraseToAnyPublisher(),
            config.controller.workspaceCoordinator.store.objectWillChange.eraseToAnyPublisher(),
            config.controller.workspaceCoordinator.objectWillChange.eraseToAnyPublisher(),
            OhMyGhosttySettings.shared.objectWillChange.eraseToAnyPublisher(),
            SessionRuntimeBackgroundStore.shared.objectWillChange.eraseToAnyPublisher(),
            // A conversation title adds or replaces a row's title and subtitle.
            AgentConversationTitleStore.shared.objectWillChange.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .omgDockAttentionDidChange).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        // Today and Yesterday move at midnight without any tab changing.
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in if self?.isInbox == true { self?.scheduleRefresh() } }
            .store(in: &subscriptions)
        SessionRuntimeBackgroundStore.shared.startMonitoringIfNeeded()
        themeObserver.sourceWindow = config.controller.window
    }

    private func observeMetadata() {
        let ids = tabs.map(ObjectIdentifier.init)
        guard ids != tabIDs else { return }
        tabIDs = ids
        SessionRuntimeBackgroundStore.shared.refresh()
        metadataSubscriptions.removeAll()
        for tab in tabs {
            tab.objectWillChange.sink { [weak self] _ in
                if self?.groupsByProject == true { self?.scheduleRefresh() }
            }.store(in: &metadataSubscriptions)
            // Activation orders the Tabs view; the inbox follows interaction.
            tab.$tabLastActivatedAt.dropFirst().sink { [weak self] _ in
                if self?.configuration.layoutState.orderingMode == .recentlyUsed { self?.scheduleRefresh() }
            }.store(in: &metadataSubscriptions)
            tab.$tabLastInteractionAt.dropFirst().sink { [weak self] _ in
                if self?.inboxFollowsRecency == true { self?.scheduleRefresh() }
            }.store(in: &metadataSubscriptions)
            tab.$tabLastAgentActivityAt.dropFirst().sink { [weak self] _ in
                if self?.inboxFollowsRecency == true { self?.scheduleRefresh() }
            }.store(in: &metadataSubscriptions)
            // Only a change of state moves a tab into or out of Continue, or
            // changes the inbox button's dot; progress and message updates of
            // a working agent do not.
            tab.$agentActivities.map { Set($0.values.map(\.state)) }.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &metadataSubscriptions)
            tab.$surfaceTree.dropFirst().sink { [weak self] _ in
                self?.tabIDs = []
                self?.scheduleRefresh()
            }.store(in: &metadataSubscriptions)
            for surface in tab.surfaceTree {
                surface.$pwd.dropFirst().sink { [weak self] _ in
                    if self?.groupsByProject == true { self?.scheduleRefresh() }
                }.store(in: &metadataSubscriptions)
            }
        }
    }

    private func scheduleRefresh() {
        guard !scheduled, !configuration.controller.workspaceCoordinator.isTerminating,
              isActivePresentation else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard !self.configuration.controller.workspaceCoordinator.isTerminating else { return }
            self.refresh()
        }
    }

    private var isActivePresentation: Bool {
        let controller = configuration.controller
        guard !controller.workspaceCoordinator.isTerminating,
              !TerminalWorkspacePresentation.isChanging, !controller.workspacePresentationIsParked,
              !controller.workspaceTabAttachmentIsPending, let window = controller.window else { return false }
        if controller.workspaceCoordinator.hasNonNativeFullscreen(in: controller.windowSessionID),
           !window.isVisible { return false }
        guard window.isSelectedInTabGroup else { return false }
        let selectedID = configuration.layoutState.tabSnapshot.selectedID
        return selectedID == nil || selectedID == ObjectIdentifier(controller)
    }

    private func refresh(force: Bool = false) {
        guard isViewLoaded else { return }
        guard !configuration.controller.workspaceCoordinator.isTerminating else { return }
        guard force || isActivePresentation else { return }
        refreshCount += 1
        observeMetadata()
        let config = configuration
        view.layer?.backgroundColor = config.backgroundColor.withAlphaComponent(config.backgroundOpacity).cgColor
        workspaceButton.configure(.resolve(controller: config.controller, activities: config.statusStore),
                                  controller: config.controller) { [weak controller = config.controller] in
            controller?.workspaceSwitcherIsPresented.toggle()
        }
        let bgCount = SessionRuntimeBackgroundStore.shared.items(for: config.controller).count
        backgroundButton.update(count: bgCount, isPresented: backgroundPopover.isShown)
        backgroundWidth?.constant = backgroundButton.preferredWidth
        // Settings changes schedule this refresh, so the tooltip and menu
        // follow a language switch without rebuilding the sidebar.
        let strings = ChromeStrings.current
        optionsButton.configure(title: "", symbol: "ellipsis", help: strings.organizeTabs,
                                enabled: true, style: .plain, identifier: "tabs.organize")
        configureInboxButton(strings)
        optionsButton.entries = isInbox ? inboxEntries(strings) : organizationEntries(strings)
        list.update(outlineConfiguration())
        view.needsLayout = true
    }

    /// The Tabs view's grouping and ordering, which also arrange the native tabs.
    private func organizationEntries(_ strings: ChromeStrings) -> [NativeMenuEntry] {
        let config = configuration
        return organizationEntries(
            strings, grouping: config.layoutState.groupingMode, ordering: config.layoutState.orderingMode,
            setGrouping: { [weak controller = config.controller] in controller?.setTabGroupingMode($0) },
            setOrdering: { [weak controller = config.controller] in controller?.setTabOrderingMode($0) })
    }

    /// The same choices for the inbox. They are its own settings and only
    /// change what the list displays.
    private func inboxEntries(_ strings: ChromeStrings) -> [NativeMenuEntry] {
        let settings = OhMyGhosttySettings.shared
        return organizationEntries(
            strings, grouping: settings.tabInboxGroupingMode, ordering: settings.tabInboxOrderingMode,
            setGrouping: { OhMyGhosttySettings.shared.tabInboxGroupingMode = $0 },
            setOrdering: { OhMyGhosttySettings.shared.tabInboxOrderingMode = $0 })
    }

    private func organizationEntries(
        _ strings: ChromeStrings, grouping: GhosttyTabGroupingMode, ordering: GhosttyTabOrderingMode,
        setGrouping: @escaping (GhosttyTabGroupingMode) -> Void,
        setOrdering: @escaping (GhosttyTabOrderingMode) -> Void
    ) -> [NativeMenuEntry] {
        var entries: [NativeMenuEntry] = [.action(strings.groupHeader, enabled: false) {}]
        for mode in GhosttyTabGroupingMode.allCases {
            entries.append(.action(strings.groupingTitle(mode), checked: grouping == mode) { setGrouping(mode) })
        }
        entries.append(.separator)
        entries.append(.action(strings.orderHeader, enabled: false) {})
        for mode in GhosttyTabOrderingMode.allCases {
            entries.append(.action(strings.orderingTitle(mode), checked: ordering == mode) { setOrdering(mode) })
        }
        return entries
    }

    private func outlineConfiguration() -> NativeTabOutlineConfiguration {
        let config = configuration
        let inbox = isInbox
        // The inbox only changes what the list displays. The native tab order,
        // grouping and ordering are untouched, so the Tabs view returns as it was.
        let groups = inbox ? inboxGroups() : organization.groups(
            tabs: tabs, grouping: config.layoutState.groupingMode, ordering: config.layoutState.orderingMode)
        if !inbox { forgetInboxOrder() }
        return NativeTabOutlineConfiguration(
            groups: groups,
            selectedID: config.layoutState.pendingSelectedTabID ?? config.layoutState.tabSnapshot.selectedID,
            layoutState: config.layoutState, controller: config.controller,
            metrics: inbox ? .inbox : .tabs(rowHeight: OhMyGhosttySettings.shared.tabRowDensity.rowHeight),
            allowsReordering: !inbox,
            // The resolver's rule, without resolving the whole presentation.
            showsSubtitle: { [weak self] in
                $0.controller.tabTitleHasSubtitle(activities: self?.configuration.statusStore)
            },
            presentation: { [weak self] in self?.presentation(for: $0) }
        )
    }

    private func inboxGroups() -> [GhosttyTabGroupPresentation] {
        let settings = OhMyGhosttySettings.shared
        let grouping = settings.tabInboxGroupingMode
        let ordering = settings.tabInboxOrderingMode
        let tabs = self.tabs
        let fresh = TabInboxModel.groups(tabs: tabs, grouping: grouping, ordering: ordering,
                                         organization: organization, activities: configuration.statusStore)
        let freshRows = TabInboxModel.rows(fresh)
        var shown = freshRows
        // Rows must not jump under the pointer. An explicit change of the
        // grouping or ordering applies at once.
        if let displayedInbox, displayedInbox.grouping == grouping, displayedInbox.ordering == ordering,
           list?.isPointerHoldingOrder == true {
            shown = TabInboxModel.holding(fresh: freshRows, displayed: displayedInbox.rows)
        }
        let shownIDs = Set(shown.map(\.id))
        var headers = inboxHeaders.filter { shownIDs.contains($0.key) }
        for group in fresh { headers[group.id] = TabInboxHeader(title: group.title, icon: group.icon) }
        inboxHeaders = headers
        displayedInbox = (grouping, ordering, shown)
        inboxOrderIsPending = shown != freshRows
        inboxReleaseWorkItem?.cancel()
        inboxReleaseWorkItem = nil
        if inboxOrderIsPending {
            // The pointer may rest on the list instead of leaving it.
            let release = DispatchWorkItem { [weak self] in self?.applyPendingInboxOrder() }
            inboxReleaseWorkItem = release
            DispatchQueue.main.asyncAfter(deadline: .now() + NativeTabListPointer.restInterval + 0.1, execute: release)
        }
        let groups = inboxOrderIsPending ? TabInboxModel.groups(shown, headers: headers, of: tabs) : fresh
        // `goto_tab` and the shortcut labels count the rows the user sees,
        // held or not. A hidden sidebar shows none, so they stay native.
        let visible = configuration.layoutState.isSidebarVisible
        configuration.layoutState.publishInboxDisplayOrder(visible ? groups.flatMap(\.tabs).map(\.controller) : [])
        return groups
    }

    private func forgetInboxOrder() {
        displayedInbox = nil
        inboxHeaders = [:]
        inboxOrderIsPending = false
        inboxReleaseWorkItem?.cancel()
        inboxReleaseWorkItem = nil
        configuration.layoutState.publishInboxDisplayOrder([])
    }

    /// The number `goto_tab` selects this row with: its place from the top in
    /// the inbox, the native index in the Tabs view.
    private func shortcutIndex(for tab: GhosttyOrganizedTab) -> Int {
        guard configuration.controller.tabShortcutsFollowInbox else { return tab.actualIndex }
        return configuration.layoutState.inboxDisplayOrder.position(of: tab.id) ?? tab.actualIndex
    }

    private func presentation(for tab: GhosttyOrganizedTab) -> GhosttyTabPresentation? {
        TerminalTabPresentationResolver.resolve(tab.controller, index: shortcutIndex(for: tab),
            selected: tab.id == configuration.layoutState.tabSnapshot.selectedID,
            activities: configuration.statusStore, icons: configuration.iconProvider,
            style: isInbox ? .inbox : .sidebar)
    }
}
