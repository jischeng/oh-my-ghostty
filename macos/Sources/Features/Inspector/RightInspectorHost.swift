import AppKit
import Combine
import SwiftUI

enum TerminalShellStyle {
    static let resizeHitWidth: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let minimumTerminalWidth: CGFloat = 320
    static let resizeOverlap = resizeHitWidth - dividerWidth
    static let sidebarTransitionDuration = 0.18
    static let sidebarTransitionAnimation = Animation.easeOut(
        duration: sidebarTransitionDuration
    )

    static func presentedInspectorWidth(
        preferred: CGFloat,
        totalWidth: CGFloat,
        leadingWidth: CGFloat
    ) -> CGFloat {
        let maximum = max(
            RightInspectorMetrics.minimumWidth,
            totalWidth - leadingWidth - minimumTerminalWidth - dividerWidth
        )
        return min(preferred, maximum)
    }
}

enum InspectorContentMetrics {
    static let leadingInset: CGFloat = 12
    static let treeOuterInset: CGFloat = 4
    static let treeRowLeadingInset = leadingInset - treeOuterInset

    static func titlebarLeadingInset(firstItemHasTitle: Bool) -> CGFloat {
        let buttonInset = firstItemHasTitle
            ? TerminalTitlebarControlStyle.horizontalLabelPadding
            : TerminalTitlebarControlStyle.iconHorizontalPadding
        return max(0, leadingInset - buttonInset)
    }
}

struct TerminalSidebarDividerLine: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: TerminalShellStyle.dividerWidth)
            .frame(maxHeight: .infinity)
    }
}

struct TerminalResizeBoundary: View {
    enum Edge {
        case leading
        case trailing
        case top
    }

    let edge: Edge
    let color: Color
    let currentExtent: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void
    let accessibilityLabel: String

    @ViewBuilder
    var body: some View {
        switch edge {
        case .leading:
            ZStack(alignment: .leading) {
                TerminalSidebarDividerLine(color: color)
                interaction(direction: .trailing)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.trailing, -TerminalShellStyle.resizeOverlap)

        case .trailing:
            ZStack(alignment: .trailing) {
                TerminalSidebarDividerLine(color: color)
                interaction(direction: .leading)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.leading, -TerminalShellStyle.resizeOverlap)

        case .top:
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(color)
                    .frame(height: TerminalShellStyle.dividerWidth)
                    .frame(maxWidth: .infinity)
                interaction(direction: .top)
            }
            .frame(height: TerminalShellStyle.resizeHitWidth)
            .padding(.bottom, -TerminalShellStyle.resizeOverlap)
        }
    }

    private func interaction(
        direction: SidebarResizeInteraction.Direction
    ) -> some View {
        SidebarResizeInteraction(
            currentWidth: currentExtent,
            resize: resize,
            direction: direction
        )
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TerminalSidebarTransitionContainer<Content: View>: View {
    enum Edge {
        case left
        case right

        var alignment: Alignment { self == .left ? .leading : .trailing }
        func hiddenOffset(for width: CGFloat) -> CGFloat {
            self == .left ? -width : width
        }
    }

    let isVisible: Bool
    let width: CGFloat
    let edge: Edge
    let animationsEnabled: Bool
    let background: Color
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var occupiesSpace: Bool
    @State private var revealProgress: CGFloat
    @State private var transitionTask: Task<Void, Never>?

    init(
        isVisible: Bool,
        width: CGFloat,
        edge: Edge,
        animationsEnabled: Bool,
        background: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.isVisible = isVisible
        self.width = width
        self.edge = edge
        self.animationsEnabled = animationsEnabled
        self.background = background
        self.content = content()
        self._occupiesSpace = State(initialValue: isVisible)
        self._revealProgress = State(initialValue: isVisible ? 1 : 0)
    }

    var body: some View {
        ZStack(alignment: edge.alignment) {
            if occupiesSpace {
                content
                    .frame(width: width, alignment: edge.alignment)
                    .offset(
                        x: (1 - revealProgress) * edge.hiddenOffset(for: width)
                    )
                    .allowsHitTesting(revealProgress == 1)
                    .accessibilityHidden(revealProgress != 1)
            }
        }
        .frame(
            width: occupiesSpace ? width : 0,
            alignment: edge.alignment
        )
        .background(background)
        .clipped()
        .onAppear { synchronizeImmediately() }
        .onChange(of: isVisible) { visible in transition(to: visible) }
        .onChange(of: reduceMotion) { _ in synchronizeImmediately() }
        .onChange(of: animationsEnabled) { _ in synchronizeImmediately() }
        .onDisappear { transitionTask?.cancel() }
    }

    private func transition(to visible: Bool) {
        transitionTask?.cancel()
        transitionTask = nil
        guard !reduceMotion, animationsEnabled else {
            occupiesSpace = visible
            revealProgress = visible ? 1 : 0
            return
        }

        if visible {
            let needsMount = !occupiesSpace
            occupiesSpace = true
            if needsMount { revealProgress = 0 }
            transitionTask = Task { @MainActor in
                if needsMount { await Task.yield() }
                guard !Task.isCancelled else { return }
                withAnimation(TerminalShellStyle.sidebarTransitionAnimation) {
                    revealProgress = 1
                }
            }
        } else {
            withAnimation(TerminalShellStyle.sidebarTransitionAnimation) {
                revealProgress = 0
            }
            transitionTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(
                    TerminalShellStyle.sidebarTransitionDuration
                ))
                guard !Task.isCancelled else { return }
                occupiesSpace = false
            }
        }
    }

    private func synchronizeImmediately() {
        transitionTask?.cancel()
        transitionTask = nil
        occupiesSpace = isVisible
        revealProgress = isVisible ? 1 : 0
    }
}

