import AppKit
import Combine
import SwiftUI

enum TerminalShellStyle {
    static let resizeHitWidth: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let minimumTerminalWidth: CGFloat = 320
    static let resizeOverlap = resizeHitWidth - dividerWidth

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
    var defersTerminalResize: Bool = true
    /// OMG: hover-or-drag state from the AppKit tracking area. It flips only on
    /// enter/exit/down/up, so the line never flickers while the mouse moves.
    @State private var isActive = false

    /// Theme-consistent highlight; OMG uses the accent for selection chrome.
    static let activeColor = Color.accentColor

    private var lineColor: Color { isActive ? Self.activeColor : color }

    @ViewBuilder
    var body: some View {
        switch edge {
        case .leading:
            ZStack(alignment: .leading) {
                TerminalSidebarDividerLine(color: lineColor)
                interaction(direction: .trailing)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.trailing, -TerminalShellStyle.resizeOverlap)

        case .trailing:
            ZStack(alignment: .trailing) {
                TerminalSidebarDividerLine(color: lineColor)
                interaction(direction: .leading)
            }
            .frame(width: TerminalShellStyle.resizeHitWidth)
            .padding(.leading, -TerminalShellStyle.resizeOverlap)

        case .top:
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(lineColor)
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
            direction: direction,
            defersTerminalResize: defersTerminalResize,
            onActiveChange: { isActive = $0 }
        )
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
}

final class InspectorTitlebarPresentation: ObservableObject {
    @Published private(set) var width = TerminalTitlebarMetrics.inspectorCollapsedWidth
    @Published private(set) var isVisible = false
    @Published var navigationInPane = false

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
        guard styleMask.contains(.titled) else { return }
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
        inspectorTitlebarPresentation.navigationInPane = controller.tabLayout == .horizontal
        let state = controller.tabLayoutState
        inspectorTitlebarPresentation.setVisible(false)
        inspectorTitlebarPresentation.setWidth(
            TerminalTitlebarMetrics.inspectorCollapsedWidth
        )
        let inspectorWidths = state.$inspectorWidth
            .merge(with: state.inspectorWidthChanges)
            .removeDuplicates()
        let layoutChanges = Publishers.CombineLatest3(
            state.$isInspectorVisible,
            inspectorWidths,
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
        .sink { [weak self, weak controller, weak state] layout, _ in
            guard let self, let controller else { return }
            let (isVisible, publishedWidth, sidebarWidth) = layout
            let inspectorWidth = state?.effectiveInspectorWidth ?? publishedWidth
            let totalWidth = self.contentLayoutRect.width
            let leadingWidth = controller.supportsSidebar
                ? sidebarWidth + TerminalShellStyle.dividerWidth
                : 0
            let presentedWidth = TerminalShellStyle.presentedInspectorWidth(
                preferred: inspectorWidth,
                totalWidth: totalWidth,
                leadingWidth: leadingWidth
            )
            let targetWidth = isVisible && controller.supportsSidebar
                ? presentedWidth
                : TerminalTitlebarMetrics.inspectorCollapsedWidth
            // Resize the native accessory and its controls in the same turn
            // as the pane. No delayed collapse or separate titlebar animation.
            self.applyInspectorAccessoryWidth(targetWidth, controller: controller)
            self.inspectorTitlebarPresentation.setVisible(isVisible)
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
        let descriptors = inspectorVisible && !presentation.navigationInPane
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
            if inspectorVisible && !presentation.navigationInPane {
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
            } else {
                Spacer(minLength: 0)
            }

            TerminalTitlebarIconButton(
                systemName: "sidebar.right",
                help: inspectorVisible ? "Hide Inspector · ⌘⇧B" : "Show Inspector · ⌘⇧B",
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
        .transaction { $0.animation = nil }
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
    let statusStore: TabActivityStore
    @ObservedObject var inspectorRegistry: InspectorRegistry
    let showsTabSidebar: Bool
    let backgroundColor: Color
    /// Effective chrome background (color with effective opacity applied).
    let chromeBackground: Color
    let content: Content

    init(
        controller: TerminalController,
        layoutState: VerticalTabWindowLayoutState,
        statusStore: TabActivityStore,
        inspectorRegistry: InspectorRegistry,
        showsTabSidebar: Bool,
        backgroundColor: Color,
        chromeBackground: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.layoutState = layoutState
        self.statusStore = statusStore
        self.inspectorRegistry = inspectorRegistry
        self.showsTabSidebar = showsTabSidebar
        self.backgroundColor = backgroundColor
        self.chromeBackground = chromeBackground
        self.content = content()
    }

    var body: some View {
        let leftVisible = showsTabSidebar && layoutState.isSidebarVisible
        let rightVisible = layoutState.isInspectorVisible && !inspectorRegistry.isEmpty
        NativeTerminalShell(
            leadingWidth: presentedSidebarWidth + TerminalShellStyle.dividerWidth,
            trailingWidth: preferredInspectorWidth,
            layoutState: layoutState,
            tracksLiveInspectorWidth: isSelectedTab,
            leadingVisible: leftVisible,
            trailingVisible: rightVisible,
            chromeBackground: chromeBackground,
            leading: AnyView(HStack(spacing: 0) {
                SharedTerminalTabSidebar(
                    controller: controller, layoutState: layoutState,
                    statusStore: statusStore, backgroundColor: backgroundColor
                )
                VerticalTabSidebarDivider(
                    controller: controller, layoutState: layoutState,
                    color: controller.sidebarDividerColor, background: .clear
                )
            }),
            center: AnyView(AgentQuickInputDock(
                controller: controller, model: controller.quickInputModel
            ) {
                VStack(spacing: 0) {
                    if !showsTabSidebar && !controller.horizontalWorkspaceInTitlebar {
                        HStack {
                            TerminalWorkspaceButton(controller: controller)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(chromeBackground)
                    }
                    SSHAgentHookOnboardingBanner(controller: controller)
                    content
                }
            }),
            trailing: AnyView(HStack(spacing: 0) {
                RightInspectorResizeHandle(
                    color: controller.sidebarDividerColor, background: .clear,
                    currentWidth: { layoutState.effectiveInspectorWidth },
                    resize: controller.updateInspectorWidth
                )
                .zIndex(10)
                RightInspectorHost(
                    controller: controller, layoutState: layoutState,
                    registry: inspectorRegistry, isPresented: rightVisible,
                    backgroundColor: backgroundColor
                )
            })
        )
    }

    private var isSelectedTab: Bool {
        controller.selectedTabID == ObjectIdentifier(controller)
    }

    private var presentedSidebarWidth: CGFloat {
        isSelectedTab
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }

    private var preferredInspectorWidth: CGFloat {
        isSelectedTab
            ? layoutState.effectiveInspectorWidth
            : layoutState.committedInspectorWidth
    }
}

/// A SwiftUI adapter only; observation, pane caching and provider presentation
/// belong to the native controller rather than SwiftUI appearance callbacks.
struct RightInspectorHost: NSViewControllerRepresentable {
    let controller: TerminalController
    let layoutState: VerticalTabWindowLayoutState
    let registry: InspectorRegistry
    var isPresented = true
    let backgroundColor: Color

    func makeNSViewController(context: Context) -> InspectorHostController {
        InspectorHostController(controller: controller, layoutState: layoutState, registry: registry)
    }

    func updateNSViewController(_ host: InspectorHostController, context: Context) {
        host.configure(isPresented: isPresented, backgroundColor: backgroundColor,
                       environment: context.environment)
    }

    static func dismantleNSViewController(_ host: InspectorHostController, coordinator: ()) {
        host.stop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: InspectorHostController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct InspectorPaneContentView: View {
    let content: InspectorPaneContent
    let paneID: String
    let context: InspectorPaneContext
    let dividerColor: Color
    let registry: InspectorRegistry

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

        case .info(let info):
            InspectorInfoView(
                info: info,
                directory: InfoWorkingDirectory.resolve(context),
                dividerColor: dividerColor,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )
        case .agentHistory(let history):
            InspectorAgentHistoryView(
                history: history,
                currentDirectory: context.workingDirectory,
                perform: { kind in
                    registry.performAction(
                        paneID: paneID,
                        action: .init(context: context, kind: kind)
                    )
                }
            )
        case .git(let gitContent):
            InspectorGitView(
                content: gitContent,
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
