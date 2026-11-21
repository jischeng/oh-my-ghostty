import AppKit
import Testing
@testable import Ghostty

@MainActor
struct InspectorFileTreeViewTests {
    private func file(_ path: String, name: String? = nil) -> InspectorFileNode {
        .init(id: path, name: name ?? path, isDirectory: false,
              icon: .init(systemImage: "doc", tint: .secondary),
              isExpanded: false, isLoading: false, children: nil)
    }
    private func folder(expanded: Bool, children: [InspectorFileNode]?) -> InspectorFileNode {
        .init(id: "/repo/folder", name: "folder", isDirectory: true,
              icon: .init(systemImage: "folder", tint: .blue),
              isExpanded: expanded, isLoading: expanded && children == nil, children: children)
    }

    @Test func asynchronousChildrenKeepIdentityAndSelectionWithoutEchoingProviderExpansion() throws {
        let controller = InspectorFileTreeController()
        var actions: [InspectorPaneActionKind] = []
        func update(_ directory: InspectorFileNode) {
            controller.update(.init(rootName: "repo", rootPath: "/repo", nodes: [directory]), isLight: false) {
                actions.append($0)
            }
        }
        update(folder(expanded: false, children: nil))
        let original = try #require(controller.items["/repo/folder"])
        controller.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.outline.expandItem(original)
        #expect(actions == [.toggleNode(id: "/repo/folder", expanded: true)])
        update(folder(expanded: true, children: nil))
        update(folder(expanded: true, children: [file("/repo/folder/one")]))
        #expect(controller.items["/repo/folder"] === original)
        #expect(controller.outline.numberOfRows == 2)
        #expect(controller.outline.item(atRow: controller.outline.selectedRow) as? InspectorFileTreeController.Item === original)
        #expect(actions.count == 1)
        let child = try #require(controller.items["/repo/folder/one"])
        controller.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        update(folder(expanded: true, children: [file("/repo/folder/zero"), file("/repo/folder/one", name: "updated")]))
        #expect(controller.items["/repo/folder/one"] === child)
        #expect(controller.outline.item(atRow: controller.outline.selectedRow) as? InspectorFileTreeController.Item === child)
        update(folder(expanded: false, children: [file("/repo/folder/one")]))
        #expect(controller.outline.numberOfRows == 1)
        #expect(actions.count == 1)
    }

    @Test func largeSnapshotsRetainItemsAndResetSelectionWhenRootChanges() throws {
        let controller = InspectorFileTreeController()
        let nodes = (0..<10_000).map { file("/repo/file-\($0)") }
        controller.update(.init(rootName: "repo", rootPath: "/repo", nodes: nodes), isLight: false) { _ in }
        #expect(controller.outline.numberOfRows == 10_000)
        let original = try #require(controller.items["/repo/file-5000"])
        controller.outline.selectRowIndexes(IndexSet(integer: 5000), byExtendingSelection: false)
        controller.update(.init(rootName: "repo", rootPath: "/repo", nodes: nodes), isLight: true) { _ in }
        #expect(controller.items["/repo/file-5000"] === original)
        #expect(controller.outline.selectedRow == 5000)
        controller.update(.init(rootName: "other", rootPath: "/other", nodes: [file("/other/file")]), isLight: true) { _ in }
        #expect(controller.items.count == 1)
        #expect(controller.outline.selectedRow == -1)
    }

    @Test func filesPaneStringsFollowTheLanguageSetting() {
        let english = FilesStrings(language: .english)
        let chinese = FilesStrings(language: .simplifiedChinese)
        #expect(english.title == "Files")
        #expect(chinese.title == "文件")
        #expect(english.rename == "Rename…")
        #expect(chinese.rename == "重命名…")
        #expect(chinese.openIn == "打开方式…")
        #expect(chinese.renameTitle("a.txt") == "重命名 a.txt")
        #expect(chinese.createMessage(folder: "src") == "请输入名称，将创建在 src 中。")
        #expect(chinese.destinationTitle(.currentPane) == "当前窗格")
        #expect(english.destinationTitle(.currentPane) == "Current Pane")
    }

    @Test func menuActionsKeepTheContextThatOpenedTheMenu() throws {
        let controller = InspectorFileTreeController()
        let tree = InspectorFileTree(rootName: "repo", rootPath: "/repo", nodes: [file("/repo/one")])
        var first: [InspectorPaneActionKind] = []
        var second: [InspectorPaneActionKind] = []
        controller.update(tree, isLight: false) { first.append($0) }
        let menu = controller.menu(for: try #require(controller.items["/repo/one"]))
        controller.update(tree, isLight: false) { second.append($0) }
        let rename = try #require(menu.items.first { $0.title == FilesStrings.current.rename })
        let action = try #require(rename.action)
        NSApp.sendAction(action, to: rename.target, from: rename)
        #expect(first == [.renameFile(path: "/repo/one")])
        #expect(second.isEmpty)
    }

    @Test func localFilesInspectorAutoRefreshesOnFilesystemChangesAndStopsWatchingOnDisappear() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-fsevents-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("initial.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("inside.swift"))

        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            fsEventDebounceInterval: .milliseconds(30),
            openFile: { _, _, _ in }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Files Test",
            workingDirectory: root.path
        )

        func currentTree() -> InspectorFileTree? {
            guard case .fileTree(let tree) = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            ) else {
                return nil
            }
            return tree
        }

