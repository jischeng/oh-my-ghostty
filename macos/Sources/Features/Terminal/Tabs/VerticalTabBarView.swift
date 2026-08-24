import Combine
import SwiftUI
import UniformTypeIdentifiers

struct VerticalTabSidebarMetrics {
    static let minimumWidth: CGFloat = 176
    static let defaultWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 480

    @MainActor
    static var persistedWidth: CGFloat {
        let stored = CGFloat(OhMyGhosttySettings.shared.defaultSidebarWidth)
        return min(max(stored, minimumWidth), maximumWidth)
    }

    @MainActor
    static func persist(_ width: CGFloat) {
        guard OhMyGhosttySettings.shared.rememberSidebarWidth else { return }
        OhMyGhosttySettings.shared.defaultSidebarWidth = Double(
            min(max(width, minimumWidth), maximumWidth)
        )
    }
}

enum GhosttyTabGroupingMode: String, CaseIterable {
    case none
    case project
    case date

    var title: String {
        switch self {
        case .none: "No Grouping"
        case .project: "By Project"
        case .date: "By Date"
        }
    }
}

enum GhosttyTabOrderingMode: String, CaseIterable {
    case manual
    case created
    case recentlyUsed

    var title: String {
        switch self {
        case .manual: "Manual"
        case .created: "Created Time"
        case .recentlyUsed: "Recently Used"
        }
    }
}

@MainActor
final class VerticalTabWindowLayoutState: ObservableObject {
    @Published private(set) var isSidebarVisible: Bool
    @Published private(set) var sidebarWidth: CGFloat
    @Published private(set) var committedSidebarWidth: CGFloat
    @Published private(set) var groupingMode: GhosttyTabGroupingMode
    @Published private(set) var orderingMode: GhosttyTabOrderingMode
    @Published private(set) var collapsedGroupIDs: Set<String> = []
    @Published private(set) var isInspectorVisible = false
    @Published private(set) var inspectorWidth = RightInspectorMetrics.defaultWidth
    @Published private(set) var committedInspectorWidth = RightInspectorMetrics.defaultWidth
    @Published private(set) var selectedInspectorPaneID: String?

    private var pendingSidebarWidth: CGFloat?
    private var resizeWorkItem: DispatchWorkItem?
    private var pendingInspectorWidth: CGFloat?
    private var inspectorResizeWorkItem: DispatchWorkItem?
    private(set) var appliedResizeCount = 0
    private(set) var appliedInspectorResizeCount = 0
    private let settings: OhMyGhosttySettings
    private let inspectorPresentation: InspectorPresentationStore

    init(
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat? = nil,
        settings: OhMyGhosttySettings? = nil,
        inspectorPresentation: InspectorPresentationStore? = nil
    ) {
        let settings = settings ?? OhMyGhosttySettings.shared
        let inspectorPresentation = inspectorPresentation ?? InspectorPresentationStore.shared
        self.settings = settings
        self.inspectorPresentation = inspectorPresentation
        let initialWidth = sidebarWidth ?? CGFloat(settings.defaultSidebarWidth)
        self.isSidebarVisible = isSidebarVisible
        self.sidebarWidth = initialWidth
        self.committedSidebarWidth = initialWidth
        self.groupingMode = settings.groupingMode
        self.orderingMode = settings.orderingMode
        self.isInspectorVisible = inspectorPresentation.snapshot.isVisible
        let inspectorWidth = CGFloat(inspectorPresentation.snapshot.width)
        self.inspectorWidth = inspectorWidth
        self.committedInspectorWidth = inspectorWidth
        self.selectedInspectorPaneID = inspectorPresentation.snapshot.selectedPaneID
    }

    func setSidebarVisible(_ visible: Bool) {
        guard isSidebarVisible != visible else { return }
        isSidebarVisible = visible
    }

    func applySidebarPreferences(
        visible: Bool,
        width proposedWidth: CGFloat,
        availableWidth: CGFloat
    ) {
        setSidebarVisible(visible)
        let maximumWidth = min(
            VerticalTabSidebarMetrics.maximumWidth,
            max(VerticalTabSidebarMetrics.minimumWidth, availableWidth * 0.5)
        )
        let width = min(
            max(proposedWidth, VerticalTabSidebarMetrics.minimumWidth),
            maximumWidth
        )
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        pendingSidebarWidth = nil
        applySidebarWidth(width)
        committedSidebarWidth = width
    }

