import Combine
import Foundation

struct RightInspectorMetrics {
    static let minimumWidth: CGFloat = 176
    static let defaultWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 640
}

struct InspectorPaneDescriptor: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case coreFeature(String)
        case plugin(String)

    }

    let id: String
    let title: String
    let systemImage: String
    let source: Source
    let preferredWidth: CGFloat
    let minimumWidth: CGFloat
}

struct InspectorField: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct InspectorListItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String?
}

enum InspectorFileIconTint: String, Equatable, Sendable {
    case secondary
    case blue
    case green
    case orange
    case yellow
    case purple
    case red
}

struct InspectorFileIcon: Equatable, Sendable {
    let systemImage: String
    let tint: InspectorFileIconTint
}

struct InspectorFileNode: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isDirectory: Bool
    let icon: InspectorFileIcon
    let isExpanded: Bool
    let isLoading: Bool
    let children: [InspectorFileNode]?
}

struct InspectorFileTree: Equatable, Sendable {
    let rootName: String
    let rootPath: String
    let nodes: [InspectorFileNode]
}

enum InspectorPaneActionKind: Equatable, Sendable {
    case toggleNode(id: String, expanded: Bool)
    case refresh
    case collapseAll
    case createFile(name: String)
    case createFolder(name: String)
    case createPortForward(target: String)
    case openPortForward(id: String)
    case copyPortForward(id: String)
    case removePortForward(id: String)
}

struct InspectorPaneAction: Equatable, Sendable {
    let context: InspectorPaneContext
    let kind: InspectorPaneActionKind
}

enum InspectorPaneContent: Equatable, Sendable {
    case empty(title: String, message: String)
    case fields([InspectorField])
    case list([InspectorListItem])
    case fileTree(InspectorFileTree)
    case info(InspectorInfoContent)
}

struct InspectorPaneContext: Equatable, Sendable {
    let tabID: UUID
    let surfaceID: UUID?
    let title: String
    let workingDirectory: String?
    let workspace: WorkspaceDescriptor?
    let session: PaneSessionContext

    init(
        tabID: UUID,
        surfaceID: UUID?,
        title: String,
        workingDirectory: String?,
        workspace: WorkspaceDescriptor? = nil,
        session: PaneSessionContext? = nil
    ) {
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.title = title
        self.workingDirectory = workingDirectory
        self.workspace = workspace
        self.session = session ?? .init(
            workingDirectory: workingDirectory,
            terminalTitle: title
        )
    }
}

enum InspectorPaneLifecycleEvent: Equatable, Sendable {
    case appeared(InspectorPaneContext)
    case disappeared(InspectorPaneContext)
}

@MainActor
final class InspectorRegistry: ObservableObject {
    enum RegistryError: Error, Equatable {
        case invalidDescriptor
        case duplicatePaneID
        case ownerMismatch
        case paneNotFound
    }

    struct Entry: Identifiable {
        let descriptor: InspectorPaneDescriptor
        var id: String { descriptor.id }
    }

    typealias ContentProvider = (InspectorPaneContext) -> InspectorPaneContent
    typealias LifecycleHandler = (InspectorPaneLifecycleEvent) -> Void
    typealias ActionHandler = (InspectorPaneAction) -> Void

    @Published private(set) var entries: [Entry] = []
    @Published private var contentRevision: UInt64 = 0

    private struct PresentedPane: Equatable {
        let paneID: String
        let context: InspectorPaneContext
    }

    private struct PluginContentKey: Hashable {
        let paneID: String
        let tabID: UUID?
    }

    private var contentProviders: [String: ContentProvider] = [:]
    private var lifecycleHandlers: [String: LifecycleHandler] = [:]
    private var actionHandlers: [String: ActionHandler] = [:]
    private var pluginContent: [PluginContentKey: InspectorPaneContent] = [:]
    private var presentedPanes: [UUID: PresentedPane] = [:]

    var isEmpty: Bool { entries.isEmpty }

    func descriptor(id: String) -> InspectorPaneDescriptor? {
        entries.first { $0.id == id }?.descriptor
    }

    func registerCorePane(
        _ descriptor: InspectorPaneDescriptor,
        content: @escaping ContentProvider,
        lifecycle: LifecycleHandler? = nil
    ) throws {
        guard case .coreFeature = descriptor.source else {
            throw RegistryError.ownerMismatch
        }
        try register(descriptor, content: content, lifecycle: lifecycle)
    }