final class InspectorTitlebarPresentation: ObservableObject {
    @Published private(set) var width = TerminalTitlebarMetrics.inspectorCollapsedWidth
    @Published private(set) var isVisible = false

    func setWidth(_ width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}

enum InspectorTitlebarLayout {
    static func pluginWidth(totalWidth: CGFloat) -> CGFloat {
        max(0, totalWidth - TerminalTitlebarMetrics.inspectorCollapsedWidth)
    }
}

struct InspectorPluginBarLayout: Equatable {
    let visibleIDs: [String]
    let overflowIDs: [String]

    static func resolve(
        descriptors: [InspectorPaneDescriptor],
        selectedID: String?,
        availableWidth: CGFloat
    ) -> Self {
        let bucket = TerminalTitlebarMetrics.inspectorOverflowBucket
        let bucketedWidth = floor(max(availableWidth, 0) / bucket) * bucket
        let firstItemHasTitle = descriptors.first?.id == selectedID
        let leadingInset = InspectorContentMetrics.titlebarLeadingInset(
            firstItemHasTitle: firstItemHasTitle
        )
        let overflowWidth = TerminalTitlebarControlStyle.controlWidth(title: nil)
        let spacing = TerminalTitlebarControlStyle.itemSpacing
        let usable = max(0, bucketedWidth - leadingInset)

        func itemWidth(_ descriptor: InspectorPaneDescriptor) -> CGFloat {
            TerminalTitlebarControlStyle.controlWidth(
                title: descriptor.id == selectedID ? descriptor.title : nil
            )
        }

        let allItemsWidth = descriptors.enumerated().reduce(0) { result, item in
            result + (item.offset == 0 ? 0 : spacing) + itemWidth(item.element)
        }
        if allItemsWidth <= usable {
            return .init(
                visibleIDs: descriptors.map(\.id),
                overflowIDs: []
            )
        }

        var visible: [String] = []
        var used = overflowWidth
        for descriptor in descriptors {
            let candidate = itemWidth(descriptor) + spacing
            guard used + candidate <= usable else { break }
            visible.append(descriptor.id)
            used += candidate
        }
        return .init(
            visibleIDs: visible,
            overflowIDs: descriptors.map(\.id).filter { !visible.contains($0) }
        )
    }
}

extension TerminalWindow {
    func installInspectorToggle(
        controller: TerminalController,
        registry: InspectorRegistry
    ) {
        let installed = titlebarAccessoryViewControllers.contains(inspectorToggleAccessory)
        inspectorToggleAccessory.layoutAttribute = .right
        inspectorToggleAccessory.view = AlignedTerminalTitlebarControlsView(
            minimumWidth: TerminalTitlebarMetrics.inspectorCollapsedWidth,
            rootView: InspectorTitlebarControls(
                layoutState: controller.tabLayoutState,
                presentation: inspectorTitlebarPresentation,
                registry: registry,
                toggleInspector: { [weak controller] in controller?.toggleInspectorPane() }
            )
        )
        inspectorToggleAccessory.view.translatesAutoresizingMaskIntoConstraints = false
        inspectorToggleWidthConstraint?.isActive = false
        let widthConstraint = inspectorToggleAccessory.view.widthAnchor.constraint(
            equalToConstant: TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        inspectorToggleWidthConstraint = widthConstraint
        widthConstraint.isActive = true
        if !installed {
            addTitlebarAccessoryViewController(inspectorToggleAccessory)
        }
        let state = controller.tabLayoutState
        inspectorTitlebarPresentation.setVisible(false)
        inspectorTitlebarPresentation.setWidth(
            TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        let layoutChanges = Publishers.CombineLatest3(
            state.$isInspectorVisible,
            state.$inspectorWidth,
            state.$sidebarWidth
        )
        let resizeChanges = NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification,
            object: self
        )
        .map { _ in () }
        .prepend(())
        inspectorToggleCancellable = Publishers.CombineLatest(
            layoutChanges,
            resizeChanges
        )
        .sink { [weak self, weak controller] layout, _ in
            guard let self, let controller else { return }
            let (isVisible, inspectorWidth, sidebarWidth) = layout
            let totalWidth = self.contentLayoutRect.width
            let leadingWidth = controller.supportsSidebar
                ? sidebarWidth + TerminalShellStyle.dividerWidth
                : 0
            let presentedWidth = TerminalShellStyle.presentedInspectorWidth(
                preferred: inspectorWidth,
                totalWidth: totalWidth,
                leadingWidth: leadingWidth
            )
            let targetWidth = isVisible
                ? presentedWidth
                : TerminalTitlebarMetrics.inspectorCollapsedWidth
            self.inspectorCollapseWorkItem?.cancel()
            self.inspectorCollapseWorkItem = nil
            if isVisible {
                // Expand the AppKit accessory before revealing Plugin controls.
                // The next-turn reveal then animates with the content pane rather
                // than appearing in the old collapsed frame first.
                self.applyInspectorAccessoryWidth(
                    targetWidth,
                    controller: controller
                )
                guard !self.inspectorTitlebarPresentation.isVisible else { return }
                let workItem = DispatchWorkItem { [weak self, weak controller] in
                    guard let self, let controller,
                          controller.tabLayoutState.isInspectorVisible else { return }
                    self.inspectorCollapseWorkItem = nil
                    self.inspectorTitlebarPresentation.setVisible(true)
                }
                self.inspectorCollapseWorkItem = workItem
                DispatchQueue.main.async(execute: workItem)
            } else {
                // Animate Plugin controls out with the pane, then contract the
                // accessory only after the shared transition duration.
                self.inspectorTitlebarPresentation.setVisible(false)
                let workItem = DispatchWorkItem { [weak self, weak controller] in
                    guard let self, let controller,
                          !controller.tabLayoutState.isInspectorVisible else { return }
                    self.inspectorCollapseWorkItem = nil
                    self.applyInspectorAccessoryWidth(
                        targetWidth,
                        controller: controller
                    )
                }
                self.inspectorCollapseWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + TerminalShellStyle.sidebarTransitionDuration,
                    execute: workItem
                )
            }
        }

        // AppKit may reset an already-visible transparent window to opaque when
        // adding or resizing a trailing titlebar accessory. Restore appearance
        // once the titlebar layout has settled rather than on every resize event.
        scheduleInspectorAppearanceSync(controller: controller)
    }

