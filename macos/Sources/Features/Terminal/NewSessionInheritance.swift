import Foundation

/// What a new tab or split carries over from the focused pane (#42). Levels
/// are cumulative: an Agent level also keeps the SSH connection, which in turn
/// keeps the (remote) working directory. Ghostty's `tab/split-inherit-working-
/// directory` remain authoritative for the directory itself; when they are off
/// the inherited directory is already absent and the pane uses the default.
enum NewSessionInheritance: String, CaseIterable, Identifiable, Sendable {
    /// Local shell in Ghostty's configured default directory.
    case defaultDirectory = "default"
    /// Local shell in the focused pane's local directory (the pre-SSH
    /// directory when the pane is connected over SSH).
    case workingDirectory = "directory"
    /// Same SSH host and remote directory when the pane is connected.
    case ssh
    /// Start a new conversation of the focused pane's Agent.
    case agentNewSession = "agent"
    /// Resume the focused pane's Agent conversation by ID. Two live processes
    /// then append to one transcript without seeing each other's turns.
    case agentResume

    enum Entry: Sendable { case tab, split }

    var id: String { rawValue }
    var inheritsSSH: Bool { self == .ssh || inheritsAgent }
    var inheritsAgent: Bool { self == .agentNewSession || self == .agentResume }

    /// Defaults preserve the behavior before this setting existed.
    static func defaultValue(for entry: Entry) -> Self {
        switch entry {
        case .tab: .workingDirectory
        case .split: .ssh
        }
    }

    @MainActor
    static func current(for entry: Entry, settings: OhMyGhosttySettings = .shared) -> Self {
        switch entry {
        case .tab: settings.newTabInheritance
        case .split: settings.newSplitInheritance
        }
    }

    /// Host-validated launch for an inherited Agent.
    struct AgentLaunch: Equatable, Sendable {
        let descriptor: AgentResumeDescriptor
        let command: String
    }

    /// An SSH pane's exact replay and its current remote directory.
    struct Remote: Equatable, Sendable {
        let replay: SSHReplayDescriptor
        let workingDirectory: String?
    }

    /// Builds the Agent launch for an Agent level. Remote panes require an
    /// exact SSH replay; resume requires a conversation ID and an Agent with
    /// resume arguments, otherwise a new conversation starts.
    static func agentLaunch(
        level: Self,
        agent: SupportedAgent,
        conversationID: AgentConversationID?,
        remote: Remote?,
        localWorkingDirectory: String?,
        executablePath: String,
        includeLocalWorkingDirectoryInCommand: Bool = true
    ) -> AgentLaunch? {
        guard level.inheritsAgent else { return nil }
        let canResume = level == .agentResume && !agent.definition.resume.resumeArguments.isEmpty
        let resumedID = canResume ? conversationID : nil
        if let remote {
            let descriptor = AgentResumeDescriptor(
                agent: agent, conversationID: resumedID, scope: .remote,
                workingDirectory: remote.workingDirectory, sshReplay: remote.replay
            )
            guard descriptor.isValid,
                  let command = remote.replay.command(
                    executablePath: executablePath,
                    remoteWorkingDirectory: remote.workingDirectory,
                    remoteAgent: agent,
                    conversationID: resumedID,
                    includeLocalWorkingDirectory: includeLocalWorkingDirectoryInCommand
                  ) else { return nil }
            return .init(descriptor: descriptor, command: command)
        }
        let descriptor = AgentResumeDescriptor(
            agent: agent, conversationID: resumedID, scope: .local,
            workingDirectory: localWorkingDirectory
        )
        // The ID comes from the live source pane, as for an explicit history
        // resume, so skip the on-disk store probe.
        guard let command = descriptor.restorationCommand(executablePath: executablePath, verifyLocalStore: false)
        else { return nil }
        return .init(descriptor: descriptor, command: command)
    }

    /// Surface configuration that runs `launch` instead of a login shell. The
    /// survival wrapper leaves a usable local shell after the Agent/SSH exits.
    static func configuration(
        for launch: AgentLaunch,
        inherited config: Ghostty.SurfaceConfiguration?,
        localWorkingDirectory: String?,
        suppressInheritWorkingDirectory: Bool = false
    ) -> Ghostty.SurfaceConfiguration {
        var result = config ?? .init()
        for key in [SessionRuntimeDescriptor.environmentKey, SessionRuntimeDescriptor.localRuntimeEnvironmentKey,
                    SessionRuntimeDescriptor.attachExistingEnvironmentKey,
                    SessionRuntimeDescriptor.resurrectWorkingDirectoryEnvironmentKey,
                    SessionRuntimeDescriptor.recreateIfGoneEnvironmentKey,
                    SessionRuntimeDescriptor.handoffResumeEnvironmentKey,
                    Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey,
                    "OMG_RUNTIME_SOCKET", "OMG_RUNTIME_PANE_ID"] {
            result.environmentVariables.removeValue(forKey: key)
        }
        result.workingDirectory = localWorkingDirectory
        if suppressInheritWorkingDirectory {
            result.environmentVariables[Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey] = "1"
        }
        result.setSurvivalCommand(launch.command)
        result.initialInput = nil
        result.waitAfterCommand = false
        return result
    }
}

