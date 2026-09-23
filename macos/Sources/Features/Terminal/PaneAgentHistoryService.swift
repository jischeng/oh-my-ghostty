import Foundation

/// Owns live subscriptions, not navigation. A transcript never manufactures a
/// terminal position. Tasks and callbacks are fenced by a per-subscription token.
@MainActor
final class PaneAgentHistoryService {
    enum State: Equatable, Sendable {
        case loading
        case ready
        case limited
        case unavailable
    }

    struct Snapshot: Equatable, Sendable {
        var items: [InspectorHistoryItem] = []
        var state: State = .loading
    }

    struct Binding: Equatable, Sendable {
        let agent: SupportedAgent
        let conversationID: AgentConversationID
        let remoteHost: String?
        let connectionID: String?

        static func current(descriptor: AgentResumeDescriptor, session: PaneSessionContext) -> Self? {
            guard let conversationID = descriptor.conversationID else { return nil }
            switch (descriptor.scope, session.state) {
            case (.local, .local):
                return .init(agent: descriptor.agent, conversationID: conversationID,
                             remoteHost: nil, connectionID: nil)
            case (.remote, .sshReady(let ssh, _)):
                guard let host = descriptor.sshReplay?.transferTarget, host == ssh.transferTarget else { return nil }
                return .init(agent: descriptor.agent, conversationID: conversationID,
                             remoteHost: host, connectionID: ssh.connectionID)
            default:
                // Never load the old local/remote descriptor during a connection handoff.
                return nil
            }
        }
    }

    typealias Resolve = @Sendable (Binding) async -> AgentHistorySession?
    private struct Subscription {
        let binding: Binding
        let token: UUID
        let task: Task<Void, Never>
        var snapshot = Snapshot()
    }
    private var subscriptions: [UUID: Subscription] = [:]
    private let resolve: Resolve
    private let interval: Duration

    init(interval: Duration = .seconds(3), resolve: @escaping Resolve = { binding in
        await AgentHistoryStore.session(agent: binding.agent, conversationID: binding.conversationID,
                                        remoteHost: binding.remoteHost)
    }) {
        self.interval = interval
        self.resolve = resolve
    }

    deinit {
        for subscription in subscriptions.values { subscription.task.cancel() }
    }

    func observe(surfaceID: UUID, binding: Binding, changed: @escaping @MainActor () -> Void) -> Snapshot {
        if let current = subscriptions[surfaceID], current.binding == binding { return current.snapshot }
        remove(surfaceID)
        let token = UUID()
        let resolve = self.resolve
        let interval = self.interval
        let task = Task { [weak self] in
            var reader: PanePromptReader?
            while !Task.isCancelled {
                if reader == nil, let session = await resolve(binding) {
                    reader = PanePromptReader(session: session)
                }
                var snapshot = Snapshot(state: .unavailable)
                if let reader {
                    do {
                        let result = try await reader.refresh()
                        snapshot = .init(items: result.items.reversed(), state: result.limited ? .limited : .ready)
                    } catch is CancellationError {
                        return
                    } catch {
                        // Keep existing text available to copy, but don't disguise a
                        // failed refresh as an empty or successfully refreshed list.
                        snapshot.items = self?.subscriptions[surfaceID]?.snapshot.items ?? []
                    }
                }
                guard !Task.isCancelled, self?.subscriptions[surfaceID]?.token == token else { return }
                if self?.subscriptions[surfaceID]?.snapshot != snapshot {
                    self?.subscriptions[surfaceID]?.snapshot = snapshot
                    changed()
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
        subscriptions[surfaceID] = .init(binding: binding, token: token, task: task)
        return .init()
    }

    func remove(_ surfaceID: UUID) {
        subscriptions.removeValue(forKey: surfaceID)?.task.cancel()
    }

    func retain(surfaces: Set<UUID>) {
        for id in Array(subscriptions.keys) where !surfaces.contains(id) { remove(id) }
    }

    func shutdown() { retain(surfaces: []) }
}
