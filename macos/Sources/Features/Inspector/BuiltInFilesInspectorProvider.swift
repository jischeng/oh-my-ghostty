import Foundation

@MainActor
final class BuiltInFilesInspectorProvider {
    static let pluginID = "builtin.files"
    static let paneID = "builtin.files"

    private struct BrowserState {
        var context: InspectorPaneContext
        var rootURL: URL
        var expanded: Set<String> = []
        var generation: UInt64 = 0
    }

    private let registry: InspectorRegistry
    private var states: [UUID: BrowserState] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]

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
        guard case .appeared(let context) = event else { return }
        guard context.workingDirectory?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false else {
            states.removeValue(forKey: context.tabID)
            loadTasks.removeValue(forKey: context.tabID)?.cancel()
            try? registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: context.tabID,
                content: .empty(
                    title: "Files",
                    message: "The terminal has not reported a working directory."
                )
            )
            return
        }
        var state = state(for: context)
        state.context = context
        states[context.tabID] = state
        reload(context: context)
    }

    private func handle(_ action: InspectorPaneAction) {
        let context = action.context
        var state = state(for: context)
        switch action.kind {
        case .toggleNode(let id, let expanded):
            if expanded {
                state.expanded.insert(id)
            } else {
                state.expanded = state.expanded.filter {
                    $0 != id && !$0.hasPrefix(id + "/")
                }
            }
            states[context.tabID] = state
            reload(context: context)

        case .refresh:
            states[context.tabID] = state
            reload(context: context)

        case .collapseAll:
            state.expanded.removeAll()
            states[context.tabID] = state
            reload(context: context)

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
        return .init(context: context, rootURL: rootURL)
    }

    private func reload(context: InspectorPaneContext) {
        var state = state(for: context)
        state.generation &+= 1
        states[context.tabID] = state
        let generation = state.generation
        let rootURL = state.rootURL
        let expanded = state.expanded

        loadTasks[context.tabID]?.cancel()
        try? registry.updatePluginContent(
            paneID: Self.paneID,
            pluginID: Self.pluginID,
            tabID: context.tabID,
            content: .empty(title: "Files", message: "Loading…")
        )
        loadTasks[context.tabID] = Task { [weak self] in
            let content = await Task.detached(priority: .utility) {
                Self.loadContent(rootURL: rootURL, expanded: expanded)
            }.value
            guard !Task.isCancelled,
                  let self,
                  states[context.tabID]?.generation == generation else { return }
            try? registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: context.tabID,
                content: content
            )
            loadTasks.removeValue(forKey: context.tabID)
        }
    }

    private func create(
        name: String,
        directory: Bool,
        context: InspectorPaneContext
    ) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validChildName(normalized) else { return }
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
            self?.reload(context: context)
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
        guard depth < 24 else { return [] }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }

        return urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { lhs, rhs in
                let lhsValues = try? lhs.resourceValues(forKeys: keys)
                let rhsValues = try? rhs.resourceValues(forKeys: keys)
                let lhsDirectory = lhsValues?.isDirectory == true && lhsValues?.isSymbolicLink != true
                let rhsDirectory = rhsValues?.isDirectory == true && rhsValues?.isSymbolicLink != true
                if lhsDirectory != rhsDirectory { return lhsDirectory }
                return lhs.lastPathComponent.localizedStandardCompare(
                    rhs.lastPathComponent
                ) == .orderedAscending
            }
            .prefix(500)
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                let directory = values?.isDirectory == true && values?.isSymbolicLink != true
                let nodeID = url.path
                let isExpanded = directory && expanded.contains(nodeID)
                let children = isExpanded
                    ? loadNodes(at: url, expanded: expanded, depth: depth + 1)
                    : nil
                return .init(
                    id: nodeID,
                    name: url.lastPathComponent,
                    isDirectory: directory,
                    icon: icon(for: url.lastPathComponent, isDirectory: directory),
                    isExpanded: isExpanded,
                    isLoading: false,
                    children: children
                )
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
