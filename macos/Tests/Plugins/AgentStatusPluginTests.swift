import AppKit
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
            #expect(idleActivity.icon?.kind == .bundledAsset)
            #expect(idleActivity.icon?.name == agent.assetName)

            let waitingUpdate = reducer.consume(signal(
                agent: agent,
                state: "needsAttention",
                attention: .permission
            ))
            let waiting = try #require(waitingUpdate)
            guard case .set(let waitingActivity) = waiting else {
                Issue.record("Expected waiting activity for \(agent.rawValue)")
                continue
            }
            #expect(waitingActivity.state == .needsAttention)
            #expect(waitingActivity.attentionKind == .permission)

            let clearUpdate = reducer.consume(.init(
                action: .end,
                id: "omg-agent-\(agent.rawValue)",
                metadata: "type=app;omg_agent=\(agent.rawValue)"
            ))
            let cleared = try #require(clearUpdate)
            #expect(cleared == .clear)
        }
    }

    @Test func bundledAgentCatalogDefinesHooksAndResume() {
        let expected: [SupportedAgent: (String, String, Int)] = [
            .codex: ("codex", "AgentOpenAI", 7),
            .claude: ("claude", "AgentClaude", 8),
            .pi: ("pi", "AgentPi", 7),
            .qoder: ("qodercli", "AgentQoder", 7),
            .reasonix: ("reasonix", "AgentReasonix", 8),
            .omp: ("omp", "AgentOMP", 4),
            .opencode: ("opencode", "AgentOpenCode", 4),
            .amp: ("amp", "AgentAmp", 2),
            .antigravity: ("agy", "AgentAntigravity", 0),
            .cline: ("cline", "AgentCline", 7),
            .copilot: ("copilot", "AgentCopilot", 5),
            .crush: ("crush", "AgentCrush", 0),
            .cursor: ("cursor-agent", "AgentCursor", 5),
            .droid: ("droid", "AgentDroid", 5),
            .grok: ("grok", "AgentGrok", 5),
            .hermes: ("hermes", "AgentHermes", 0),
            .kimi: ("kimi", "AgentKimi", 3),
            .qwen: ("qwen", "AgentQwen", 5),
        ]
        for agent in SupportedAgent.allCases {
            let definition = agent.definition
            let value = expected[agent]
            #expect(definition.id == agent.rawValue)
            #expect(definition.command == value?.0)
            #expect(definition.iconAsset == value?.1)
            #expect(definition.hook.events.count == value?.2)
        }
        #expect(SupportedAgent.codex.definition.resume.discover != nil)
        #expect(SupportedAgent.claude.definition.resume.store != nil)
        #expect(SupportedAgent.pi.definition.resume.seed == "pi-session-file")
        #expect(SupportedAgent.codex.definition.hook.conversationField == "session_id")
        #expect(SupportedAgent.claude.definition.hook.transcriptField == "transcript_path")
    }

    @Test func buildsOnlyAllowlistedAgentResumeCommands() throws {
        let conversation = try #require(AgentConversationID("019f-test_session"))
        let codex = AgentResumeDescriptor(
            agent: .codex,
            conversationID: conversation,
            scope: .local,
            workingDirectory: "/tmp/project"
        )
        let command = try #require(codex.restorationCommand(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg",
            verifyLocalStore: false
        ))
        #expect(command.contains("'codex' 'resume' '019f-test_session'"))
        #expect(command.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
        let remote = AgentResumeDescriptor(
            agent: .pi,
            conversationID: conversation,
            scope: .remote,
            workingDirectory: "/home/user/project",
            sshReplay: .init(
                version: 1,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: true,
                cache: true,
                args: ["cloud"]
            )
        )
        let remoteCommand = try #require(remote.restorationCommand(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(remoteCommand.contains("--remote-agent=pi"))
        #expect(remoteCommand.contains("--remote-agent-session=019f-test_session"))
        #expect(remoteCommand.contains("--remote-working-directory=/home/user/project"))
        let encoded = try JSONEncoder().encode(remote)
        #expect(try JSONDecoder().decode(
            AgentResumeDescriptor.self,
            from: encoded
        ) == remote)
        let expectedResumeFragments: [SupportedAgent: String] = [
            .claude: "'claude' '--resume' '019f-test_session'",
            .qoder: "'qodercli' '--resume' '019f-test_session'",
            .reasonix: "'reasonix' '--resume' '019f-test_session'",
            .omp: "'omp' '--resume=019f-test_session'",
            .opencode: "'opencode' '--session' '019f-test_session'",
            .grok: "'grok' '--resume' '019f-test_session'",
            .qwen: "'qwen' '--resume' '019f-test_session'",
        ]
        for (agent, fragment) in expectedResumeFragments {
            let descriptor = AgentResumeDescriptor(
                agent: agent,
                conversationID: conversation,
                scope: .local,
                workingDirectory: "/tmp/project"
            )
            let command = try #require(descriptor.restorationCommand(
                executablePath: "/Applications/OMG.app/Contents/MacOS/omg",
                verifyLocalStore: false
            ))
            #expect(command.contains(fragment))
        }
        #expect(AgentConversationID("bad session") == nil)
        #expect(AgentConversationID("../escape") == nil)
    }

    @Test func extractsValidatedConversationIdentityFromContextSignal() throws {
        let update = AgentContextSignalReducer.sessionSignal(from: .init(
            action: .start,
            id: "omg-agent-codex-42",
            metadata: "type=app;omg_agent=codex;omg_scope=local;" +
                "omg_state=working;omg_conversation=019f-test_session"
        ))
        let signal = try #require(update)
        #expect(signal.agent == .codex)
        #expect(signal.scope == .local)
        #expect(signal.conversationID?.rawValue == "019f-test_session")
    }

    @Test func discoversExactConversationFromBoundedSessionStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexFile = root.appendingPathComponent("2026/08/25/rollout.jsonl")
        try FileManager.default.createDirectory(
            at: codexFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": "019f-codex", "cwd": "/tmp/project"],
        ]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0A)
        try data.write(to: codexFile)
        #expect(AgentConversationStore.discover(
            agent: .codex,
            workingDirectory: "/tmp/project",
            launchedAfter: Date().addingTimeInterval(-1),
            rootURL: root
        )?.rawValue == "019f-codex")
        let knownID = try #require(AgentConversationID("019f-codex"))
        #expect(AgentConversationStore.contains(
            agent: .codex,
            conversationID: knownID,
            rootURL: root
        ))

        let second = root.appendingPathComponent("2026/08/25/second.jsonl")
        let secondRecord: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": "019f-other", "cwd": "/tmp/project"],
        ]
        var secondData = try JSONSerialization.data(withJSONObject: secondRecord)
        secondData.append(0x0A)
        try secondData.write(to: second)
        #expect(AgentConversationStore.discover(
            agent: .codex,
            workingDirectory: "/tmp/project",
            launchedAfter: Date().addingTimeInterval(-1),
            rootURL: root
        ) == nil)
    }

    @Test func appliesManifestScreenStatusRules() {
        let definition = SupportedAgent.crush.definition
        #expect(AgentScreenStatusDetector.detect(
            definition: definition,
            screen: "Permission Required: Allow for Session"
        ) == .needsAttention)
        #expect(AgentScreenStatusDetector.detect(
            definition: definition,
            screen: "Thinking..."
        ) == .working)
        #expect(AgentScreenStatusDetector.detect(
            definition: definition,
            screen: "Ready"
        ) == .idle)
        #expect(AgentScreenStatusDetector.detect(
            status: SupportedAgent.grok.definition.titleStatus,
            text: "Action Required"
        ) == .needsAttention)
        #expect(AgentScreenStatusDetector.detect(
            status: SupportedAgent.qwen.definition.titleStatus,
            text: "◐ Thinking"
        ) == .working)
    }

    @Test func detectsLocalAgentForegroundCommandsWithoutFalseArguments() {
        for agent in SupportedAgent.allCases {
            let command = agent.definition.command
            #expect(LocalAgentProcessDetector.detect(
                in: "/Users/test/.local/bin/\(command)\n"
            ) == agent)
        }
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.local/bin/codex --model gpt-5\n"
        ) == .codex)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/bin/login -flp test claude\n/usr/local/bin/claude\n"
        ) == .claude)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/local/bin/node /opt/pi-coding-agent/dist/cli.js\n"
        ) == .pi)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/local/bin/node /opt/claude-code/cli.js\n"
        ) == .claude)
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.local/bin/qodercli\n"
        ) == .qoder)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/local/bin/reasonix\n"
        ) == .reasonix)
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.local/bin/omp\n"
        ) == .omp)
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.opencode/bin/opencode\n"
        ) == .opencode)
        #expect(LocalAgentProcessDetector.detect(
            in: "/bin/cat pi\n"
        ) == nil)
    }

    @Test @MainActor func bundledAgentAssetsRenderVisiblePixels() throws {
        for agent in SupportedAgent.allCases {
            let image = try #require(NSImage(named: agent.assetName))
            if ![.reasonix, .crush, .droid, .hermes].contains(agent) {
                #expect(image.isTemplate)
            }
            #expect(renderedPixelCount(image) > 100)
        }
    }

    @Test func distinguishesQuestionFromPermissionAttention() throws {
        var reducer = AgentContextSignalReducer()
        guard case .set(let question) = reducer.consume(signal(
            agent: .pi,
            state: "needsAttention",
            attention: .question
        )) else {
            Issue.record("Expected question activity")
            return
        }
        #expect(question.attentionKind == .question)
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

    @Test func localForegroundExitHonorsStartupGraceThenClears() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 300
        ))
        #expect(reducer.requiresForegroundValidation)
        #expect(reducer.reconcileLocalForegroundProcess(300) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(301) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(
            301,
            processGroupIsAlive: true,
            now: Date().addingTimeInterval(10)
        ) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(
            301,
            processGroupIsAlive: false,
            now: Date().addingTimeInterval(10)
        ) == .clear)
        #expect(!reducer.requiresForegroundValidation)
    }

    @Test func acknowledgingCompletionRestoresIdleIdentity() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(agent: .codex, state: "done"))
        guard case .set(let activity) = reducer.acknowledgeCompletion() else {
            Issue.record("Expected completion acknowledgement")
            return
        }
        #expect(activity.state == .idle)
        #expect(activity.icon == SupportedAgent.codex.icon)
        #expect(activity.progress == nil)
        #expect(reducer.acknowledgeCompletion() == nil)
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
                "Stop": [[
                    "matcher": "other-stop",
                    "hooks": [[
                        "type": "command",
                        "command": "preserve stop command verbatim",
                    ]],
                ]],
                "Notification": [[
                    "matcher": "other-notification",
                    "hooks": [[
                        "type": "command",
                        "command": "preserve notification command verbatim",
                    ]],
                ]],
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
            #expect(command.contains("omg_conversation=%s"))
            #expect(command.contains("session_id"))
            #expect(command.contains("> \"/dev/$omg_tty\""))
            try assertUnrelatedHooksPreserved(at: url)
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
        try assertUnrelatedHooksPreserved(at: codexHooks)

        try installer.uninstall(.claude)
        #expect(!installer.isInstalled(.claude))
        try assertUnrelatedHooksPreserved(at: claudeSettings)
    }

    @Test func oldOwnerVersionRequiresHookCommandUpgrade() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        let url = home.appendingPathComponent(".codex/hooks.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var hooks = try #require(root["hooks"] as? [String: Any])
        for key in hooks.keys {
            var entries = try #require(hooks[key] as? [[String: Any]])
            for index in entries.indices
            where entries[index][AgentHookInstaller.marker] as? Int ==
                AgentHookInstaller.hookVersion {
                entries[index][AgentHookInstaller.marker] = 3
                var commands = try #require(
                    entries[index]["hooks"] as? [[String: Any]]
                )
                for commandIndex in commands.indices {
                    let command = try #require(
                        commands[commandIndex]["command"] as? String
                    )
                    commands[commandIndex]["command"] = command.replacingOccurrences(
                        of: "_omg_agent_status_v4",
                        with: "_omg_agent_status_v3"
                    )
                }
                entries[index]["hooks"] = commands
            }
            hooks[key] = entries
        }
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        #expect(installer.installationState(.codex) == .updateAvailable)
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
            let expected: AgentHookInstallationState =
                agent.definition.hook.kind == .none ? .missing : .current
            #expect(installer.installationState(agent) == expected)
        }
        for path in [".cursor/hooks.json", ".copilot/hooks/omg.json"] {
            let root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf:
                    home.appendingPathComponent(path)
                )) as? [String: Any]
            )
            #expect(root["version"] as? Int == 1)
        }
        let reasonix = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf:
                home.appendingPathComponent(".reasonix/settings.json")
            )) as? [String: Any]
        )
        let reasonixHooks = try #require(reasonix["hooks"] as? [String: Any])
        let reasonixStart = try #require(
            reasonixHooks["SessionStart"] as? [[String: Any]]
        )
        #expect(reasonixStart.first?["command"] is String)
        #expect(reasonixStart.first?["hooks"] == nil)

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
        #expect(source.contains("sessionManager?.getSessionId"))
        #expect(source.contains("omg_conversation="))
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

    @MainActor
    private func renderedPixelCount(_ image: NSImage) -> Int {
        let size = 32
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return 0
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.draw(in: NSRect(x: 2, y: 2, width: size - 4, height: size - 4))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<size {
            for x in 0..<size where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }

    private func assertUnrelatedHooksPreserved(at url: URL) throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let hooks = try #require(root["hooks"] as? [String: Any])
        for (event, matcher, command) in [
            ("Stop", "other-stop", "preserve stop command verbatim"),
            (
                "Notification",
                "other-notification",
                "preserve notification command verbatim"
            ),
        ] {
            let entries = try #require(hooks[event] as? [[String: Any]])
            let entry = try #require(entries.first {
                $0["matcher"] as? String == matcher
            })
            let commands = try #require(entry["hooks"] as? [[String: Any]])
            #expect(commands.count == 1)
            #expect(commands[0]["command"] as? String == command)
        }
    }

    private func signal(
        agent: SupportedAgent,
        state: String,
        instance: Int? = nil,
        scope: String? = nil,
        attention: TabAttentionKind? = nil
    ) -> Ghostty.ContextSignal {
        let id = "omg-agent-\(agent.rawValue)" + (instance.map { "-\($0)" } ?? "")
        var metadata = "type=app;omg_agent=\(agent.rawValue);omg_state=\(state)"
        if let scope = scope ?? (instance == nil ? nil : "local") {
            metadata += ";omg_scope=\(scope)"
        }
        if let attention { metadata += ";omg_attention=\(attention.rawValue)" }
        return .init(action: .start, id: id, metadata: metadata)
    }
}