    func toggleSidebar() {
        setSidebarVisible(!isSidebarVisible)
    }

    func setInspectorVisible(_ visible: Bool) {
        guard isInspectorVisible != visible else { return }
        isInspectorVisible = visible
        inspectorPresentation.setVisible(visible)
    }

    func toggleInspector() {
        setInspectorVisible(!isInspectorVisible)
    }

    func selectInspectorPane(_ paneID: String?) {
        guard selectedInspectorPaneID != paneID else { return }
        selectedInspectorPaneID = paneID
        inspectorPresentation.selectPane(paneID)
    }

    func setGroupingMode(_ mode: GhosttyTabGroupingMode) {
        guard groupingMode != mode else { return }
        groupingMode = mode
        settings.groupingMode = mode
    }

    func setOrderingMode(_ mode: GhosttyTabOrderingMode) {
        guard orderingMode != mode else { return }
        orderingMode = mode
        settings.orderingMode = mode
    }

    func applyPreferences(
        grouping: GhosttyTabGroupingMode,
        ordering: GhosttyTabOrderingMode
    ) {
        if groupingMode != grouping { groupingMode = grouping }
        if orderingMode != ordering { orderingMode = ordering }
    }

    func toggleGroup(_ id: String) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    func updateSidebarWidth(_ proposedWidth: CGFloat, availableWidth: CGFloat, persist: Bool) {
        let maximumWidth = min(
            VerticalTabSidebarMetrics.maximumWidth,
            max(VerticalTabSidebarMetrics.minimumWidth, availableWidth * 0.5)
        )
        let width = min(max(proposedWidth, VerticalTabSidebarMetrics.minimumWidth), maximumWidth)

        if persist {
            resizeWorkItem?.cancel()
            resizeWorkItem = nil
            pendingSidebarWidth = nil
            applySidebarWidth(width)
            if committedSidebarWidth != width {
                committedSidebarWidth = width
            }
            if settings.rememberSidebarWidth {
                settings.defaultSidebarWidth = Double(width)
            }
            return
        }

        pendingSidebarWidth = width
        guard resizeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeWorkItem = nil
            guard let width = self.pendingSidebarWidth else { return }
            self.pendingSidebarWidth = nil
            self.applySidebarWidth(width)
        }
        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0 / 60.0,
            execute: workItem
        )
    }

    func updateInspectorWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat,
        persist: Bool
    ) {
        let maximumWidth = min(
            RightInspectorMetrics.maximumWidth,
            max(RightInspectorMetrics.minimumWidth, availableWidth * 0.5)
        )
        let width = min(max(proposedWidth, RightInspectorMetrics.minimumWidth), maximumWidth)

        if persist {
            inspectorResizeWorkItem?.cancel()
            inspectorResizeWorkItem = nil
            pendingInspectorWidth = nil
            applyInspectorWidth(width)
            committedInspectorWidth = width
            inspectorPresentation.setWidth(width)
            return
        }

        pendingInspectorWidth = width
        guard inspectorResizeWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inspectorResizeWorkItem = nil
            guard let width = self.pendingInspectorWidth else { return }
            self.pendingInspectorWidth = nil
            self.applyInspectorWidth(width)
        }
        inspectorResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0 / 60.0,
            execute: workItem
        )
    }

    private func applySidebarWidth(_ width: CGFloat) {
        guard sidebarWidth != width else { return }
        sidebarWidth = width
        appliedResizeCount += 1
    }

    private func applyInspectorWidth(_ width: CGFloat) {
        guard inspectorWidth != width else { return }
        inspectorWidth = width
        appliedInspectorResizeCount += 1
    }
}

struct GhosttyTabStyle {
    static let rowHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 5
    static let horizontalPadding: CGFloat = 8
    static let contentSpacing: CGFloat = 8
    static let shortcutFontSize = NSFont.smallSystemFontSize

    static func backgroundOpacity(selected: Bool, hovered: Bool) -> Double {
        if selected { return 0.14 }
        if hovered { return 0.07 }
        return 0
    }

    static func iconColor(selected: Bool, hovered: Bool) -> Color {
        if selected { return .accentColor }
        if hovered { return .primary }
        return .secondary
    }
}

