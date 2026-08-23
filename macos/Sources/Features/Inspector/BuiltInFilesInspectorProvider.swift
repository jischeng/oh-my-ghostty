import Foundation
import OSLog

@MainActor
final class BuiltInFilesInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "files-inspector"
    )
    static let pluginID = "builtin.files"
    static let paneID = "builtin.files"

    private static let rootTaskID = "__root__"

    private struct BrowserState {
        var context: InspectorPaneContext
        var rootURL: URL
        var expanded: Set<String> = []
        var generation: UInt64 = 0
        var tree: InspectorFileTree?
    }

    private struct LoadKey: Hashable {
        let tabID: UUID
        let nodeID: String
    }

    private struct DiskEntry: Sendable {
        let url: URL
        let isDirectory: Bool
    }

    private let registry: InspectorRegistry
    private var states: [UUID: BrowserState] = [:]
    private var loadTasks: [LoadKey: Task<Void, Never>] = [:]

    init(registry: InspectorRegistry) {
        self.registry = registry
    }

    func register() throws {
        let descriptor = InspectorPaneDescriptor(
            id: Self.paneID,
            title: "Files",
            systemImage: "folder",
            source: .plugin(Self.pluginID),
            preferredWidth: RightInspectorMetrics.defaultWidth,
            minimumWidth: 220
        )
        try registry.registerPluginPane(
            descriptor,
            lifecycle: { [weak self] event in self?.handle(event) },
            action: { [weak self] action in self?.handle(action) }
        )
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        guard case .appeared(let context) = event else {
            Self.logger.debug("Files pane disappeared")
            return
        }
        Self.logger.debug("Files pane appeared tab=\(context.tabID.uuidString, privacy: .public) cwd=\(context.workingDirectory ?? "<none>", privacy: .public)")
        guard context.workingDirectory?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false else {
            cancelTasks(tabID: context.tabID)
            states.removeValue(forKey: context.tabID)
            publish(
                .empty(
                    title: "Files",
                    message: "The terminal has not reported a working directory."
                ),
                tabID: context.tabID
            )
            return
        }

        let previousState = states[context.tabID]
        var state = state(for: context)
        state.context = context
        states[context.tabID] = state
        if previousState?.rootURL == state.rootURL, state.tree != nil {
            Self.logger.debug("Files context updated without root reload tab=\(context.tabID.uuidString, privacy: .public)")
            return
        }
        if previousState?.rootURL != state.rootURL {
            Self.logger.debug("Files cwd changed tab=\(context.tabID.uuidString, privacy: .public) root=\(state.rootURL.path, privacy: .public)")
        }
        reloadRoot(
            context: context,
            reason: previousState == nil ? "appear" : "cwd"
        )
    }

    private func handle(_ action: InspectorPaneAction) {
        let context = action.context
        var state = state(for: context)
        switch action.kind {
        case .toggleNode(let id, let expanded):
            Self.logger.debug("Files disclosure tab=\(context.tabID.uuidString, privacy: .public) node=\(id, privacy: .public) expanded=\(expanded)")
            guard let tree = state.tree,
                  let node = Self.findNode(id: id, in: tree.nodes),
                  node.isDirectory else {
                Self.logger.error("Files disclosure ignored missing node=\(id, privacy: .public)")
                return
            }

            if expanded {
                state.expanded.insert(id)
                state.tree = Self.updatingTree(tree, nodeID: id) { current in
                    Self.copy(
                        current,
                        isExpanded: true,
                        isLoading: current.children == nil,
                        children: current.children
                    )
                }
                states[context.tabID] = state
                publishTree(for: context.tabID)
                if node.children == nil {
                    loadChildren(nodeID: id, context: context)
                }
            } else {
                state.expanded = Set(state.expanded.filter {
                    $0 != id && !$0.hasPrefix(id + "/")
                })
                cancelNodeTasks(tabID: context.tabID, pathPrefix: id)
                state.tree = Self.updatingTree(tree, nodeID: id) { current in
                    Self.copy(
                        current,
                        isExpanded: false,
                        isLoading: false,
                        children: current.children
                    )
                }
                states[context.tabID] = state
                publishTree(for: context.tabID)
            }

        case .refresh:
            states[context.tabID] = state
            reloadRoot(context: context, reason: "manual-refresh")

        case .collapseAll:
            state.expanded.removeAll()
            cancelNodeTasks(tabID: context.tabID)
            if let tree = state.tree {
                state.tree = .init(
                    rootName: tree.rootName,
                    rootPath: tree.rootPath,
                    nodes: Self.collapsing(nodes: tree.nodes)
                )
            }
            states[context.tabID] = state
            publishTree(for: context.tabID)

        case .createFile(let name):
            create(name: name, directory: false, context: context)

        case .createFolder(let name):
            create(name: name, directory: true, context: context)
        }
    }

    private func state(for context: InspectorPaneContext) -> BrowserState {
        let rootURL = Self.rootURL(for: context)
        if var state = states[context.tabID], state.rootURL == rootURL {
            state.context = context
            return state
        }
        cancelTasks(tabID: context.tabID)
        return .init(context: context, rootURL: rootURL)
    }

    private func reloadRoot(context: InspectorPaneContext, reason: String) {
        var state = state(for: context)
        state.generation &+= 1
        states[context.tabID] = state
        let generation = state.generation
        let rootURL = state.rootURL
        let expanded = state.expanded
        let key = LoadKey(tabID: context.tabID, nodeID: Self.rootTaskID)

        cancelTasks(tabID: context.tabID)
        if state.tree == nil {
            publish(.empty(title: "Files", message: "Loading…"), tabID: context.tabID)
        }
        let started = ContinuousClock.now
        Self.logger.debug("Files root refresh started tab=\(context.tabID.uuidString, privacy: .public) generation=\(generation) reason=\(reason, privacy: .public) root=\(rootURL.path, privacy: .public) expanded=\(expanded.count)")
        let diskTask = Task.detached(priority: .utility) {
            Self.loadContent(rootURL: rootURL, expanded: expanded)
        }
        loadTasks[key] = Task { [weak self] in
            let content = await withTaskCancellationHandler(
                operation: { await diskTask.value },
                onCancel: { diskTask.cancel() }
            )
            guard !Task.isCancelled,
                  let self,
                  states[context.tabID]?.generation == generation else {
                Self.logger.debug("Files root refresh discarded tab=\(context.tabID.uuidString, privacy: .public) generation=\(generation)")
                return
            }
            if case .fileTree(let tree) = content {
                states[context.tabID]?.tree = tree
            }
            publish(content, tabID: context.tabID)
            loadTasks.removeValue(forKey: key)
            let elapsed = ContinuousClock.now - started
            Self.logger.debug("Files root refresh completed tab=\(context.tabID.uuidString, privacy: .public) generation=\(generation) elapsed=\(elapsed) summary=\(Self.summary(content), privacy: .public)")
        }
    }

    private func loadChildren(nodeID: String, context: InspectorPaneContext) {
        guard let state = states[context.tabID] else { return }
        let generation = state.generation
        let expanded = state.expanded
        let key = LoadKey(tabID: context.tabID, nodeID: nodeID)
        loadTasks[key]?.cancel()
        let started = ContinuousClock.now
        Self.logger.debug("Files subtree read started tab=\(context.tabID.uuidString, privacy: .public) node=\(nodeID, privacy: .public) generation=\(generation)")
        let diskTask = Task.detached(priority: .utility) {
            Self.loadNodes(
                at: URL(fileURLWithPath: nodeID),
                expanded: expanded,
                depth: 0
            )
        }
        loadTasks[key] = Task { [weak self] in
            let children = await withTaskCancellationHandler(
                operation: { await diskTask.value },
                onCancel: { diskTask.cancel() }
            )
            guard !Task.isCancelled,
                  let self,
                  var current = states[context.tabID],
                  current.generation == generation,
                  current.expanded.contains(nodeID),
                  let tree = current.tree else {
                Self.logger.debug("Files subtree read discarded tab=\(context.tabID.uuidString, privacy: .public) node=\(nodeID, privacy: .public)")
                return
            }
            current.tree = Self.updatingTree(tree, nodeID: nodeID) { node in
                Self.copy(
                    node,
                    isExpanded: true,
                    isLoading: false,
                    children: children
                )
            }
            states[context.tabID] = current
            publishTree(for: context.tabID)
            loadTasks.removeValue(forKey: key)
            let elapsed = ContinuousClock.now - started
            Self.logger.debug("Files subtree read completed tab=\(context.tabID.uuidString, privacy: .public) node=\(nodeID, privacy: .public) children=\(children.count) elapsed=\(elapsed)")
        }
    }

    private func publishTree(for tabID: UUID) {
        guard let tree = states[tabID]?.tree else { return }
        publish(.fileTree(tree), tabID: tabID)
    }

    private func publish(_ content: InspectorPaneContent, tabID: UUID) {
        do {
            try registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: tabID,
                content: content
            )
        } catch {
            Self.logger.error("Files state publish failed tab=\(tabID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelTasks(tabID: UUID) {
        let keys = loadTasks.keys.filter { $0.tabID == tabID }
        for key in keys {
            loadTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func cancelNodeTasks(tabID: UUID, pathPrefix: String? = nil) {
        let keys = loadTasks.keys.filter { key in
            guard key.tabID == tabID, key.nodeID != Self.rootTaskID else { return false }
            guard let pathPrefix else { return true }
            return key.nodeID == pathPrefix || key.nodeID.hasPrefix(pathPrefix + "/")
        }
        for key in keys {
            loadTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func create(
        name: String,
        directory: Bool,
        context: InspectorPaneContext
    ) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validChildName(normalized) else {
            Self.logger.error("Files create rejected invalid name=\(normalized, privacy: .public)")
            return
        }
        let rootURL = state(for: context).rootURL
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                let destination = rootURL.appendingPathComponent(normalized)
                if directory {
                    try? FileManager.default.createDirectory(
                        at: destination,
                        withIntermediateDirectories: false
                    )
                } else if !FileManager.default.fileExists(atPath: destination.path) {
                    _ = FileManager.default.createFile(
                        atPath: destination.path,
                        contents: Data()
                    )
                }
            }.value
            self?.reloadRoot(context: context, reason: directory ? "create-folder" : "create-file")
        }
    }

    nonisolated private static func rootURL(for context: InspectorPaneContext) -> URL {
        guard let path = context.workingDirectory,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return URL(fileURLWithPath: "/")
        }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    nonisolated private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":")
    }

    nonisolated private static func loadContent(
        rootURL: URL,
        expanded: Set<String>
    ) -> InspectorPaneContent {
        let started = ContinuousClock.now
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: rootURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return .empty(
                title: "Files",
                message: "The current working directory is unavailable."
            )
        }

        let nodes = loadNodes(at: rootURL, expanded: expanded, depth: 0)
        let elapsed = ContinuousClock.now - started
        Self.logger.debug("Files root read completed root=\(rootURL.path, privacy: .public) nodes=\(nodes.count) elapsed=\(elapsed)")
        return .fileTree(.init(
            rootName: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent,
            rootPath: rootURL.path,
            nodes: nodes
        ))
    }

    nonisolated private static func loadNodes(
        at directoryURL: URL,
        expanded: Set<String>,
        depth: Int
    ) -> [InspectorFileNode] {
        guard depth < 24, !Task.isCancelled else { return [] }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let started = ContinuousClock.now
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            Self.logger.error("Files directory read failed path=\(directoryURL.path, privacy: .public)")
            return []
        }

        var entries: [DiskEntry] = []
        entries.reserveCapacity(min(urls.count, 500))
        for url in urls where !Task.isCancelled && url.lastPathComponent != ".DS_Store" {
            let values = try? url.resourceValues(forKeys: keys)
            entries.append(.init(
                url: url,
                isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(
                rhs.url.lastPathComponent
            ) == .orderedAscending
        }
        if entries.count > 500 { entries.removeSubrange(500...) }
        let elapsed = ContinuousClock.now - started
        Self.logger.debug("Files directory read path=\(directoryURL.path, privacy: .public) depth=\(depth) entries=\(entries.count) elapsed=\(elapsed)")

        var nodes: [InspectorFileNode] = []
        nodes.reserveCapacity(entries.count)
        for entry in entries where !Task.isCancelled {
            let nodeID = entry.url.path
            let isExpanded = entry.isDirectory && expanded.contains(nodeID)
            let children = isExpanded
                ? loadNodes(at: entry.url, expanded: expanded, depth: depth + 1)
                : nil
            nodes.append(.init(
                id: nodeID,
                name: entry.url.lastPathComponent,
                isDirectory: entry.isDirectory,
                icon: icon(for: entry.url.lastPathComponent, isDirectory: entry.isDirectory),
                isExpanded: isExpanded,
                isLoading: false,
                children: children
            ))
        }
        return nodes
    }

    nonisolated private static func findNode(
        id: String,
        in nodes: [InspectorFileNode]
    ) -> InspectorFileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let match = findNode(id: id, in: node.children ?? []) { return match }
        }
        return nil
    }

    nonisolated private static func updatingTree(
        _ tree: InspectorFileTree,
        nodeID: String,
        transform: (InspectorFileNode) -> InspectorFileNode
    ) -> InspectorFileTree {
        .init(
            rootName: tree.rootName,
            rootPath: tree.rootPath,
            nodes: updating(nodes: tree.nodes, nodeID: nodeID, transform: transform)
        )
    }

    nonisolated private static func updating(
        nodes: [InspectorFileNode],
        nodeID: String,
        transform: (InspectorFileNode) -> InspectorFileNode
    ) -> [InspectorFileNode] {
        nodes.map { node in
            if node.id == nodeID { return transform(node) }
            guard let children = node.children else { return node }
            let updatedChildren = updating(
                nodes: children,
                nodeID: nodeID,
                transform: transform
            )
            guard updatedChildren != children else { return node }
            return copy(node, children: updatedChildren)
        }
    }

    nonisolated private static func collapsing(
        nodes: [InspectorFileNode]
    ) -> [InspectorFileNode] {
        nodes.map { node in
            copy(
                node,
                isExpanded: false,
                isLoading: false,
                children: node.children.map(collapsing(nodes:))
            )
        }
    }

    nonisolated private static func copy(
        _ node: InspectorFileNode,
        isExpanded: Bool? = nil,
        isLoading: Bool? = nil,
        children: [InspectorFileNode]? = nil
    ) -> InspectorFileNode {
        .init(
            id: node.id,
            name: node.name,
            isDirectory: node.isDirectory,
            icon: node.icon,
            isExpanded: isExpanded ?? node.isExpanded,
            isLoading: isLoading ?? node.isLoading,
            children: children ?? node.children
        )
    }

    nonisolated private static func summary(_ content: InspectorPaneContent) -> String {
        switch content {
        case .fileTree(let tree): "fileTree root=\(tree.rootPath) nodes=\(tree.nodes.count)"
        case .empty(let title, _): "empty title=\(title)"
        case .fields(let fields): "fields count=\(fields.count)"
        case .list(let items): "list count=\(items.count)"
        }
    }

    nonisolated private static func icon(
        for name: String,
        isDirectory: Bool
    ) -> InspectorFileIcon {
        if isDirectory {
            return .init(systemImage: "folder", tint: .blue)
        }

        let lower = name.lowercased()
        let ext = URL(fileURLWithPath: lower).pathExtension
        if [".gitconfig", ".gitignore", ".gitattributes"].contains(lower) ||
            lower == "gitconfig" {
            return .init(systemImage: "point.3.connected.trianglepath.dotted", tint: .orange)
        }
        if [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].contains(lower) {
            return .init(systemImage: "terminal", tint: .green)
        }
        if ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"].contains(lower) {
            return .init(systemImage: "shippingbox", tint: .red)
        }
        if ["cargo.toml", "cargo.lock"].contains(lower) {
            return .init(systemImage: "gearshape.2", tint: .orange)
        }

        switch ext {
        case "swift": return .init(systemImage: "swift", tint: .orange)
        case "js", "jsx": return .init(systemImage: "curlybraces", tint: .yellow)
        case "ts", "tsx": return .init(systemImage: "curlybraces", tint: .blue)
        case "json": return .init(systemImage: "curlybraces.square", tint: .yellow)
        case "py": return .init(systemImage: "chevron.left.forwardslash.chevron.right", tint: .yellow)
        case "rs": return .init(systemImage: "gearshape.2", tint: .orange)
        case "go": return .init(systemImage: "g.circle", tint: .blue)
        case "zig": return .init(systemImage: "bolt", tint: .orange)
        case "sh", "bash", "zsh", "fish": return .init(systemImage: "terminal", tint: .green)
        case "md", "markdown": return .init(systemImage: "doc.richtext", tint: .blue)
        case "yaml", "yml", "toml", "ini", "conf":
            return .init(systemImage: "gearshape.2", tint: .secondary)
        case "png", "jpg", "jpeg", "gif", "webp", "svg":
            return .init(systemImage: "photo", tint: .purple)
        case "pdf": return .init(systemImage: "doc.richtext", tint: .red)
        default: return .init(systemImage: "doc.text", tint: .secondary)
        }
    }
}
