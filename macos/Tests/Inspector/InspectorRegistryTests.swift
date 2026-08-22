import Foundation
import Testing
@testable import Ghostty

@MainActor
struct InspectorRegistryTests {
    @Test func inspectorPresentationPersistsVisibilityWidthAndPane() throws {
        let suite = "InspectorPresentationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InspectorPresentationStore(defaults: defaults)

        store.setVisible(true)
        store.setWidth(412)
        store.selectPane("builtin.files")

        let restored = InspectorPresentationStore(defaults: defaults)
        #expect(restored.snapshot == .init(
            isVisible: true,
            width: 412,
            selectedPaneID: "builtin.files"
        ))
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: false,
            inspectorPresentation: restored
        )
        #expect(state.isInspectorVisible)
        #expect(state.inspectorWidth == 412)
        #expect(state.selectedInspectorPaneID == "builtin.files")
    }

    @Test func emptyRegistryDoesNotMutateWindowLayoutState() throws {
        let suite = "InspectorEmptyRegistryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = InspectorRegistry()
        let state = VerticalTabWindowLayoutState(
            isSidebarVisible: false,
            inspectorPresentation: InspectorPresentationStore(defaults: defaults)
        )

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

        let updatedContext = InspectorPaneContext(
            tabID: context.tabID,
            surfaceID: context.surfaceID,
            title: "Updated Shell",
            workingDirectory: "/var/tmp"
        )
        registry.presentationDidChange(to: descriptor.id, context: context)
        registry.presentationDidChange(to: descriptor.id, context: updatedContext)
        registry.presentationDidChange(to: nil, context: updatedContext)
        #expect(events == [
            .appeared(context),
            .disappeared,
            .appeared(updatedContext),
            .disappeared,
        ])
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

    @Test func builtInFilesProviderUsesPluginDataBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        try "print(\"demo\")".write(
            to: sources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "demo".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: root.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )

        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Demo",
            workingDirectory: root.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: context
        )

        var content: InspectorPaneContent?
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree = content { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let initialTree) = content else {
            Issue.record("Expected a typed Files tree")
            return
        }
        #expect(initialTree.rootName == root.lastPathComponent)
        #expect(initialTree.nodes.map(\.name) == ["Sources", "package.json", "README.md"])
        #expect(initialTree.nodes[0].isDirectory)
        #expect(initialTree.nodes[0].children == nil)
        #expect(initialTree.nodes[1].icon.systemImage == "shippingbox")

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .toggleNode(id: initialTree.nodes[0].id, expanded: true)
            )
        )
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree(let tree) = content,
               tree.nodes.first?.children?.first?.name == "main.swift" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let expandedTree) = content else {
            Issue.record("Expected an expanded Files tree")
            return
        }
        #expect(expandedTree.nodes[0].isExpanded)
        #expect(expandedTree.nodes[0].children?.map(\.name) == ["main.swift"])
        #expect(expandedTree.nodes[0].children?.first?.icon.systemImage == "swift")

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .collapseAll)
        )
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree(let tree) = content,
               tree.nodes.first?.isExpanded == false { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let collapsedTree) = content else {
            Issue.record("Expected collapsed Files tree")
            return
        }
        #expect(collapsedTree.nodes[0].children == nil)

        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .createFile(name: "created.json"))
        )
        for _ in 0..<20 where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("created.json").path
        ) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("created.json").path
        ))
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .createFolder(name: "Created Folder"))
        )
        for _ in 0..<20 where !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Created Folder").path
        ) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Created Folder").path
        ))
        try "external".write(
            to: root.appendingPathComponent("external.toml"),
            atomically: true,
            encoding: .utf8
        )
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .refresh)
        )
        for _ in 0..<20 {
            content = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            )
            if case .fileTree(let tree) = content,
               tree.nodes.contains(where: { $0.name == "external.toml" }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let refreshedTree) = content else {
            Issue.record("Expected refreshed Files tree")
            return
        }
        #expect(refreshedTree.nodes.contains(where: { $0.name == "external.toml" }))

        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try "second".write(
            to: secondRoot.appendingPathComponent("second.py"),
            atomically: true,
            encoding: .utf8
        )
        let secondContext = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Second",
            workingDirectory: secondRoot.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: secondContext
        )
        var secondContent: InspectorPaneContent?
        for _ in 0..<20 {
            secondContent = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: secondContext
            )
            if case .fileTree = secondContent { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let secondTree) = secondContent else {
            Issue.record("Expected tab-scoped Files content")
            return
        }
        #expect(secondTree.rootPath == secondRoot.path)
        #expect(secondTree.nodes.map(\.name) == ["second.py"])
        guard case .fileTree(let retainedFirstTree) = registry.content(
            for: BuiltInFilesInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected first tab Files content to remain isolated")
            return
        }
        #expect(retainedFirstTree.rootPath == root.path)

        let movedContext = InspectorPaneContext(
            tabID: context.tabID,
            surfaceID: context.surfaceID,
            title: context.title,
            workingDirectory: secondRoot.path
        )
        registry.presentationDidChange(
            to: BuiltInFilesInspectorProvider.paneID,
            context: movedContext
        )
        var movedContent: InspectorPaneContent?
        for _ in 0..<20 {
            movedContent = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: movedContext
            )
            if case .fileTree(let tree) = movedContent,
               tree.rootPath == secondRoot.path { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .fileTree(let movedTree) = movedContent else {
            Issue.record("Expected cwd-driven Files refresh")
            return
        }
        #expect(movedTree.rootPath == secondRoot.path)
        #expect(registry.descriptor(id: BuiltInFilesInspectorProvider.paneID)?.source ==
            .plugin(BuiltInFilesInspectorProvider.pluginID))

        registry.disconnectPlugin(BuiltInFilesInspectorProvider.pluginID)
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