enum GhosttyTabIcon {
    case systemSymbol(String)
    case asset(String)
    case image(NSImage)
}

struct GhosttyTabGroupIdentity {
    let id: String
    let title: String
    let icon: GhosttyTabIcon
}

struct GhosttyTabMetadata {
    let project: GhosttyTabGroupIdentity?
    let agent: GhosttyTabGroupIdentity?
    let workspace: GhosttyTabGroupIdentity?
    let customGroup: GhosttyTabGroupIdentity?
}

struct GhosttyTabMetadataContext {
    let tabID: UUID
    let title: String
    let workingDirectory: String?
}

protocol GhosttyTabMetadataProviding {
    func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata?
}

struct AnyGhosttyTabMetadataProvider: GhosttyTabMetadataProviding {
    private let resolve: (GhosttyTabMetadataContext) -> GhosttyTabMetadata?

    init<Provider: GhosttyTabMetadataProviding>(_ provider: Provider) {
        self.resolve = provider.metadata
    }

    func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
        resolve(context)
    }
}

struct CompositeGhosttyTabMetadataProvider: GhosttyTabMetadataProviding {
    let providers: [AnyGhosttyTabMetadataProvider]

    func metadata(for context: GhosttyTabMetadataContext) -> GhosttyTabMetadata? {
        for provider in providers {
            if let metadata = provider.metadata(for: context) { return metadata }
        }
        return nil
    }
}

struct GhosttyTabIconContext {
    let tabID: UUID
    let title: String
    let activity: TabActivity?
    let defaultIcon: GhosttyTabIcon?

    init(
        tabID: UUID,
        title: String,
        activity: TabActivity?,
        defaultIcon: GhosttyTabIcon? = nil
    ) {
        self.tabID = tabID
        self.title = title
        self.activity = activity
        self.defaultIcon = defaultIcon
    }
}

protocol GhosttyTabIconProviding {
    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon?
}

struct DefaultGhosttyTabIconProvider: GhosttyTabIconProviding {
    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
        if let icon = context.activity?.icon {
            return switch icon.kind {
            case .systemSymbol: .systemSymbol(icon.name)
            case .bundledAsset: .asset(icon.name)
            }
        }
        return context.defaultIcon ?? .systemSymbol("terminal")
    }
}

struct AnyGhosttyTabIconProvider: GhosttyTabIconProviding {
    private let resolve: (GhosttyTabIconContext) -> GhosttyTabIcon?

    init<Provider: GhosttyTabIconProviding>(_ provider: Provider) {
        self.resolve = provider.icon
    }

    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
        resolve(context)
    }
}

struct CompositeGhosttyTabIconProvider: GhosttyTabIconProviding {
    let overrides: [AnyGhosttyTabIconProvider]
    let fallback = DefaultGhosttyTabIconProvider()

    func icon(for context: GhosttyTabIconContext) -> GhosttyTabIcon? {
        for provider in overrides {
            if let icon = provider.icon(for: context) { return icon }
        }
        return fallback.icon(for: context)
    }
}

struct GhosttyTabPresentation {
    let title: String
    let shortcut: String?
    let icon: GhosttyTabIcon
    let activity: TabActivity?
    let selected: Bool
    let hovered: Bool
}

struct GhosttyOrganizedTab: Identifiable {
    let controller: TerminalController
    let actualIndex: Int
    var id: ObjectIdentifier { ObjectIdentifier(controller) }
}

struct GhosttyTabGroupPresentation: Identifiable {
    let id: String
    let title: String?
    let icon: GhosttyTabIcon?
    var tabs: [GhosttyOrganizedTab]
}

@MainActor
final class GhosttyTabOrganizationModel: ObservableObject {
    private var projectCache: [String: GhosttyTabGroupIdentity] = [:]
    private let metadataProvider: AnyGhosttyTabMetadataProvider

    init(
        metadataProvider: AnyGhosttyTabMetadataProvider = .init(
            CompositeGhosttyTabMetadataProvider(providers: [])
        )
    ) {
        self.metadataProvider = metadataProvider
    }

