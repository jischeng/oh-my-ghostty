import Foundation

@MainActor
final class BuiltInFilesInspectorProvider {
    static let pluginID = "builtin.files"
    static let paneID = "builtin.files"

    private let registry: InspectorRegistry
    private var loadTask: Task<Void, Never>?

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
        try registry.registerPluginPane(descriptor) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        loadTask?.cancel()
        loadTask = nil
        guard case .appeared(let context) = event else { return }

        loadTask = Task { [weak self] in
            let content = await Task.detached(priority: .utility) {
                Self.loadContent(context: context)
            }.value
            guard !Task.isCancelled, let self else { return }
            try? registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                content: content
            )
        }
    }

    nonisolated private static func loadContent(
        context: InspectorPaneContext
    ) -> InspectorPaneContent {
        guard let path = context.workingDirectory,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty(
                title: "Files",
                message: "The terminal has not reported a working directory."
            )
        }

        let root = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return .empty(
                title: "Files",
                message: "The current working directory is unavailable."
            )
        }

        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let sorted = urls.sorted { lhs, rhs in
                let lhsDirectory = (try? lhs.resourceValues(forKeys: keys).isDirectory) == true
                let rhsDirectory = (try? rhs.resourceValues(forKeys: keys).isDirectory) == true
                if lhsDirectory != rhsDirectory { return lhsDirectory }
                return lhs.lastPathComponent.localizedStandardCompare(
                    rhs.lastPathComponent
                ) == .orderedAscending
            }
            let visible = sorted.prefix(200).map { url in
                let directory = (try? url.resourceValues(forKeys: keys).isDirectory) == true
                return InspectorListItem(
                    id: url.path,
                    title: url.lastPathComponent,
                    subtitle: directory ? "Folder" : nil,
                    systemImage: directory ? "folder" : "doc"
                )
            }
            guard !visible.isEmpty else {
                return .empty(title: root.lastPathComponent, message: "This folder is empty.")
            }
            return .list(visible)
        } catch {
            return .empty(title: "Files", message: error.localizedDescription)
        }
    }
}
