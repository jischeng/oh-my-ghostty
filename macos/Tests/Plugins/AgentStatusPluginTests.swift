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

    @Test func staleSameAgentEndDoesNotClearNewInstance() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .codex,
            state: "working",
            instance: 100
        ))
        _ = reducer.consume(signal(
            agent: .codex,
            state: "working",
            instance: 200
        ))
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-codex-100",
            metadata: "type=app;omg_agent=codex;omg_scope=local"
        )) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(200) == nil)
    }

    @Test func localForegroundExitClearsAgent() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 300
        ))
        #expect(reducer.requiresForegroundValidation)
        #expect(reducer.reconcileLocalForegroundProcess(300) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(301) == .clear)
        #expect(!reducer.requiresForegroundValidation)
    }

    @Test func remotePromptClearsOrphanedAgent() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .claude,
            state: "working",
            instance: 400,
            scope: "remote"
        ))
        let update = reducer.consumeRemotePrompt(.init(
            action: .start,
            id: "omg-ssh-remote-test",
            metadata: "type=remote;targethost=cloud;cwd=%2Ftmp"
        ))
        #expect(update == .clear)
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

    @Test func backgroundAttentionOutranksFocusedWorkingActivity() throws {
        var reducer = AgentContextSignalReducer()
        guard case .set(let working) = reducer.consume(signal(
            agent: .codex,
            state: "working"
        )), case .set(let attention) = reducer.consume(signal(
            agent: .claude,
            state: "needsAttention"
        )) else {
            Issue.record("Expected normalized activities")
            return
        }
        let preferred = AgentActivitySelection.preferred([
            .init(activity: working, isFocused: true),
            .init(activity: attention, isFocused: false),
        ])
        #expect(preferred == attention)
        guard case .set(let claudeWorking) = reducer.consume(signal(
            agent: .claude,
            state: "working"
        )) else {
            Issue.record("Expected focused activity")
            return
        }
        let focusedTie = AgentActivitySelection.preferred([
            .init(activity: working, isFocused: false),
            .init(activity: claudeWorking, isFocused: true),
        ])
        #expect(focusedTie == claudeWorking)
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
                "SessionStart": [
                    [
                        "_otty": true,
                        "hooks": [["type": "command", "command": "otty state"]],
                    ],
                    [
                        "matcher": "legacy-shared-entry",
                        "hooks": [
                            [
                                "type": "command",
                                "command": ": _omg_agent_status; old hook",
                            ],
                            ["type": "command", "command": "keep shared hook"],
                        ],
                    ],
                ],
            ],
            "preserved": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: codexHooks)
        try data.write(to: claudeSettings)
        try "[features]\nhooks=true\nother = true\n".write(
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
            let sharedEntry = try #require(starts.first {
                $0["matcher"] as? String == "legacy-shared-entry"
            })
            let sharedCommands = try #require(
                sharedEntry["hooks"] as? [[String: Any]]
            )
            #expect(sharedCommands.count == 1)
            #expect(sharedCommands[0]["command"] as? String == "keep shared hook")
            let omgEntry = try #require(starts.first { entry in
                entry[AgentHookInstaller.marker] as? Int ==
                    AgentHookInstaller.hookVersion
            })
            let commands = try #require(omgEntry["hooks"] as? [[String: Any]])
            let command = try #require(commands.first?["command"] as? String)
            #expect(command.contains("omg_state=idle"))
            #expect(command.contains("ps -o tty= -p \"$PPID\""))
            #expect(command.contains("ps -o pgid= -p \"$PPID\""))
            #expect(command.contains("omg-agent-\(url == codexHooks ? "codex" : "claude")-%s"))
            #expect(command.contains("omg_scope=%s"))
            #expect(command.contains("> \"/dev/$omg_tty\""))
        }
        let config = try String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        #expect(config.contains("hooks = true"))
        #expect(!config.contains("hooks=true"))
        #expect(config.components(separatedBy: "hooks").count == 2)
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
        #expect(restoredStarts.count == 2)
        #expect(restoredStarts.contains { $0["_otty"] as? Bool == true })
        let preservedShared = try #require(restoredStarts.first {
            $0["matcher"] as? String == "legacy-shared-entry"
        })
        let preservedCommands = try #require(
            preservedShared["hooks"] as? [[String: Any]]
        )
        #expect(preservedCommands.count == 1)
        #expect(preservedCommands[0]["command"] as? String == "keep shared hook")
    }

    @Test func refusesMalformedHooksWithoutOverwriting() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let hooksURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = #"{"hooks":{"SessionStart":"do not replace"}}"#
        try original.write(to: hooksURL, atomically: true, encoding: .utf8)

        #expect(throws: AgentHookInstallerError.self) {
            try AgentHookInstaller(homeURL: home).install(.claude)
        }
        #expect(try String(contentsOf: hooksURL, encoding: .utf8) == original)
    }

    @Test func validatesCodexHooksBeforeChangingFeatureFlag() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true
        )
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let originalConfig = "[features]\nhooks = false\n"
        try originalConfig.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        try #"{"hooks":{"SessionStart":"invalid"}}"#.write(
            to: hooksURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: AgentHookInstallerError.self) {
            try AgentHookInstaller(homeURL: home).install(.codex)
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
    }

    @Test func refusesDuplicateCodexHooksSettingBeforeWritingHooks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true
        )
        try "[features]\nhooks=true\nhooks = false\n".write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: AgentHookInstallerError.self) {
            try AgentHookInstaller(homeURL: home).install(.codex)
        }
        #expect(!FileManager.default.fileExists(
            atPath: codexDirectory.appendingPathComponent("hooks.json").path
        ))
    }

    @Test func exportedRemoteInstallerProducesCurrentHooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let scriptURL = root.appendingPathComponent("omg-agent-hooks.py")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try AgentHookInstaller.remoteInstallerScript().write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: message))

        let installer = AgentHookInstaller(homeURL: home)
        for agent in SupportedAgent.allCases {
            #expect(installer.installationState(agent) == .current)
        }
        let remotePi = home.appendingPathComponent(
            ".pi/agent/extensions/omg-agent-status.ts"
        )
        let remoteMode = try #require(
            FileManager.default.attributesOfItem(atPath: remotePi.path)[
                .posixPermissions
            ] as? NSNumber
        )
        #expect(remoteMode.intValue == 0o600)
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
        #expect(source.contains("omg-agent-pi-${process.pid}"))
        #expect(source.contains("process.env.SSH_CONNECTION"))
        #expect(source.contains("agent_settled"))
        #expect(source.contains("ask_user_question"))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(
                ".pi/agent/extensions/omg-agent-status.ts"
            ).path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
        try installer.uninstall(.pi)
        #expect(!installer.isInstalled(.pi))
    }

    private func signal(
        agent: SupportedAgent,
        state: String,
        instance: Int? = nil,
        scope: String? = nil
    ) -> Ghostty.ContextSignal {
        let id = "omg-agent-\(agent.rawValue)" + (instance.map { "-\($0)" } ?? "")
        var metadata = "type=app;omg_agent=\(agent.rawValue);omg_state=\(state)"
        if let scope = scope ?? (instance == nil ? nil : "local") {
            metadata += ";omg_scope=\(scope)"
        }
        return .init(action: .start, id: id, metadata: metadata)
    }
}