    private func applyInspectorAccessoryWidth(
        _ width: CGFloat,
        controller: TerminalController
    ) {
        let sizing = inspectorToggleAccessory.view as? TerminalTitlebarWidthSynchronizing
        guard inspectorToggleWidthConstraint?.constant != width ||
                sizing?.titlebarWidth != width else { return }
        inspectorToggleWidthConstraint?.constant = width
        inspectorTitlebarPresentation.setWidth(width)
        sizing?.setTitlebarWidth(width)
        inspectorToggleAccessory.view.needsLayout = true
        titlebarContainer?.needsLayout = true
        titlebarContainer?.layoutSubtreeIfNeeded()
        inspectorToggleAccessory.view.layoutSubtreeIfNeeded()
        scheduleInspectorAppearanceSync(controller: controller)
    }

    private func scheduleInspectorAppearanceSync(controller: TerminalController) {
        inspectorAppearanceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self,
                  let surface = controller?.focusedSurface ?? controller?.surfaceTree.first else {
                return
            }
            self.syncAppearance(surface.derivedConfig)
        }
        inspectorAppearanceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    var inspectorToggleIsInstalled: Bool {
        titlebarAccessoryViewControllers.contains(inspectorToggleAccessory)
    }

    var inspectorControlsCenterY: CGFloat? {
        (inspectorToggleAccessory.view as? TerminalTitlebarControlsCentering)?.contentCenterYInWindow
    }

