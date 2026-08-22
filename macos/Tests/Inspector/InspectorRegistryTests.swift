import Foundation
import Testing
@testable import Ghostty

@MainActor
struct InspectorRegistryTests {
    @Test func emptyRegistryDoesNotMutateWindowLayoutState() {
        let registry = InspectorRegistry()
        let state = VerticalTabWindowLayoutState(isSidebarVisible: false)

        state.setInspectorVisible(true)

        #expect(registry.isEmpty)
        #expect(state.isInspectorVisible)
        #expect(state.selectedInspectorPaneID == nil)
    }

    @Test func corePaneUsesTypedContentAndLifecycle() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(
            id: "core.session",
            source: .coreFeature("session")
        )
        var events: [InspectorPaneLifecycleEvent] = []
        try registry.registerCorePane(
            descriptor,
            content: { context in
                .fields([
                    .init(id: "title", label: "Title", value: context.title),
                ])
            },
            lifecycle: { events.append($0) }
        )
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Shell",
            workingDirectory: "/tmp"
        )

        #expect(registry.entries.map(\.id) == ["core.session"])
        #expect(registry.content(for: descriptor.id, context: context) == .fields([
            .init(id: "title", label: "Title", value: "Shell"),
        ]))

        registry.presentationDidChange(to: descriptor.id, context: context)
        registry.presentationDidChange(to: nil, context: context)
        #expect(events == [.appeared(context), .disappeared])
    }

    @Test func pluginPaneIsDataOnlyAndOwnerScoped() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(
            id: "plugin.agent.context",
            source: .plugin("agent")
        )
        try registry.registerPluginPane(descriptor)
        let content = InspectorPaneContent.list([
            .init(id: "task", title: "Running", subtitle: "Tests", systemImage: "bolt"),
        ])

        try registry.updatePluginContent(
            paneID: descriptor.id,
            pluginID: "agent",
            content: content
        )
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: nil,
            title: "Terminal",
            workingDirectory: nil
        )
        #expect(registry.content(for: descriptor.id, context: context) == content)
        #expect(throws: InspectorRegistry.RegistryError.ownerMismatch) {
            try registry.updatePluginContent(
                paneID: descriptor.id,
                pluginID: "other",
                content: content
            )
        }

        registry.disconnectPlugin("agent")
        #expect(registry.isEmpty)
    }

    @Test func descriptorsAndWidthsAreValidated() throws {
        let registry = InspectorRegistry()
        let descriptor = paneDescriptor(id: "valid.pane", source: .coreFeature("core"))
        try registry.registerCorePane(descriptor) { _ in
            .empty(title: "Empty", message: "No content")
        }
        #expect(throws: InspectorRegistry.RegistryError.duplicatePaneID) {
            try registry.registerCorePane(descriptor) { _ in
                .empty(title: "Empty", message: "No content")
            }
        }

        let invalid = InspectorPaneDescriptor(
            id: "invalid pane",
            title: "Invalid",
            systemImage: "sidebar.trailing",
            source: .coreFeature("core"),
            preferredWidth: 100,
            minimumWidth: 100
        )
        #expect(throws: InspectorRegistry.RegistryError.invalidDescriptor) {
            try registry.registerCorePane(invalid) { _ in
                .empty(title: "Empty", message: "No content")
            }
        }

        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        state.updateInspectorWidth(900, availableWidth: 800, persist: true)
        #expect(state.inspectorWidth == 400)
        #expect(state.committedInspectorWidth == 400)
        state.updateInspectorWidth(100, availableWidth: 800, persist: true)
        #expect(state.inspectorWidth == RightInspectorMetrics.minimumWidth)
    }

    private func paneDescriptor(
        id: String,
        source: InspectorPaneDescriptor.Source
    ) -> InspectorPaneDescriptor {
        .init(
            id: id,
            title: "Context",
            systemImage: "sidebar.trailing",
            source: source,
            preferredWidth: 320,
            minimumWidth: 220
        )
    }
}