/// A resolved new-pane configuration plus the Agent or SSH descriptor to adopt
/// once the Surface exists, so status, chained splits/tabs, and restoration
/// know the launched session immediately.
struct InheritedSessionLaunch {
    var configuration: Ghostty.SurfaceConfiguration?
    var agentDescriptor: AgentResumeDescriptor?
    var sshDescriptor: SSHResumeDescriptor?
}

extension TerminalController {
    func adoptInheritedLaunch(_ launch: InheritedSessionLaunch, for surface: Ghostty.SurfaceView) {
        if let sshDescriptor = launch.sshDescriptor {
            surface.pendingSSHLaunchReplay = sshDescriptor.sshReplay
            if let localDir = sshDescriptor.localWorkingDirectory, localDir.hasPrefix("/") {
                surface.knownLocalWorkingDirectory = localDir
            }
            adoptSSHRecoveryDescriptor(sshDescriptor, for: surface)
        }
        if let descriptor = launch.agentDescriptor {
            if descriptor.scope == .remote, let replay = descriptor.sshReplay {
                surface.pendingSSHLaunchReplay = replay
                if let localDir = replay.localWorkingDirectory, localDir.hasPrefix("/") {
                    surface.knownLocalWorkingDirectory = localDir
                }
            }
            adoptAgentResumeDescriptor(descriptor, for: surface)
        }
    }

    /// Applies the configured new-tab inheritance on top of Ghostty's
    /// inherited configuration for `source`.
    func newTabLaunch(
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView,
        level requested: NewSessionInheritance? = nil,
        ghosttyConfig: Ghostty.Config? = nil
    ) -> InheritedSessionLaunch {
        let level = requested ?? .current(for: .tab)
        if let launch = inheritedAgentLaunch(
            entry: .tab,
            level: level,
            inherited: config,
            from: source,
            ghosttyConfig: ghosttyConfig
        ) {
            return launch
        }
        let inheritsDirectory = shouldInheritWorkingDirectory(
            entry: .tab,
            level: level,
            ghosttyConfig: ghosttyConfig
        )
        switch level {
        case .defaultDirectory:
            var result = tabConfiguration(
                inherited: withoutWorkingDirectory(config),
                from: source,
                inheritsWorkingDirectory: false
            ) ?? .init()
            result.workingDirectory = nil
            result.environmentVariables[Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey] = "1"
            return .init(configuration: result)
        case .workingDirectory:
            return .init(configuration: tabConfiguration(
                inherited: config,
                from: source,
                inheritsWorkingDirectory: inheritsDirectory
            ))
        case .ssh, .agentNewSession, .agentResume:
            guard let remoteSource = remoteSessionSource(for: source),
                  let remote = try? splitConfiguration(
                    inherited: config,
                    from: source,
                    inheritsWorkingDirectory: inheritsDirectory,
                    injectTabSessionID: false
                  ) else {
                return .init(configuration: tabConfiguration(
                    inherited: config,
                    from: source,
                    inheritsWorkingDirectory: inheritsDirectory
                ))
            }
            return .init(
                configuration: remote,
                sshDescriptor: inheritedSSHLaunchDescriptor(
                    from: remoteSource,
                    inheritsWorkingDirectory: inheritsDirectory,
                    configuration: remote
                )
            )
        }
    }