    var inspectorControlsHeight: CGFloat? {
        guard inspectorToggleAccessory.view.window != nil else { return nil }
        return inspectorToggleAccessory.view.bounds.height
    }

    var inspectorControlsWidth: CGFloat? {
        guard inspectorToggleAccessory.view.window != nil else { return nil }
        return inspectorToggleAccessory.view.bounds.width
    }

}

private struct InspectorTitlebarControls: View {
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var presentation: InspectorTitlebarPresentation
    @ObservedObject var registry: InspectorRegistry
    let toggleInspector: () -> Void

    private var selectedPaneID: String? {
        if let selected = layoutState.selectedInspectorPaneID,
           registry.descriptor(id: selected) != nil {
            return selected
        }
        return registry.entries.first?.id
    }

    var body: some View {
        let inspectorVisible = presentation.isVisible
        let descriptors = inspectorVisible
            ? registry.entries.map(\.descriptor)
            : []
        let pluginWidth = InspectorTitlebarLayout.pluginWidth(
            totalWidth: presentation.width
        )
        let layout = InspectorPluginBarLayout.resolve(
            descriptors: descriptors,
            selectedID: selectedPaneID,
            availableWidth: pluginWidth
        )
        let titlebarLeadingInset = InspectorContentMetrics.titlebarLeadingInset(
            firstItemHasTitle: layout.visibleIDs.first == selectedPaneID
        )
        HStack(spacing: 0) {
            if inspectorVisible {
                HStack(spacing: TerminalTitlebarControlStyle.itemSpacing) {
                    ForEach(layout.visibleIDs, id: \.self) { id in
                        if let descriptor = registry.descriptor(id: id) {
                            InspectorTitlebarPaneButton(
                                descriptor: descriptor,
                                selected: selectedPaneID == id,
                                select: { select(id) }
                            )
                        }
                    }
                    if !layout.overflowIDs.isEmpty {
                        InspectorPluginOverflowMenu(
                            descriptors: layout.overflowIDs.compactMap {
                                registry.descriptor(id: $0)
                            },
                            selectedID: selectedPaneID,
                            select: select
                        )
                    }
                }
                .padding(.leading, titlebarLeadingInset)
                .frame(width: pluginWidth, alignment: .leading)
                .transition(.opacity.combined(with: .offset(x: 6, y: 0)))
            } else {
                Spacer(minLength: 0)
            }

            TerminalTitlebarIconButton(
                systemName: "sidebar.right",
                help: inspectorVisible ? "Hide Inspector" : "Show Inspector",
                action: toggleInspector
            )
            .frame(width: TerminalTitlebarMetrics.inspectorCollapsedWidth)
            .disabled(registry.isEmpty)
            .opacity(
                registry.isEmpty ? TerminalTitlebarControlStyle.disabledOpacity : 1
            )
        }
        .frame(width: presentation.width, alignment: .trailing)
        .frame(maxHeight: .infinity)
        .animation(
            TerminalShellStyle.sidebarTransitionAnimation,
            value: inspectorVisible
        )
    }