        registry.presentationDidChange(to: BuiltInFilesInspectorProvider.paneID, context: context)
        for _ in 0..<80 {
            if let tree = currentTree(), tree.nodes.count == 2 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(provider.activeWatchedDirectoryCountForTesting == 1)

        // Expand `src` so both root and expanded subdirectory are watched.
        let initialSrcNode = try #require(currentTree()?.nodes.first(where: { $0.name == "src" }))
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .toggleNode(id: initialSrcNode.id, expanded: true))
        )
        for _ in 0..<80 {
            if provider.activeWatchedDirectoryCountForTesting == 2,
               let srcNode = currentTree()?.nodes.first(where: { $0.name == "src" }),
               srcNode.children?.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(provider.activeWatchedDirectoryCountForTesting == 2)

        // External terminal touch/rm updates both root and expanded subdirectory automatically.
        try Data("created".utf8).write(to: root.appendingPathComponent("added.md"))
        try Data("nested".utf8).write(to: nested.appendingPathComponent("extra.swift"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("initial.txt"))

        for _ in 0..<100 {
            if let tree = currentTree(),
               tree.nodes.contains(where: { $0.name == "added.md" }),
               !tree.nodes.contains(where: { $0.name == "initial.txt" }),
               tree.nodes.first(where: { $0.name == "src" })?.children?.count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let updatedTree = try #require(currentTree())
        #expect(updatedTree.nodes.map(\.name) == ["src", "added.md"])
        #expect(updatedTree.nodes.first(where: { $0.name == "src" })?.children?.map(\.name) == ["extra.swift", "inside.swift"])

        // Hiding the Files pane immediately tears down all directory watchers.
        registry.presentationDidChange(to: nil, context: context)
        #expect(provider.activeWatchedDirectoryCountForTesting == 0)
    }

    @Test func deletingOrMovingWatchedDirectoriesClosesEventOnlyFileDescriptorsImmediately() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-fd-leak-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("workspace")
        let srcDir = root.appendingPathComponent("src")
        let nestedDir = srcDir.appendingPathComponent("nested")
        let movedSrcDir = sandbox.appendingPathComponent("moved-src")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try Data("root".utf8).write(to: root.appendingPathComponent("README.md"))
        // Include a sibling file in `src` so `src` and `nested` are distinct non-compacted nodes.
        try Data("app".utf8).write(to: srcDir.appendingPathComponent("App.swift"))
        try Data("leaf".utf8).write(to: nestedDir.appendingPathComponent("Leaf.swift"))

        let registry = InspectorRegistry()
        let provider = BuiltInFilesInspectorProvider(
            registry: registry,
            fsEventDebounceInterval: .milliseconds(25),
            openFile: { _, _, _ in }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "FD Leak Test",
            workingDirectory: root.path
        )

        func currentTree() -> InspectorFileTree? {
            guard case .fileTree(let tree) = registry.content(
                for: BuiltInFilesInspectorProvider.paneID,
                context: context
            ) else {
                return nil
            }
            return tree
        }

        registry.presentationDidChange(to: BuiltInFilesInspectorProvider.paneID, context: context)
        for _ in 0..<80 {
            if currentTree()?.nodes.count == 2 { break }
            try await Task.sleep(for: .milliseconds(15))
        }

        let srcNode = try #require(currentTree()?.nodes.first(where: { $0.name == "src" }))
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .toggleNode(id: srcNode.id, expanded: true))
        )
        for _ in 0..<80 {
            if currentTree()?.nodes.first(where: { $0.name == "src" })?.children?.count == 2 { break }
            try await Task.sleep(for: .milliseconds(15))
        }

        let nestedNode = try #require(
            currentTree()?.nodes.first(where: { $0.name == "src" })?.children?.first(where: { $0.name == "nested" })
        )
        registry.performAction(
            paneID: BuiltInFilesInspectorProvider.paneID,
            action: .init(context: context, kind: .toggleNode(id: nestedNode.id, expanded: true))
        )
        for _ in 0..<80 {
            if provider.activeWatchedDirectoryCountForTesting == 3 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(provider.activeWatchedDirectoryCountForTesting == 3)

        // 1. Moving `src` out of `root` must release BOTH `src` and `src/nested` O_EVTONLY descriptors.
        try FileManager.default.moveItem(at: srcDir, to: movedSrcDir)
        for _ in 0..<100 {
            if provider.activeWatchedDirectoryCountForTesting == 1,
               currentTree()?.nodes.map(\.name) == ["README.md"] {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(provider.activeWatchedDirectoryCountForTesting == 1)

        // 2. Single-child compact chains (`pkg/internal`) also watch intermediate `pkg` and close cleanly on delete.
        let compactLeafDir = root.appendingPathComponent("pkg/internal")
        try FileManager.default.createDirectory(at: compactLeafDir, withIntermediateDirectories: true)
        try Data("mod".utf8).write(to: compactLeafDir.appendingPathComponent("Mod.swift"))
        for _ in 0..<100 {
            if currentTree()?.nodes.contains(where: { $0.name == "pkg/internal" }) == true,
               provider.activeWatchedDirectoryCountForTesting == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(provider.activeWatchedDirectoryCountForTesting == 2)

        // 3. Deleting the root directory while the Files pane stays visible transitions to `.empty`
        // and closes all O_EVTONLY descriptors immediately.
        try FileManager.default.removeItem(at: root)
        for _ in 0..<100 {
            if provider.activeWatchedDirectoryCountForTesting == 0,
               case .empty = registry.content(for: BuiltInFilesInspectorProvider.paneID, context: context) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(provider.activeWatchedDirectoryCountForTesting == 0)
        if case .empty = registry.content(for: BuiltInFilesInspectorProvider.paneID, context: context) {
            // Expected `.empty` state when root directory disappears.
        } else {
            Issue.record("Expected Files pane to publish .empty after root directory removal")
        }

        registry.presentationDidChange(to: nil, context: context)
    }
}
