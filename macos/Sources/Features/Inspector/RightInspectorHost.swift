import AppKit
import Combine
import SwiftUI

enum TerminalShellStyle {
    static let dividerColor = Color.primary.opacity(0.18)
    static let resizeHitWidth: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let minimumTerminalWidth: CGFloat = 320

    static func presentedInspectorWidth(
        preferred: CGFloat,
        totalWidth: CGFloat,
        leadingWidth: CGFloat
    ) -> CGFloat {
        let maximum = max(
            RightInspectorMetrics.minimumWidth,
            totalWidth - leadingWidth - minimumTerminalWidth - resizeHitWidth
        )
        return min(preferred, maximum)
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
        let bucketedWidth = floor(max(availableWidth, 0) / 12) * 12
        let horizontalPadding: CGFloat = 18
        let toggleWidth: CGFloat = 28
        let overflowWidth: CGFloat = 28
        let spacing: CGFloat = 4
        let usable = max(0, bucketedWidth - horizontalPadding)

        func itemWidth(_ descriptor: InspectorPaneDescriptor) -> CGFloat {
            guard descriptor.id == selectedID else { return 28 }
            return max(52, 34 + CGFloat(descriptor.title.count) * 6.5)
        }

        let allItemsWidth = descriptors.reduce(toggleWidth) { result, descriptor in
            result + spacing + itemWidth(descriptor)
        }
        if allItemsWidth <= usable {
            return .init(
                visibleIDs: descriptors.map(\.id),
                overflowIDs: []
            )
        }

        var visible: [String] = []
        var used = toggleWidth + overflowWidth + spacing * 2
        for descriptor in descriptors {
            let candidate = itemWidth(descriptor) + (visible.isEmpty ? 0 : spacing)
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
        inspectorToggleAccessory.view = AlignedTitlebarControlsView(
            width: 190,
            rootView: InspectorTitlebarControls(
                layoutState: controller.tabLayoutState,
                registry: registry,
                toggleInspector: { [weak controller] in controller?.toggleInspectorPane() }
            )
        )
        if !installed {
            addTitlebarAccessoryViewController(inspectorToggleAccessory)
        }
        inspectorToggleAccessory.view.translatesAutoresizingMaskIntoConstraints = false
        inspectorToggleWidthConstraint?.isActive = false
        let widthConstraint = inspectorToggleAccessory.view.widthAnchor.constraint(
            equalToConstant: 190
        )
        inspectorToggleWidthConstraint = widthConstraint
        widthConstraint.isActive = true
        let stateChanges = controller.tabLayoutState.objectWillChange.map { _ in () }
        let resizeChanges = NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification,
            object: self
        ).map { _ in () }
        inspectorToggleCancellable = Publishers.Merge(stateChanges, resizeChanges)
            .prepend(())
            .sink { [weak self, weak controller] _ in
                DispatchQueue.main.async {
                    guard let self, let controller else { return }
                    let state = controller.tabLayoutState
                    let totalWidth = self.contentLayoutRect.width
                    let leadingWidth = controller.supportsSidebar && state.isSidebarVisible
                        ? state.sidebarWidth + TerminalShellStyle.resizeHitWidth
                        : 0
                    let presentedWidth = TerminalShellStyle.presentedInspectorWidth(
                        preferred: state.inspectorWidth,
                        totalWidth: totalWidth,
                        leadingWidth: leadingWidth
                    )
                    self.inspectorToggleWidthConstraint?.constant = state.isInspectorVisible
                        ? presentedWidth
                        : 120
                }
            }

        // AppKit may reset an already-visible transparent window to opaque when
        // adding a trailing titlebar accessory after the initial appearance pass.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self,
                  let surface = controller?.focusedSurface ?? controller?.surfaceTree.first else {
                return
            }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    var inspectorToggleIsInstalled: Bool {
        titlebarAccessoryViewControllers.contains(inspectorToggleAccessory)
    }

    var inspectorControlsCenterY: CGFloat? {
        (inspectorToggleAccessory.view as? TitlebarControlsCentering)?.contentCenterYInWindow
    }
}

private struct InspectorTitlebarControls: View {
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
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
        GeometryReader { geometry in
            let descriptors = registry.entries.map(\.descriptor)
            let layout = InspectorPluginBarLayout.resolve(
                descriptors: descriptors,
                selectedID: selectedPaneID,
                availableWidth: geometry.size.width
            )
            HStack(spacing: 4) {
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
                Spacer(minLength: 0)
                SidebarIconButton(
                    systemName: "sidebar.right",
                    help: layoutState.isInspectorVisible ? "Hide Inspector" : "Show Inspector",
                    action: toggleInspector
                )
                .disabled(registry.isEmpty)
                .opacity(registry.isEmpty ? 0.45 : 1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
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
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            Group {
                if selected {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                        .padding(.horizontal, 8)
                } else {
                    Image(systemName: descriptor.systemImage)
                        .frame(width: 24)
                }
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(hovered ? 0.06 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(descriptor.title)
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
            HStack(spacing: 0) {
                if showsTabSidebar && layoutState.isSidebarVisible {
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
                        color: TerminalShellStyle.dividerColor,
                        background: backgroundColor.opacity(backgroundOpacity)
                    )
                }

                content

                if layoutState.isInspectorVisible && !inspectorRegistry.isEmpty {
                    RightInspectorResizeHandle(
                        background: backgroundColor.opacity(backgroundOpacity),
                        currentWidth: { layoutState.inspectorWidth },
                        resize: controller.updateInspectorWidth
                    )
                    RightInspectorHost(
                        controller: controller,
                        layoutState: layoutState,
                        registry: inspectorRegistry,
                        backgroundColor: backgroundColor,
                        backgroundOpacity: backgroundOpacity
                    )
                    .frame(width: presentedInspectorWidth(totalWidth: geometry.size.width))
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
        let leadingWidth = showsTabSidebar && layoutState.isSidebarVisible
            ? presentedSidebarWidth + TerminalShellStyle.resizeHitWidth
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
        return .init(
            tabID: controller.tabSessionID,
            surfaceID: surface?.id,
            title: controller.titleOverride ?? surface?.title ?? "Terminal",
            workingDirectory: surface?.pwd
        )
    }

    private var contextChanges: AnyPublisher<Void, Never> {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else {
            return Empty().eraseToAnyPublisher()
        }
        return Publishers.CombineLatest(surface.$pwd, surface.$title)
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
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
            contextRevision &+= 1
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
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovered ? 0.06 : 0))
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

private struct InspectorFileTreeView: View {
    let tree: InspectorFileTree
    let perform: (InspectorPaneActionKind) -> Void
    @State private var selectedNodeID: String?

    var body: some View {
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
            .padding(.vertical, 4)
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
                .padding(.leading, CGFloat(depth) * 14 + 8)
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
        .padding(.horizontal, 4)
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
    let background: Color
    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void

    var body: some View {
        RightInspectorResizeInteraction(
            currentWidth: currentWidth,
            resize: resize
        )
        .frame(width: TerminalShellStyle.resizeHitWidth)
        .background(background)
        .accessibilityLabel("Resize Inspector")
    }
}

private struct RightInspectorResizeInteraction: NSViewRepresentable {
    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        DragView(currentWidth: currentWidth, resize: resize)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.currentWidth = currentWidth
        view.resize = resize
    }

    final class DragView: NSView {
        var currentWidth: () -> CGFloat
        var resize: (CGFloat, Bool) -> Void
        private var startWidth: CGFloat = 0
        private var startX: CGFloat = 0

        init(
            currentWidth: @escaping () -> CGFloat,
            resize: @escaping (CGFloat, Bool) -> Void
        ) {
            self.currentWidth = currentWidth
            self.resize = resize
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            startWidth = currentWidth()
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            resize(startWidth - event.locationInWindow.x + startX, false)
        }

        override func mouseUp(with event: NSEvent) {
            resize(startWidth - event.locationInWindow.x + startX, true)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}
