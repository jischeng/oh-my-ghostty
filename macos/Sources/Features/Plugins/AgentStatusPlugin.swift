import Foundation

/// Converts explicit terminal progress events into declarative session status commands.
/// The out-of-process plugin owns agent identification and feeds only matching sessions here.
struct AgentProgressStatusReducer: Sendable {
    private struct SessionState: Sendable {
        var revision: UInt64 = 0
        var active = false
    }

    let agent: String
    private var sessions: [UUID: SessionState] = [:]

    init(agent: String) {
        self.agent = agent
    }

    mutating func consume(_ event: PluginSessionEvent) -> PluginWireMessage.Body? {
        switch event.kind {
        case .opened:
            sessions[event.session.id] = SessionState()
            return nil

        case .closed:
            guard var state = sessions.removeValue(forKey: event.session.id) else { return nil }
            state.revision += 1
            return .clearSessionStatus(.init(
                sessionID: event.session.id,
                revision: state.revision
            ))

        case .progressChanged:
            return progressChanged(event.session)

        case .titleChanged, .foregroundProcessChanged, .focusChanged:
            return nil
        }
    }

    private mutating func progressChanged(_ session: PluginSessionSnapshot) -> PluginWireMessage.Body? {
        var state = sessions[session.id] ?? SessionState()
        state.revision += 1

        guard let progress = session.progress else {
            guard state.active else {
                sessions[session.id] = state
                return nil
            }
            state.active = false
            sessions[session.id] = state
            return .setSessionStatus(.init(
                sessionID: session.id,
                revision: state.revision,
                status: .init(agent: agent, title: nil, state: .completed),
                ttlMilliseconds: 15_000
            ))
        }

        let statusState: PluginSessionStatus.State
        let ttlMilliseconds: UInt64?
        switch progress.state {
        case .set, .indeterminate:
            state.active = true
            statusState = .running
            ttlMilliseconds = nil
        case .pause:
            state.active = true
            statusState = .waiting
            ttlMilliseconds = nil
        case .error:
            state.active = false
            statusState = .failed
            ttlMilliseconds = 30_000
        }
        sessions[session.id] = state

        return .setSessionStatus(.init(
            sessionID: session.id,
            revision: state.revision,
            status: .init(agent: agent, title: nil, state: statusState),
            ttlMilliseconds: ttlMilliseconds
        ))
    }
}

@MainActor
final class MockAgentStatusAdapter {
    static let pluginID = "dev.oh-my-ghostty.mock-agent"

    private let store: TabActivityStore
    private var revisions: [UUID: UInt64] = [:]

    init(store: TabActivityStore) {
        self.store = store
    }

    @discardableResult
    func report(
        sessionID: UUID,
        state: TabActivityState,
        message: String? = nil
    ) -> PluginProtocolFailure? {
        let revision = (revisions[sessionID] ?? 0) + 1
        revisions[sessionID] = revision

        if state == .idle {
            return store.clear(
                .init(sessionID: sessionID, revision: revision),
                pluginID: Self.pluginID
            )
        }

        let wireState: PluginSessionStatus.State = switch state {
        case .idle: .completed
        case .working: .running
        case .done: .completed
        case .needsAttention: .waiting
        case .error: .failed
        }
        return store.set(
            .init(
                sessionID: sessionID,
                revision: revision,
                status: .init(
                    agent: "mock",
                    title: "Mock Agent",
                    state: wireState,
                    message: message,
                    icon: .init(kind: .systemSymbol, name: "bolt.fill")
                ),
                ttlMilliseconds: state == .done ? 15_000 : nil
            ),
            pluginID: Self.pluginID,
            sessionExists: { $0 == sessionID }
        )
    }
}

extension TabActivityState {
    var titleMarker: String {
        switch self {
        case .idle: ""
        case .working: "⏳"
        case .done: "✓"
        case .needsAttention: "⚠️"
        case .error: "✕"
        }
    }
}

extension PluginSessionStatus.State {
    var titleMarker: String {
        switch self {
        case .running: "⏳"
        case .waiting: "⚠️"
        case .completed: "✓"
        case .failed: "✕"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "hourglass"
        case .waiting: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