    /// Registers a data-only plugin pane. Plugins update typed content and never
    /// receive an NSWindow, NSSplitView, NSView, or SwiftUI View capability.
    func registerPluginPane(
        _ descriptor: InspectorPaneDescriptor,
        lifecycle: LifecycleHandler? = nil,
        action: ActionHandler? = nil
    ) throws {
        guard case .plugin = descriptor.source else {
            throw RegistryError.ownerMismatch
        }
        try register(
            descriptor,
            content: { [weak self] context in
                self?.pluginContent[.init(
                    paneID: descriptor.id,
                    tabID: context.tabID
                )] ?? self?.pluginContent[.init(
                    paneID: descriptor.id,
                    tabID: nil
                )] ?? .empty(
                    title: descriptor.title,
                    message: "Waiting for plugin data"
                )
            },
            lifecycle: lifecycle,
            action: action
        )
    }

    func updatePluginPaneTitle(
        paneID: String,
        pluginID: String,
        title: String
    ) throws {
        guard let index = entries.firstIndex(where: { $0.id == paneID }) else {
            throw RegistryError.paneNotFound
        }
        let descriptor = entries[index].descriptor
        guard descriptor.source == .plugin(pluginID) else {
            throw RegistryError.ownerMismatch
        }
        let updated = InspectorPaneDescriptor(
            id: descriptor.id,
            title: title,
            systemImage: descriptor.systemImage,
            source: descriptor.source,
            preferredWidth: descriptor.preferredWidth,
            minimumWidth: descriptor.minimumWidth
        )
        guard Self.validate(updated) else { throw RegistryError.invalidDescriptor }
        entries[index] = .init(descriptor: updated)
    }

    func updatePluginContent(
        paneID: String,
        pluginID: String,
        tabID: UUID? = nil,
        content: InspectorPaneContent
    ) throws {
        guard let descriptor = descriptor(id: paneID) else {
            throw RegistryError.paneNotFound
        }
        guard descriptor.source == .plugin(pluginID) else {
            throw RegistryError.ownerMismatch
        }
        pluginContent[.init(paneID: paneID, tabID: tabID)] = content
        contentRevision &+= 1
    }

    func performAction(paneID: String, action: InspectorPaneAction) {
        actionHandlers[paneID]?(action)
    }

    func unregister(source: InspectorPaneDescriptor.Source) {
        let removedIDs = Set(entries.compactMap {
            $0.descriptor.source == source ? $0.id : nil
        })
        guard !removedIDs.isEmpty else { return }
        let removedHosts = presentedPanes.compactMap { hostID, presentation in
            removedIDs.contains(presentation.paneID)
                ? (hostID, presentation)
                : nil
        }
        for (hostID, presentation) in removedHosts {
            lifecycleHandlers[presentation.paneID]?(
                .disappeared(presentation.context)
            )
            presentedPanes.removeValue(forKey: hostID)
        }
        entries.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            contentProviders.removeValue(forKey: id)
            lifecycleHandlers.removeValue(forKey: id)
            actionHandlers.removeValue(forKey: id)
            pluginContent = pluginContent.filter { $0.key.paneID != id }
        }
    }

    func disconnectPlugin(_ pluginID: String) {
        unregister(source: .plugin(pluginID))
    }

    func content(for paneID: String, context: InspectorPaneContext) -> InspectorPaneContent? {
        _ = contentRevision
        return contentProviders[paneID]?(context)
    }

    func presentationDidChange(to paneID: String?, context: InspectorPaneContext) {
        let hostID = context.tabID
        let next = paneID.map { PresentedPane(paneID: $0, context: context) }
        guard presentedPanes[hostID] != next else { return }
        if let previous = presentedPanes[hostID] {
            lifecycleHandlers[previous.paneID]?(
                .disappeared(previous.context)
            )
        }
        presentedPanes[hostID] = next
        if let next {
            lifecycleHandlers[next.paneID]?(.appeared(context))
        }
    }

    private func register(
        _ descriptor: InspectorPaneDescriptor,
        content: @escaping ContentProvider,
        lifecycle: LifecycleHandler? = nil,
        action: ActionHandler? = nil
    ) throws {
        guard Self.validate(descriptor) else { throw RegistryError.invalidDescriptor }
        guard self.descriptor(id: descriptor.id) == nil else {
            throw RegistryError.duplicatePaneID
        }
        entries.append(.init(descriptor: descriptor))
        contentProviders[descriptor.id] = content
        lifecycleHandlers[descriptor.id] = lifecycle
        actionHandlers[descriptor.id] = action
    }

    private static func validate(_ descriptor: InspectorPaneDescriptor) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_")
        )
        let id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && id.count <= 128 &&
            id.unicodeScalars.allSatisfy(allowed.contains) &&
            !title.isEmpty && title.count <= 128 &&
            !descriptor.systemImage.isEmpty && descriptor.systemImage.count <= 128 &&
            (176...640).contains(descriptor.preferredWidth) &&
            (176...descriptor.preferredWidth).contains(descriptor.minimumWidth)
    }
}