    func groups(
        tabs: [TerminalController],
        grouping: GhosttyTabGroupingMode,
        ordering: GhosttyTabOrderingMode,
        now: Date = Date()
    ) -> [GhosttyTabGroupPresentation] {
        var organized = tabs.enumerated().map {
            GhosttyOrganizedTab(controller: $0.element, actualIndex: $0.offset + 1)
        }
        switch ordering {
        case .manual:
            break
        case .created:
            organized.sort {
                if $0.controller.tabCreatedAt == $1.controller.tabCreatedAt {
                    return $0.actualIndex < $1.actualIndex
                }
                return $0.controller.tabCreatedAt < $1.controller.tabCreatedAt
            }
        case .recentlyUsed:
            organized.sort {
                if $0.controller.tabLastActivatedAt == $1.controller.tabLastActivatedAt {
                    return $0.actualIndex < $1.actualIndex
                }
                return $0.controller.tabLastActivatedAt > $1.controller.tabLastActivatedAt
            }
        }

        guard grouping != .none else {
            return [.init(id: "all", title: nil, icon: nil, tabs: organized)]
        }

        var groups: [GhosttyTabGroupPresentation] = []
        var indices: [String: Int] = [:]
        for tab in organized {
            let identity: (id: String, title: String, icon: GhosttyTabIcon)
            switch grouping {
            case .none:
                continue
            case .project:
                let project = projectIdentity(for: tab.controller)
                identity = (project.id, project.title, project.icon)
            case .date:
                identity = dateIdentity(for: tab.controller.tabCreatedAt, now: now)
            }

            if let index = indices[identity.id] {
                groups[index].tabs.append(tab)
            } else {
                indices[identity.id] = groups.count
                groups.append(.init(
                    id: identity.id,
                    title: identity.title,
                    icon: identity.icon,
                    tabs: [tab]
                ))
            }
        }
        return groups
    }

    private func projectIdentity(for controller: TerminalController) -> GhosttyTabGroupIdentity {
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        let path = surface?.pwd ?? ""
        let metadata = metadataProvider.metadata(for: .init(
            tabID: controller.tabSessionID,
            title: controller.titleOverride ?? surface?.title ?? "Terminal",
            workingDirectory: surface?.pwd
        ))
        if let project = metadata?.project { return project }
        if let cached = projectCache[path] { return cached }
        guard !path.isEmpty else {
            let identity = GhosttyTabGroupIdentity(
                id: "project:other",
                title: "Other",
                icon: .systemSymbol("folder")
            )
            projectCache[path] = identity
            return identity
        }

        var url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        while !url.path.isEmpty, url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".git").path
            ) {
                let identity = GhosttyTabGroupIdentity(
                    id: "project:\(url.path)",
                    title: url.lastPathComponent,
                    icon: .systemSymbol("folder")
                )
                projectCache[path] = identity
                return identity
            }
            url.deleteLastPathComponent()
        }

        let title = URL(fileURLWithPath: path).lastPathComponent
        let identity = GhosttyTabGroupIdentity(
            id: path.isEmpty ? "project:other" : "cwd:\(path)",
            title: title.isEmpty ? "Other" : title,
            icon: .systemSymbol("folder")
        )
        projectCache[path] = identity
        return identity
    }

    private func dateIdentity(
        for date: Date,
        now: Date
    ) -> (id: String, title: String, icon: GhosttyTabIcon) {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return ("date:today", "Today", .systemSymbol("calendar"))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return ("date:yesterday", "Yesterday", .systemSymbol("calendar"))
        }
        return ("date:older", "Older", .systemSymbol("calendar"))
    }
}

