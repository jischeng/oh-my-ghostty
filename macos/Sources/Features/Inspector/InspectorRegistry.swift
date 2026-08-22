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

enum InspectorPaneContent: Equatable, Sendable {
    case empty(title: String, message: String)
    case fields([InspectorField])
    case list([InspectorListItem])
}

struct InspectorPaneContext: Equatable, Sendable {
    let tabID: UUID
    let surfaceID: UUID?
    let title: String
    let workingDirectory: String?
}

enum InspectorPaneLifecycleEvent: Equatable, Sendable {
    case appeared(InspectorPaneContext)
    case disappeared
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

    @Published private(set) var entries: [Entry] = []
    @Published private var contentRevision: UInt64 = 0

    private var contentProviders: [String: ContentProvider] = [:]
    private var lifecycleHandlers: [String: LifecycleHandler] = [:]
    private var pluginContent: [String: InspectorPaneContent] = [:]
    private var presentedPanes: [UUID: String] = [:]

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
    func registerPluginPane(_ descriptor: InspectorPaneDescriptor) throws {
        guard case .plugin = descriptor.source else {
            throw RegistryError.ownerMismatch
        }
        try register(descriptor, content: { [weak self] _ in
            self?.pluginContent[descriptor.id] ?? .empty(
                title: descriptor.title,
                message: "Waiting for plugin data"
            )
        })
    }

    func updatePluginContent(
        paneID: String,
        pluginID: String,
        content: InspectorPaneContent
    ) throws {
        guard let descriptor = descriptor(id: paneID) else {
            throw RegistryError.paneNotFound
        }
        guard descriptor.source == .plugin(pluginID) else {
            throw RegistryError.ownerMismatch
        }
        pluginContent[paneID] = content
        contentRevision &+= 1
    }

    func unregister(source: InspectorPaneDescriptor.Source) {
        let removedIDs = Set(entries.compactMap {
            $0.descriptor.source == source ? $0.id : nil
        })
        guard !removedIDs.isEmpty else { return }
        let removedHosts = presentedPanes.compactMap { hostID, paneID in
            removedIDs.contains(paneID) ? (hostID, paneID) : nil
        }
        for (hostID, paneID) in removedHosts {
            lifecycleHandlers[paneID]?(.disappeared)
            presentedPanes.removeValue(forKey: hostID)
        }
        entries.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            contentProviders.removeValue(forKey: id)
            lifecycleHandlers.removeValue(forKey: id)
            pluginContent.removeValue(forKey: id)
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
        guard presentedPanes[hostID] != paneID else { return }
        if let previousPaneID = presentedPanes[hostID] {
            lifecycleHandlers[previousPaneID]?(.disappeared)
        }
        presentedPanes[hostID] = paneID
        if let paneID {
            lifecycleHandlers[paneID]?(.appeared(context))
        }
    }

    private func register(
        _ descriptor: InspectorPaneDescriptor,
        content: @escaping ContentProvider,
        lifecycle: LifecycleHandler? = nil
    ) throws {
        guard Self.validate(descriptor) else { throw RegistryError.invalidDescriptor }
        guard self.descriptor(id: descriptor.id) == nil else {
            throw RegistryError.duplicatePaneID
        }
        entries.append(.init(descriptor: descriptor))
        contentProviders[descriptor.id] = content
        lifecycleHandlers[descriptor.id] = lifecycle
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
