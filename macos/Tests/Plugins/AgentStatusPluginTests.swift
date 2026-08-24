import Foundation
import Testing
@testable import Ghostty

struct AgentStatusPluginTests {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func mapsTypedContextSignalsForEverySupportedAgent() throws {
        for agent in SupportedAgent.allCases {
            var reducer = AgentContextSignalReducer()
            let idleUpdate = reducer.consume(signal(
                agent: agent,
                state: "idle"
            ))
            let idle = try #require(idleUpdate)
            guard case .set(let idleActivity) = idle else {
                Issue.record("Expected idle activity for \(agent.rawValue)")
                continue
            }
            #expect(idleActivity.source == agent.rawValue)
            #expect(idleActivity.state == .idle)
            #expect(idleActivity.icon == agent.icon)

            let waitingUpdate = reducer.consume(signal(
                agent: agent,
                state: "needsAttention"
            ))
            let waiting = try #require(waitingUpdate)
            guard case .set(let waitingActivity) = waiting else {
                Issue.record("Expected waiting activity for \(agent.rawValue)")
                continue
            }
            #expect(waitingActivity.state == .needsAttention)

            let clearUpdate = reducer.consume(.init(
                action: .end,
                id: "omg-agent-\(agent.rawValue)",
                metadata: "type=app;omg_agent=\(agent.rawValue)"
            ))
            let cleared = try #require(clearUpdate)
            #expect(cleared == .clear)
        }
    }

    @Test func normalizesAgentOwnedTerminalTitleDecoration() {
        #expect(SupportedAgent.claude.normalizedTitle("✳ Claude Code") == "Claude Code")
        #expect(SupportedAgent.codex.normalizedTitle("~/code") == "~/code")
        #expect(SupportedAgent.pi.normalizedTitle("π - project") == "project")
        #expect(SupportedAgent.pi.normalizedTitle("project") == "project")
    }

    @Test func staleAgentEndDoesNotClearNewAgent() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(agent: .codex, state: "working"))
        _ = reducer.consume(signal(agent: .claude, state: "working"))
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-codex",
            metadata: "type=app;omg_agent=codex"
        )) == nil)
        guard case .set(let done) = reducer.consume(signal(
            agent: .claude,
            state: "done"
        )) else {
            Issue.record("Expected Claude to remain active")
            return
        }
        #expect(done.source == "claude")
        #expect(done.state == .done)
    }

    @Test func nestedAgentEndRestoresPreviousAgent() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(agent: .codex, state: "working"))
        _ = reducer.consume(signal(agent: .pi, state: "working"))
        let update = reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi",
            metadata: "type=app;omg_agent=pi"
        ))
        guard case .set(let restored) = update else {
            Issue.record("Expected parent agent activity to be restored")
            return
        }
        #expect(restored.source == "codex")
        #expect(restored.state == .working)
    }

    @Test func hookInstallerPreservesExistingCodexAndClaudeHooks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHooks = home.appendingPathComponent(".codex/hooks.json")
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: codexHooks.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [[
                    "_otty": true,
                    "hooks": [["type": "command", "command": "otty state"]],
                ]],
            ],
            "preserved": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: codexHooks)
        try data.write(to: claudeSettings)
        try "[features]\nother = true\n".write(
            to: home.appendingPathComponent(".codex/config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        try installer.install(.claude)
        #expect(installer.isInstalled(.codex))
        #expect(installer.isInstalled(.claude))
        #expect(FileManager.default.fileExists(
            atPath: codexHooks.appendingPathExtension("omg-backup").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: claudeSettings.appendingPathExtension("omg-backup").path
        ))

        for url in [codexHooks, claudeSettings] {
            let root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            #expect(root["preserved"] as? Bool == true)
            let hooks = try #require(root["hooks"] as? [String: Any])
            let starts = try #require(hooks["SessionStart"] as? [[String: Any]])
            #expect(starts.contains { $0["_otty"] as? Bool == true })
            let omgEntry = try #require(starts.first { entry in
                guard let hooks = entry["hooks"] as? [[String: Any]] else {
                    return false
                }
                return hooks.contains {
                    ($0["command"] as? String)?.contains(
                        AgentHookInstaller.marker
                    ) == true
                }
            })
            let commands = try #require(omgEntry["hooks"] as? [[String: Any]])
            let command = try #require(commands.first?["command"] as? String)
            #expect(command.contains("omg_state=idle"))
            #expect(command.contains("ps -o tty= -p \"$PPID\""))
            #expect(command.contains("> \"/dev/$omg_tty\""))
        }
        let config = try String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        #expect(config.contains("hooks = true"))
        #expect(config.contains("other = true"))

        try installer.uninstall(.codex)
        #expect(!installer.isInstalled(.codex))
        let restored = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: codexHooks)) as? [String: Any]
        )
        let restoredHooks = try #require(restored["hooks"] as? [String: Any])
        let restoredStarts = try #require(
            restoredHooks["SessionStart"] as? [[String: Any]]
        )
        #expect(restoredStarts.count == 1)
        #expect(restoredStarts[0]["_otty"] as? Bool == true)
    }

    @Test func installsAuditablePiExtension() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.pi)
        #expect(installer.isInstalled(.pi))
        let source = try String(
            contentsOf: home.appendingPathComponent(
                ".pi/agent/extensions/omg-agent-status.ts"
            ),
            encoding: .utf8
        )
        #expect(source.contains("marker: \(AgentHookInstaller.marker)"))
        #expect(source.contains("agent_settled"))
        #expect(source.contains("ask_user_question"))
        try installer.uninstall(.pi)
        #expect(!installer.isInstalled(.pi))
    }

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

    private func signal(
        agent: SupportedAgent,
        state: String
    ) -> Ghostty.ContextSignal {
        .init(
            action: .start,
            id: "omg-agent-\(agent.rawValue)",
            metadata: "type=app;omg_agent=\(agent.rawValue);omg_state=\(state)"
        )
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