struct TerminalTabSidebarView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var statusStore: TabActivityStore
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let backgroundColor: Color
    let backgroundOpacity: Double
    let iconProvider: AnyGhosttyTabIconProvider

    @StateObject private var organizationModel = GhosttyTabOrganizationModel()
    @State private var metadataRevision = 0
    @State private var draggedTabSessionID: UUID?
    @State private var dropTarget: VerticalTabDropTarget?

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        backgroundColor: Color,
        backgroundOpacity: Double = 1,
        iconProvider: AnyGhosttyTabIconProvider = .init(
            CompositeGhosttyTabIconProvider(overrides: [])
        )
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.iconProvider = iconProvider
    }

    private var tabs: [TerminalController] {
        controller.tabControllers.isEmpty
            ? [controller]
            : controller.tabControllers
    }

    var body: some View {
        let groups = organizedGroups
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groups) { group in
                        if let title = group.title, let icon = group.icon {
                            VerticalTabGroupHeader(
                                title: title,
                                icon: icon,
                                collapsed: groupIsCollapsed(group),
                                toggle: { layoutState.toggleGroup(group.id) }
                            )
                        }
                        if !groupIsCollapsed(group) {
                            ForEach(group.tabs) { organizedTab in
                                tabRow(
                                    organizedTab,
                                    groupID: group.id,
                                    groupSessionIDs: Set(group.tabs.map {
                                        $0.controller.tabSessionID
                                    })
                                )
                                .padding(.leading, group.title == nil ? 0 : 12)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
        }
        .background(backgroundColor.opacity(backgroundOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .onReceive(metadataChanges) { _ in
            metadataRevision &+= 1
        }
    }

    private var header: some View {
        HStack {
            Text("TABS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            TabOrganizationMenu(controller: controller, layoutState: layoutState)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var organizedGroups: [GhosttyTabGroupPresentation] {
        _ = metadataRevision
        return organizationModel.groups(
            tabs: tabs,
            grouping: layoutState.groupingMode,
            ordering: layoutState.orderingMode
        )
    }

    private var metadataChanges: AnyPublisher<Void, Never> {
        let activation = tabs.map {
            $0.$tabLastActivatedAt.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        let paths = tabs.compactMap { tab -> AnyPublisher<Void, Never>? in
            guard let surface = tab.focusedSurface ?? tab.surfaceTree.first else { return nil }
            return surface.$pwd.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        return Publishers.MergeMany(activation + paths).eraseToAnyPublisher()
    }

    private func groupIsCollapsed(_ group: GhosttyTabGroupPresentation) -> Bool {
        let containsSelected = group.tabs.contains {
            ObjectIdentifier($0.controller) == controller.selectedTabID
        }
        return layoutState.collapsedGroupIDs.contains(group.id) && !containsSelected
    }

    @ViewBuilder
    private func tabRow(
        _ organizedTab: GhosttyOrganizedTab,
        groupID: String,
        groupSessionIDs: Set<UUID>
    ) -> some View {
        let tab = organizedTab.controller
        let tabID = ObjectIdentifier(tab)
        let selected = controller.selectedTabID == tabID
        let hovered = controller.hoveredTabID == tabID
        if let surface = tab.focusedSurface ?? tab.surfaceTree.first {
            let activity = statusStore.activity(for: tab.tabSessionID)
            VerticalTabRow(
                controller: tab,
                surface: surface,
                presentation: presentation(
                    for: tab,
                    surface: surface,
                    index: organizedTab.actualIndex,
                    selected: selected,
                    hovered: hovered,
                    activity: activity
                ),
                canClose: tabs.count > 1,
                select: { controller.selectVerticalTab(tab) },
                close: { controller.closeVerticalTab(tab) },
                hoverChanged: {
                    controller.setVerticalTabHovered(tab, hovered: $0)
                }
            )
            .contentShape(Rectangle())
            .onDrag {
                controller.beginManualTabDrag()
                draggedTabSessionID = tab.tabSessionID
                return NSItemProvider(object: tab.tabSessionID.uuidString as NSString)
            }
            .onDrop(
                of: [UTType.utf8PlainText],
                delegate: VerticalTabRowDropDelegate(
                    controller: controller,
                    destination: tab,
                    groupID: groupID,
                    allowedSessionIDs: groupSessionIDs,
                    draggedSessionID: $draggedTabSessionID,
                    dropTarget: $dropTarget
                )
            )
            .overlay {
                VerticalTabInsertionIndicator(
                    target: dropTarget,
                    tabSessionID: tab.tabSessionID
                )
            }
        }
    }

    private func presentation(
        for tab: TerminalController,
        surface: Ghostty.SurfaceView,
        index: Int,
        selected: Bool,
        hovered: Bool,
        activity: TabActivity?
    ) -> GhosttyTabPresentation {
        let session = tab.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface.pwd,
            terminalTitle: surface.title
        )
        let resolvedTitle = tab.titleOverride ?? session.presentationTitle
        let context = GhosttyTabIconContext(
            tabID: tab.tabSessionID,
            title: resolvedTitle,
            activity: activity,
            defaultIcon: session.workspace?.icon ?? .systemSymbol(
                session.tabIconSystemName
            )
        )
        return .init(
            title: resolvedTitle,
            shortcut: settings.showShortcutLabels ? tab.tabShortcutLabel(for: index) : nil,
            icon: iconProvider.icon(for: context) ?? .systemSymbol("terminal"),
            activity: activity,
            selected: selected,
            hovered: hovered
        )
    }
}

struct VerticalTabDropPolicy {
    static func allows(source: UUID?, in allowedSessionIDs: Set<UUID>) -> Bool {
        source.map(allowedSessionIDs.contains) ?? false
    }

    static func insertionIndex(destinationIndex: Int, after: Bool) -> Int {
        destinationIndex + (after ? 1 : 0)
    }
}

private struct VerticalTabDropTarget: Equatable {
    enum Placement {
        case before
        case after
    }

    let tabSessionID: UUID
    let groupID: String
    let placement: Placement
}

private struct VerticalTabRowDropDelegate: DropDelegate {
    let controller: TerminalController
    let destination: TerminalController
    let groupID: String
    let allowedSessionIDs: Set<UUID>
    @Binding var draggedSessionID: UUID?
    @Binding var dropTarget: VerticalTabDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        VerticalTabDropPolicy.allows(
            source: draggedSessionID,
            in: allowedSessionIDs
        )
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard VerticalTabDropPolicy.allows(
            source: draggedSessionID,
            in: allowedSessionIDs
        ) else {
            return DropProposal(operation: .forbidden)
        }
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard dropTarget?.tabSessionID == destination.tabSessionID else { return }
        dropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dropTarget = nil
            draggedSessionID = nil
        }
        guard let draggedSessionID,
              VerticalTabDropPolicy.allows(
                  source: draggedSessionID,
                  in: allowedSessionIDs
              ),
              let source = controller.tabControllers.first(where: {
                  $0.tabSessionID == draggedSessionID
              }),
              let destinationIndex = controller.tabControllers.firstIndex(where: {
                  $0 === destination
              }) else { return false }

        let placement = dropTarget?.placement ?? .before
        let insertionIndex = VerticalTabDropPolicy.insertionIndex(
            destinationIndex: destinationIndex,
            after: placement == .after
        )
        _ = controller.reorderTab(source, toInsertionIndex: insertionIndex)
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard VerticalTabDropPolicy.allows(
            source: draggedSessionID,
            in: allowedSessionIDs
        ) else { return }
        dropTarget = .init(
            tabSessionID: destination.tabSessionID,
            groupID: groupID,
            placement: info.location.y < OhMyGhosttySettings.shared.tabRowDensity.rowHeight / 2
                ? .before
                : .after
        )
    }
}

private struct VerticalTabInsertionIndicator: View {
    let target: VerticalTabDropTarget?
    let tabSessionID: UUID

    var body: some View {
        VStack(spacing: 0) {
            if target?.tabSessionID == tabSessionID,
               target?.placement == .before {
                line
            }
            Spacer(minLength: 0)
            if target?.tabSessionID == tabSessionID,
               target?.placement == .after {
                line
            }
        }
        .allowsHitTesting(false)
    }

    private var line: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 3)
    }
}

private struct TabOrganizationMenu: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @State private var hovered = false

    var body: some View {
        Menu {
            Section("GROUP") {
                ForEach(GhosttyTabGroupingMode.allCases, id: \.self) { mode in
                    Button {
                        controller.setTabGroupingMode(mode)
                    } label: {
                        menuLabel(mode.title, selected: layoutState.groupingMode == mode)
                    }
                }
            }
            Section("ORDER") {
                ForEach(GhosttyTabOrderingMode.allCases, id: \.self) { mode in
                    Button {
                        controller.setTabOrderingMode(mode)
                    } label: {
                        menuLabel(mode.title, selected: layoutState.orderingMode == mode)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(hovered ? 0.07 : 0))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Organize Tabs")
        .accessibilityLabel("Organize Tabs")
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

private struct VerticalTabGroupHeader: View {
    let title: String
    let icon: GhosttyTabIcon
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                GhosttyTabIconView(icon: icon, color: .secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 26)
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

struct VerticalTabLayoutContainer<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var statusStore: TabActivityStore
    let backgroundColor: Color
    let backgroundOpacity: Double
    let content: Content

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        backgroundColor: Color,
        backgroundOpacity: Double = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if layoutState.isSidebarVisible {
                TerminalTabSidebarView(
                    controller: controller,
                    layoutState: layoutState,
                    statusStore: statusStore,
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                )
                .frame(width: presentedSidebarWidth)
                VerticalTabSidebarDivider(
                    controller: controller,
                    layoutState: layoutState,
                    color: controller.sidebarDividerColor,
                    background: backgroundColor.opacity(backgroundOpacity)
                )
            }
            content
        }
    }

    private var presentedSidebarWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }
}

struct VerticalTabSidebarDivider: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    let color: Color
    var background: Color = .clear

    var body: some View {
        ZStack {
            TerminalSidebarDividerLine(color: color)
            SidebarResizeInteraction(
                currentWidth: { layoutState.sidebarWidth },
                resize: controller.updateSidebarWidth,
                direction: .leading
            )
        }
        .frame(width: TerminalShellStyle.resizeHitWidth)
        .background(background)
        .accessibilityLabel("Resize Tabs Sidebar")
    }
}

struct SidebarResizeInteraction: NSViewRepresentable {
    enum Direction {
        case leading
        case trailing
    }

    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void
    let direction: Direction

    init(
        currentWidth: @escaping () -> CGFloat,
        resize: @escaping (CGFloat, Bool) -> Void,
        direction: Direction = .leading
    ) {
        self.currentWidth = currentWidth
        self.resize = resize
        self.direction = direction
    }

    func makeNSView(context: Context) -> DragView {
        DragView(currentWidth: currentWidth, resize: resize, direction: direction)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.currentWidth = currentWidth
        view.resize = resize
        view.direction = direction
        view.window?.invalidateCursorRects(for: view)
    }

    final class DragView: NSView {
        var currentWidth: () -> CGFloat
        var resize: (CGFloat, Bool) -> Void
        var direction: Direction
        private var startWidth: CGFloat = 0
        private var startX: CGFloat = 0

        init(
            currentWidth: @escaping () -> CGFloat,
            resize: @escaping (CGFloat, Bool) -> Void,
            direction: Direction = .leading
        ) {
            self.currentWidth = currentWidth
            self.resize = resize
            self.direction = direction
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startWidth = currentWidth()
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            resize(proposedWidth(for: event), false)
        }

        override func mouseUp(with event: NSEvent) {
            resize(proposedWidth(for: event), true)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        private func proposedWidth(for event: NSEvent) -> CGFloat {
            let delta = event.locationInWindow.x - startX
            switch direction {
            case .leading: return startWidth + delta
            case .trailing: return startWidth - delta
            }
        }
    }
}

typealias VerticalTabResizeInteraction = SidebarResizeInteraction

enum SidebarToolbarStyle {
    static let iconSize: CGFloat = 16
    static let iconFontSize: CGFloat = 12
    static let controlHeight: CGFloat = 24
    static let iconControlWidth: CGFloat = 24
    static let cornerRadius: CGFloat = 4
    static let itemSpacing: CGFloat = 4
    static let labelFontSize: CGFloat = 11.5
    static let labelWeight = Font.Weight.medium
    static let iconHorizontalPadding: CGFloat = 4
    static let horizontalLabelPadding: CGFloat = 8
    static let hoverOpacity = 0.06
    static let disabledOpacity = 0.45
}

struct SidebarToolbarButton: View {
    let systemName: String
    let title: String?
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: SidebarToolbarStyle.iconFontSize))
                    .frame(
                        width: SidebarToolbarStyle.iconSize,
                        height: SidebarToolbarStyle.iconSize
                    )
                if let title {
                    Text(title)
                        .font(.system(
                            size: SidebarToolbarStyle.labelFontSize,
                            weight: SidebarToolbarStyle.labelWeight
                        ))
                        .lineLimit(1)
                }
            }
            .padding(
                .horizontal,
                title == nil
                    ? SidebarToolbarStyle.iconHorizontalPadding
                    : SidebarToolbarStyle.horizontalLabelPadding
            )
            .frame(
                minWidth: SidebarToolbarStyle.iconControlWidth,
                minHeight: SidebarToolbarStyle.controlHeight
            )
            .background(
                RoundedRectangle(cornerRadius: SidebarToolbarStyle.cornerRadius)
                    .fill(Color.primary.opacity(
                        hovered ? SidebarToolbarStyle.hoverOpacity : 0
                    ))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SidebarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        SidebarToolbarButton(
            systemName: systemName,
            title: nil,
            help: help,
            action: action
        )
    }
}