    private func select(_ paneID: String) {
        layoutState.selectInspectorPane(paneID)
        layoutState.setInspectorVisible(true)
    }
}

private struct InspectorTitlebarPaneButton: View {
    let descriptor: InspectorPaneDescriptor
    let selected: Bool
    let select: () -> Void

    var body: some View {
        TerminalTitlebarButton(
            systemName: descriptor.systemImage,
            title: selected ? descriptor.title : nil,
            help: descriptor.title,
            action: select
        )
        .accessibilityValue(selected ? "Selected" : "")
    }
}

struct TerminalShellLayoutContainer<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var statusStore: TabActivityStore
    @ObservedObject var inspectorRegistry: InspectorRegistry
    let showsTabSidebar: Bool
    let backgroundColor: Color
    let backgroundOpacity: Double
    let content: Content

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        inspectorRegistry: InspectorRegistry,
        showsTabSidebar: Bool,
        backgroundColor: Color,
        backgroundOpacity: Double,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.inspectorRegistry = inspectorRegistry
        self.showsTabSidebar = showsTabSidebar
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let selectedPresentation = controller.selectedTabID == ObjectIdentifier(controller)
            let leftVisible = showsTabSidebar && layoutState.isSidebarVisible
            let leftWidth = presentedSidebarWidth + TerminalShellStyle.dividerWidth
            let inspectorWidth = presentedInspectorWidth(totalWidth: geometry.size.width)
            let rightVisible = layoutState.isInspectorVisible && !inspectorRegistry.isEmpty
            let rightWidth = inspectorWidth + TerminalShellStyle.dividerWidth

            HStack(spacing: 0) {
                TerminalSidebarTransitionContainer(
                    isVisible: leftVisible,
                    width: leftWidth,
                    edge: .left,
                    animationsEnabled: selectedPresentation,
                    background: backgroundColor.opacity(backgroundOpacity)
                ) {
                    HStack(spacing: 0) {
                        TerminalTabSidebarView(
                            controller: controller,
                            layoutState: layoutState,
                            statusStore: statusStore,
                            backgroundColor: backgroundColor,
                            backgroundOpacity: 0
                        )
                        .frame(width: presentedSidebarWidth)
                        VerticalTabSidebarDivider(
                            controller: controller,
                            layoutState: layoutState,
                            color: controller.sidebarDividerColor,
                            background: .clear
                        )
                    }
                }

                AgentQuickInputDock(
                    controller: controller,
                    model: controller.quickInputModel,
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                ) {
                    content
                }

                TerminalSidebarTransitionContainer(
                    isVisible: rightVisible,
                    width: rightWidth,
                    edge: .right,
                    animationsEnabled: selectedPresentation,
                    background: backgroundColor.opacity(backgroundOpacity)
                ) {
                    HStack(spacing: 0) {
                        RightInspectorResizeHandle(
                            color: controller.sidebarDividerColor,
                            background: .clear,
                            currentWidth: { layoutState.inspectorWidth },
                            resize: controller.updateInspectorWidth
                        )
                        RightInspectorHost(
                            controller: controller,
                            layoutState: layoutState,
                            registry: inspectorRegistry,
                            backgroundColor: backgroundColor,
                            backgroundOpacity: 0
                        )
                        .frame(width: inspectorWidth)
                    }
                }
            }
        }
    }

    private var presentedSidebarWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }

    private func presentedInspectorWidth(totalWidth: CGFloat) -> CGFloat {
        let preferred = controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.inspectorWidth
            : layoutState.committedInspectorWidth
        let leadingWidth = showsTabSidebar
            ? presentedSidebarWidth + TerminalShellStyle.dividerWidth
            : 0
        return TerminalShellStyle.presentedInspectorWidth(
            preferred: preferred,
            totalWidth: totalWidth,
            leadingWidth: leadingWidth
        )
    }
}

