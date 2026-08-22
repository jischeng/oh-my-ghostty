import Foundation
import Testing
@testable import Ghostty

struct AgentStatusPluginTests {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func mapsProgressLifecycleToSessionStatus() throws {
        var reducer = AgentProgressStatusReducer(agent: "Codex")
        #expect(reducer.consume(event(.opened, progress: nil)) == nil)

        let running = try #require(setCommand(from: reducer.consume(
            event(.progressChanged, progress: .init(state: .indeterminate, percent: nil))
        )))
        #expect(running.status.state == .running)
        #expect(running.revision == 1)
        #expect(running.ttlMilliseconds == nil)

        let waiting = try #require(setCommand(from: reducer.consume(
            event(.progressChanged, progress: .init(state: .pause, percent: nil))
        )))
        #expect(waiting.status.state == .waiting)
        #expect(waiting.revision == 2)

        let completed = try #require(setCommand(from: reducer.consume(
            event(.progressChanged, progress: nil)
        )))
        #expect(completed.status.state == .completed)
        #expect(completed.revision == 3)
        #expect(completed.ttlMilliseconds == 15_000)
    }

    @Test func errorHasTTLAndDoesNotBecomeCompletedOnRemoval() throws {
        var reducer = AgentProgressStatusReducer(agent: "Pi")
        _ = reducer.consume(event(.opened, progress: nil))

        let failed = try #require(setCommand(from: reducer.consume(
            event(.progressChanged, progress: .init(state: .error, percent: 20))
        )))
        #expect(failed.status.state == .failed)
        #expect(failed.ttlMilliseconds == 30_000)
        #expect(reducer.consume(event(.progressChanged, progress: nil)) == nil)
    }

    @Test @MainActor func mockAdapterUsesStableSessionIdentity() {
        let otherSession = UUID()
        let store = TabActivityStore()
        let adapter = MockAgentStatusAdapter(store: store)

        #expect(adapter.report(
            sessionID: sessionID,
            state: .working,
            message: "Running tests"
        ) == nil)
        #expect(store.activity(for: sessionID)?.state == .working)
        #expect(store.activity(for: sessionID)?.icon?.name == "bolt.fill")
        #expect(store.activity(for: otherSession) == nil)

        #expect(adapter.report(sessionID: sessionID, state: .needsAttention) == nil)
        #expect(store.activity(for: sessionID)?.state == .needsAttention)
        #expect(adapter.report(sessionID: sessionID, state: .done) == nil)
        #expect(store.activity(for: sessionID)?.state == .done)
        #expect(adapter.report(sessionID: sessionID, state: .idle) == nil)
        #expect(store.activity(for: sessionID) == nil)
    }

    @Test func closingTrackedSessionClearsStatusWithNextRevision() throws {
        var reducer = AgentProgressStatusReducer(agent: "Codex")
        _ = reducer.consume(event(.opened, progress: nil))
        _ = reducer.consume(event(.progressChanged, progress: .init(state: .set, percent: 10)))

        let result = reducer.consume(event(.closed, progress: nil))
        let body = try #require(result)
        guard case .clearSessionStatus(let clear) = body else {
            Issue.record("Expected clearSessionStatus")
            return
        }
        #expect(clear.sessionID == sessionID)
        #expect(clear.revision == 2)
    }

    private func event(
        _ kind: PluginSessionEvent.Kind,
        progress: PluginTerminalProgress?
    ) -> PluginSessionEvent {
        .init(
            kind: kind,
            session: .init(
                id: sessionID,
                title: "session",
                foregroundPID: 42,
                progress: progress,
                isFocused: true
            )
        )
    }

    private func setCommand(
        from body: PluginWireMessage.Body?
    ) -> PluginSetSessionStatus? {
        guard case .setSessionStatus(let command) = body else { return nil }
        return command
    }
}