private struct VerticalTabRow: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var surface: Ghostty.SurfaceView
    let presentation: GhosttyTabPresentation
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    let hoverChanged: (Bool) -> Void

    private var livePresentation: GhosttyTabPresentation {
        let session = controller.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface.pwd,
            terminalTitle: surface.title
        )
        return .init(
            title: controller.titleOverride ?? session.presentationTitle,
            shortcut: presentation.shortcut,
            icon: presentation.icon,
            activity: presentation.activity,
            selected: presentation.selected,
            hovered: presentation.hovered
        )
    }

    var body: some View {
        let presentation = livePresentation
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: GhosttyTabStyle.contentSpacing) {
                    GhosttyTabIconView(
                        icon: presentation.icon,
                        color: GhosttyTabStyle.iconColor(
                            selected: presentation.selected,
                            hovered: presentation.hovered
                        )
                    )

                    Text(presentation.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let activity = presentation.activity, activity.state != .idle {
                TabActivityIndicator(activity: activity)
            }

            if presentation.hovered && canClose {
                SidebarIconButton(
                    systemName: "xmark",
                    help: "Close Tab",
                    action: close
                )
                .scaleEffect(0.8)
            } else if let shortcut = presentation.shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: GhosttyTabStyle.shortcutFontSize))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            } else {
                Color.clear.frame(width: 28, height: 1)
            }
        }
        .padding(.horizontal, GhosttyTabStyle.horizontalPadding)
        .frame(height: OhMyGhosttySettings.shared.tabRowDensity.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: GhosttyTabStyle.cornerRadius)
                .fill(Color.primary.opacity(GhosttyTabStyle.backgroundOpacity(
                    selected: presentation.selected,
                    hovered: presentation.hovered
                )))
        )
        .onHover(perform: hoverChanged)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
    }
}