    /// Applies the configured split inheritance. Throws when SSH inheritance
    /// is requested but the connection cannot be reproduced.
    func newSplitLaunch(
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView,
        level requested: NewSessionInheritance? = nil,
        ghosttyConfig: Ghostty.Config? = nil
    ) throws -> InheritedSessionLaunch {
        let level = requested ?? .current(for: .split)
        if let launch = inheritedAgentLaunch(
            entry: .split,
            level: level,
            inherited: config,
            from: source,
            ghosttyConfig: ghosttyConfig
        ) {
            var configured = launch.configuration ?? .init()
            let settings = OhMyGhosttySettings.shared
            _ = SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
                &configured,
                policy: settings.runtimePolicy,
                enabled: settings.localRuntimeEnabled
            )
            return .init(
                configuration: Self.injectingSessionID(tabSessionID, into: configured),
                agentDescriptor: launch.agentDescriptor
            )
        }
        let inheritsDirectory = shouldInheritWorkingDirectory(
            entry: .split,
            level: level,
            ghosttyConfig: ghosttyConfig
        )
        switch level {
        case .defaultDirectory, .workingDirectory:
            let base = inheritsDirectory ? config : withoutWorkingDirectory(config)
            guard sourceIsRemote(source) else {
                return .init(configuration: try splitConfiguration(
                    inherited: base,
                    from: source,
                    inheritsWorkingDirectory: inheritsDirectory
                ))
            }
            // Same local result as a new tab from an SSH pane: a fresh local
            // shell, never the remote path on this Mac.
            var result = tabConfiguration(
                inherited: base,
                from: source,
                inheritsWorkingDirectory: inheritsDirectory
            ) ?? .init()
            if !inheritsDirectory {
                result.workingDirectory = nil
                result.environmentVariables[Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey] = "1"
            }
            let settings = OhMyGhosttySettings.shared
            _ = SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
                &result, policy: settings.runtimePolicy, enabled: settings.localRuntimeEnabled
            )
            return .init(configuration: Self.injectingSessionID(tabSessionID, into: result))
        case .ssh, .agentNewSession, .agentResume:
            let remoteSource = remoteSessionSource(for: source)
            let split = try splitConfiguration(
                inherited: config,
                from: source,
                inheritsWorkingDirectory: inheritsDirectory
            )
            return .init(
                configuration: split,
                sshDescriptor: remoteSource.flatMap {
                    inheritedSSHLaunchDescriptor(
                        from: $0,
                        inheritsWorkingDirectory: inheritsDirectory,
                        configuration: split
                    )
                }
            )
        }
    }

    func shouldInheritWorkingDirectory(
        entry: NewSessionInheritance.Entry,
        level: NewSessionInheritance,
        ghosttyConfig: Ghostty.Config? = nil
    ) -> Bool {
        if level == .defaultDirectory { return false }
        let activeConfig = ghosttyConfig ?? ghostty.config
        return switch entry {
        case .tab: activeConfig.tabInheritWorkingDirectory
        case .split: activeConfig.splitInheritWorkingDirectory
        }
    }

    private func inheritedSSHLaunchDescriptor(
        from remote: RemoteSessionSource,
        inheritsWorkingDirectory: Bool,
        configuration: Ghostty.SurfaceConfiguration?
    ) -> SSHResumeDescriptor? {
        guard configuration?.command != nil,
              var replay = remote.replay,
              replay.transferTarget != nil else { return nil }
        let localDir = inheritsWorkingDirectory
            ? (configuration?.workingDirectory ?? remote.localWorkingDirectory)
            : nil
        if replay.localWorkingDirectory == nil {
            replay.localWorkingDirectory = remote.localWorkingDirectory
        }
        return .init(
            sshReplay: replay,
            remoteWorkingDirectory: inheritsWorkingDirectory ? remote.remoteWorkingDirectory : nil,
            localWorkingDirectory: localDir,
            awaitingReconnect: false
        )
    }

    private func withoutWorkingDirectory(_ config: Ghostty.SurfaceConfiguration?) -> Ghostty.SurfaceConfiguration? {
        guard var config else { return nil }
        config.workingDirectory = nil
        return config
    }

    func sourceIsRemote(_ source: Ghostty.SurfaceView) -> Bool {
        remoteSessionSource(for: source) != nil
    }

    /// nil when the level does not inherit an Agent, the pane runs none, or
    /// its SSH connection cannot be replayed; callers then fall back to the
    /// SSH/directory behavior.
    private func inheritedAgentLaunch(
        entry: NewSessionInheritance.Entry,
        level: NewSessionInheritance,
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView,
        ghosttyConfig: Ghostty.Config? = nil
    ) -> InheritedSessionLaunch? {
        guard level.inheritsAgent, let executablePath = Bundle.main.executablePath else { return nil }
        let resume = agentResumeDescriptor(for: source)
        guard let agent = resume?.agent
                ?? agentActivity(for: source).flatMap({ SupportedAgent(rawValue: $0.source) }) else { return nil }
        let inheritsDirectory = shouldInheritWorkingDirectory(
            entry: entry,
            level: level,
            ghosttyConfig: ghosttyConfig
        )
        let remoteSource = remoteSessionSource(for: source)
        var replay = remoteSource?.replay
        if replay == nil, resume?.scope == .remote {
            replay = resume?.sshReplay
        }
        if replay == nil, remoteSource != nil { return nil }
        let remoteDirectory: String? = inheritsDirectory
            ? (remoteSource?.remoteWorkingDirectory ?? resume?.workingDirectory)
            : nil
        let rawLocalDirectory: String? = if replay != nil {
            remoteSource?.localWorkingDirectory ?? replay?.localWorkingDirectory
        } else {
            source.pwd ?? resume?.workingDirectory ?? config?.workingDirectory
        }
        if replay != nil, replay?.localWorkingDirectory == nil {
            replay?.localWorkingDirectory = rawLocalDirectory
        }
        let effectiveLocalDirectory: String? = inheritsDirectory
            ? (rawLocalDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)
            : nil
        guard let launch = NewSessionInheritance.agentLaunch(
            level: level,
            agent: agent,
            conversationID: resume?.agent == agent ? resume?.conversationID : nil,
            remote: replay.map { .init(replay: $0, workingDirectory: remoteDirectory) },
            localWorkingDirectory: effectiveLocalDirectory,
            executablePath: executablePath,
            includeLocalWorkingDirectoryInCommand: !inheritsDirectory
        ) else { return nil }
        return .init(
            configuration: NewSessionInheritance.configuration(
                for: launch,
                inherited: config,
                localWorkingDirectory: effectiveLocalDirectory,
                suppressInheritWorkingDirectory: !inheritsDirectory
            ),
            agentDescriptor: launch.descriptor
        )
    }
}
