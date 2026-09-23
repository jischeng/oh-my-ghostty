import Foundation
import Testing
@testable import Ghostty

@MainActor
struct PaneAgentHistoryServiceTests {
    private actor Resolver {
        var calls = 0
        let sessions: [String: AgentHistorySession]
        let delay: Duration
        init(sessions: [String: AgentHistorySession], delay: Duration = .zero) {
            self.sessions = sessions
            self.delay = delay
        }
        func resolve(_ binding: PaneAgentHistoryService.Binding) async -> AgentHistorySession? {
            calls += 1
            try? await Task.sleep(for: delay)
            return sessions[binding.conversationID.rawValue]
        }
    }

    private func fixture(_ text: String) throws -> AgentHistorySession {
        let id = UUID().uuidString
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("omg-prompt-test-\(id).jsonl")
        var data = try JSONSerialization.data(withJSONObject: ["role": "user", "content": text])
        data.append(10)
        try data.write(to: path)
        return .init(agent: .claude, conversationID: try #require(AgentConversationID(id)), title: "test",
                     workingDirectory: nil, updatedAt: Date(), sourcePath: path.path, isActive: true)
    }

    private func binding(_ session: AgentHistorySession) -> PaneAgentHistoryService.Binding {
        .init(agent: session.agent, conversationID: session.conversationID, remoteHost: nil, connectionID: nil)
    }

    @Test func bindingRequiresTheCurrentHostAndExecutionScope() throws {
        let id = try #require(AgentConversationID(UUID().uuidString))
        var session = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "shell")
        let local = AgentResumeDescriptor(agent: .claude, conversationID: id, scope: .local, workingDirectory: "/tmp")
        let remote = AgentResumeDescriptor(agent: .claude, conversationID: id, scope: .remote, workingDirectory: "/tmp",
            sshReplay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false, args: ["host-A"]))
        #expect(PaneAgentHistoryService.Binding.current(descriptor: local, session: session) != nil)
        #expect(PaneAgentHistoryService.Binding.current(descriptor: remote, session: session) == nil)
        session.apply(.init(action: .start, id: "omg-ssh-1", metadata: "type=remote;targethost=host-A;cwd=/tmp"),
                      currentWorkingDirectory: "/tmp", currentTerminalTitle: "remote")
        #expect(PaneAgentHistoryService.Binding.current(descriptor: local, session: session) == nil)
        #expect(PaneAgentHistoryService.Binding.current(descriptor: remote, session: session)?.connectionID == "omg-ssh-1")
        session.apply(.init(action: .start, id: "omg-ssh-2", metadata: "type=remote;targethost=host-B;cwd=/tmp"),
                      currentWorkingDirectory: "/tmp", currentTerminalTitle: "remote")
        #expect(PaneAgentHistoryService.Binding.current(descriptor: remote, session: session) == nil)
    }

    @Test func resolvesOnceAndCancelsHiddenPaneSubscriptions() async throws {
        let session = try fixture("full prompt")
        defer { try? FileManager.default.removeItem(atPath: session.sourcePath) }
        let resolver = Resolver(sessions: [session.conversationID.rawValue: session])
        let service = PaneAgentHistoryService(interval: .milliseconds(5)) { await resolver.resolve($0) }
        let surface = UUID()
        var updates = 0
        let initial = service.observe(surfaceID: surface, binding: binding(session)) { updates += 1 }
        #expect(initial.state == .loading)
        for _ in 0..<100 where updates == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let loaded = service.observe(surfaceID: surface, binding: binding(session)) { updates += 1 }
        #expect(loaded.items.map(\.text) == ["full prompt"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await resolver.calls == 1)
        #expect(updates == 1) // unchanged source does not reload the table
        service.retain(surfaces: [])
        let before = updates
        try await Task.sleep(for: .milliseconds(30))
        #expect(updates == before)
    }

    @Test func lateResultCannotPublishIntoReplacementSessionOrAnotherPane() async throws {
        let first = try fixture("old session")
        let second = try fixture("new session")
        defer {
            try? FileManager.default.removeItem(atPath: first.sourcePath)
            try? FileManager.default.removeItem(atPath: second.sourcePath)
        }
        let resolver = Resolver(sessions: [first.conversationID.rawValue: first, second.conversationID.rawValue: second],
                                delay: .milliseconds(20))
        let service = PaneAgentHistoryService(interval: .milliseconds(10)) { await resolver.resolve($0) }
        let pane = UUID()
        let otherPane = UUID()
        var oldUpdates = 0
        var newUpdates = 0
        var otherUpdates = 0
        _ = service.observe(surfaceID: pane, binding: binding(first)) { oldUpdates += 1 }
        await Task.yield()
        _ = service.observe(surfaceID: pane, binding: binding(second)) { newUpdates += 1 }
        _ = service.observe(surfaceID: otherPane, binding: binding(first)) { otherUpdates += 1 }
        for _ in 0..<100 where newUpdates == 0 || otherUpdates == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(oldUpdates == 0)
        #expect(service.observe(surfaceID: pane, binding: binding(second), changed: {}).items.map(\.text) == ["new session"])
        #expect(service.observe(surfaceID: otherPane, binding: binding(first), changed: {}).items.map(\.text) == ["old session"])
        service.shutdown()
    }
}