private struct TabActivityIndicator: View {
    let activity: TabActivity

    var body: some View {
        Group {
            if activity.state == .working {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 12, height: 12)
        .help(activity.message ?? activity.label ?? activity.state.rawValue)
        .accessibilityLabel(activity.label ?? activity.state.rawValue)
    }

    private var systemImage: String {
        switch activity.state {
        case .idle: "circle"
        case .working: "circle"
        case .done: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch activity.state {
        case .idle, .working: .secondary
        case .done: .green
        case .needsAttention: .orange
        case .error: .red
        }
    }
}

private struct GhosttyTabIconView: View {
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let icon: GhosttyTabIcon
    let color: Color

    var body: some View {
        Group {
            switch icon {
            case .systemSymbol(let name):
                Image(systemName: name)
            case .asset(let name):
                Image(name)
            case .image(let image):
                Image(nsImage: image)
            }
        }
        .foregroundStyle(color)
        .frame(width: settings.tabIconSize, height: settings.tabIconSize)
    }
}

struct VerticalTabTitleResolver {
    static func resolve(
        explicitTitle: String?,
        terminalTitle: String,
        workingDirectory: String?,
        isGitRoot: (String) -> Bool = defaultIsGitRoot
    ) -> String {
        if let explicit = normalized(explicitTitle) {
            return explicit
        }

        if let workingDirectory = normalized(workingDirectory) {
            if let project = gitProjectName(from: workingDirectory, isGitRoot: isGitRoot) {
                return project
            }
            let basename = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !basename.isEmpty { return basename }
        }

        if let terminalTitle = normalized(terminalTitle) {
            if terminalTitle.contains("/") {
                let basename = URL(fileURLWithPath: terminalTitle).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return terminalTitle
        }

        return "Terminal"
    }

    private static func gitProjectName(
        from workingDirectory: String,
        isGitRoot: (String) -> Bool
    ) -> String? {
        var url = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        while url.path != "/" {
            if isGitRoot(url.path) {
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func defaultIsGitRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path
        )
    }
}
