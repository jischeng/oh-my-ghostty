import AppKit
import SwiftUI

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
                    color: Color.primary.opacity(0.10)
                )
            }

            content

            if layoutState.isInspectorVisible && !inspectorRegistry.isEmpty {
                RightInspectorDivider(
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
                .frame(width: presentedInspectorWidth)
            }
        }
    }

    private var presentedSidebarWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.sidebarWidth
            : layoutState.committedSidebarWidth
    }

    private var presentedInspectorWidth: CGFloat {
        controller.selectedTabID == ObjectIdentifier(controller)
            ? layoutState.inspectorWidth
            : layoutState.committedInspectorWidth
    }
}

struct RightInspectorHost: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var layoutState: VerticalTabWindowLayoutState
    @ObservedObject var registry: InspectorRegistry
    let backgroundColor: Color
    let backgroundOpacity: Double

    private var context: InspectorPaneContext {
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        return .init(
            tabID: controller.tabSessionID,
            surfaceID: surface?.id,
            title: controller.titleOverride ?? surface?.title ?? "Terminal",
            workingDirectory: surface?.pwd
        )
    }

    private var selectedPaneID: String? {
        let paneID = layoutState.selectedInspectorPaneID
        if let paneID, registry.descriptor(id: paneID) != nil { return paneID }
        return registry.entries.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let paneID = selectedPaneID,
               let content = registry.content(for: paneID, context: context) {
                InspectorPaneContentView(content: content)
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
        .onDisappear {
            registry.presentationDidChange(to: nil, context: context)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if registry.entries.count == 1, let descriptor = registry.entries.first?.descriptor {
                Label(descriptor.title, systemImage: descriptor.systemImage)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Picker("Pane", selection: Binding(
                    get: { selectedPaneID },
                    set: { layoutState.selectInspectorPane($0) }
                )) {
                    ForEach(registry.entries) { entry in
                        Label(
                            entry.descriptor.title,
                            systemImage: entry.descriptor.systemImage
                        )
                        .tag(Optional(entry.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Spacer(minLength: 4)
            Button {
                layoutState.setInspectorVisible(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide Inspector")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func reconcileSelection() {
        if selectedPaneID != layoutState.selectedInspectorPaneID {
            layoutState.selectInspectorPane(selectedPaneID)
        }
    }
}

private struct InspectorPaneContentView: View {
    let content: InspectorPaneContent

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
        }
    }
}

private struct RightInspectorDivider: View {
    let currentWidth: () -> CGFloat
    let resize: (CGFloat, Bool) -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
            RightInspectorResizeInteraction(
                currentWidth: currentWidth,
                resize: resize
            )
        }
        .frame(width: 8)
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