struct RightInspectorHost: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var registry: InspectorRegistry
    let backgroundColor: Color
    let backgroundOpacity: Double
    @State private var contextRevision: UInt64 = 0

    private var context: InspectorPaneContext {
        _ = contextRevision
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        let session = controller.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface?.pwd,
            terminalTitle: surface?.title ?? "Terminal"
        )
        return .init(
            tabID: controller.tabSessionID,
            surfaceID: surface?.id,
            title: controller.titleOverride ?? session.presentationTitle,
            workingDirectory: session.workingDirectory,
            workspace: session.workspace,
            session: session
        )
    }

    private var contextChanges: AnyPublisher<Void, Never> {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else {
            return Empty().eraseToAnyPublisher()
        }
        let metadata = Publishers.CombineLatest(surface.$pwd, surface.$title)
            .dropFirst()
            .map { _ in () }
        let session = surface.$contextSignal
            .dropFirst()
            .map { _ in () }
        return Publishers.Merge(metadata, session).eraseToAnyPublisher()
    }

    private var selectedPaneID: String? {
        let paneID = layoutState.selectedInspectorPaneID
        if let paneID, registry.descriptor(id: paneID) != nil { return paneID }
        return registry.entries.first?.id
    }

    var body: some View {
        Group {
            if let paneID = selectedPaneID,
               let content = registry.content(for: paneID, context: context) {
                InspectorPaneContentView(
                    content: content,
                    paneID: paneID,
                    context: context,
                    registry: registry
                )
            }
        }
        .background(backgroundColor.opacity(backgroundOpacity))
        .onAppear {
            reconcileSelection()
            registry.presentationDidChange(to: selectedPaneID, context: context)
        }
        .onChange(of: registry.entries.map(\.id)) { _ in
            reconcileSelection()
            registry.presentationDidChange(to: selectedPaneID, context: context)
        }
        .onChange(of: layoutState.selectedInspectorPaneID) { _ in
            registry.presentationDidChange(to: selectedPaneID, context: context)
        }
        .onReceive(contextChanges) { _ in
            // @Published emits before its property storage is updated. Defer
            // one main-queue turn so the Inspector context reads the committed
            // Surface cwd/title, then notify the provider directly rather than
            // relying only on a SwiftUI body diff.
            DispatchQueue.main.async {
                contextRevision &+= 1
                registry.presentationDidChange(
                    to: selectedPaneID,
                    context: context
                )
            }
        }
        .onChange(of: context) { nextContext in
            registry.presentationDidChange(to: selectedPaneID, context: nextContext)
        }
        .onDisappear {
            registry.presentationDidChange(to: nil, context: context)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func reconcileSelection() {
        if selectedPaneID != layoutState.selectedInspectorPaneID {
            layoutState.selectInspectorPane(selectedPaneID)
        }
    }
}

private struct InspectorPaneContentView: View {
    let content: InspectorPaneContent
    let paneID: String
    let context: InspectorPaneContext
    @ObservedObject var registry: InspectorRegistry

    var body: some View {
        switch content {
        case .empty(let title, let message):
            VStack(spacing: 8) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fields(let fields):
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(fields) { field in
                        GridRow {
                            Text(field.label)
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .list(let items):
            List(items) { item in
                HStack(spacing: 8) {
                    if let systemImage = item.systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)

        case .fileTree(let tree):
            InspectorFileTreeView(
                tree: tree,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )
        }
    }
}

private struct InspectorPluginOverflowMenu: View {
    let descriptors: [InspectorPaneDescriptor]
    let selectedID: String?
    let select: (String) -> Void
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(descriptors) { descriptor in
                Toggle(isOn: Binding(
                    get: { selectedID == descriptor.id },
                    set: { enabled in if enabled { select(descriptor.id) } }
                )) {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
            }
        } label: {
            TerminalTitlebarControlLabel(
                systemName: "ellipsis",
                title: nil,
                hovered: hovered
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("More Inspector Plugins")
        .accessibilityLabel("More Inspector Plugins")
    }
}

struct InspectorPluginContextHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InspectorContentMetrics.leadingInset)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }
}

private struct InspectorFileTreeView: View {
    let tree: InspectorFileTree
    let perform: (InspectorPaneActionKind) -> Void
    @State private var selectedNodeID: String?

    var body: some View {
        VStack(spacing: 0) {
            InspectorPluginContextHeader(title: tree.rootName)
                .help(tree.rootPath)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.nodes) { node in
                        InspectorFileTreeNodeView(
                            node: node,
                            depth: 0,
                            selectedNodeID: $selectedNodeID,
                            perform: perform
                        )
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
        }
        .onChange(of: tree.rootPath) { _ in
            selectedNodeID = nil
        }
    }
}

private struct InspectorFileTreeNodeView: View {
    let node: InspectorFileNode
    let depth: Int
    @Binding var selectedNodeID: String?
    let perform: (InspectorPaneActionKind) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                selectedNodeID = node.id
                guard node.isDirectory else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    perform(.toggleNode(id: node.id, expanded: !node.isExpanded))
                }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if node.isDirectory {
                            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 10, height: 14)

                    InspectorFileIconView(icon: node.icon)
                    Text(node.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if node.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(
                    .leading,
                    CGFloat(depth) * 14 + InspectorContentMetrics.treeRowLeadingInset
                )
                .padding(.trailing, 8)
                .frame(height: 27)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(
                            selectedNodeID == node.id ? 0.12 : hovered ? 0.07 : 0
                        ))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }

            if node.isExpanded, let children = node.children {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        InspectorFileTreeNodeView(
                            node: child,
                            depth: depth + 1,
                            selectedNodeID: $selectedNodeID,
                            perform: perform
                        )
                    }
                }
                .transition(.opacity)
                .clipped()
            }
        }
        .padding(.horizontal, InspectorContentMetrics.treeOuterInset)
        .animation(.easeInOut(duration: 0.16), value: node.isExpanded)
        .animation(
            .easeInOut(duration: 0.16),
            value: node.children?.map(\.id) ?? []
        )
    }
}

private struct InspectorFileIconView: View {
    let icon: InspectorFileIcon

    var body: some View {
        Image(systemName: icon.systemImage)
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
    }

    private var color: Color {
        switch icon.tint {
        case .secondary: .secondary
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .yellow: .yellow
        case .purple: .purple
        case .red: .red
        }
    }
}

private struct RightInspectorResizeHandle: View {
    let color: Color
    let background: Color
    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void

    var body: some View {
        TerminalResizeBoundary(
            edge: .leading,
            color: color,
            currentExtent: currentWidth,
            resize: resize,
            accessibilityLabel: "Resize Inspector"
        )
        .background(background)
    }
}
