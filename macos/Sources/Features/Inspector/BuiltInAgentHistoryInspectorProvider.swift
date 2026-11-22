import AppKit
import Foundation
import OSLog

@MainActor
final class BuiltInAgentHistoryInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "agent-history"
    )

    static let pluginID = "builtin.agent-history"
    static let paneID = "builtin.agent-history"

    typealias SessionLoader = () async -> [AgentHistorySession]
    typealias RemoteSessionLoader = (AgentHistoryRemoteAccess) async -> [AgentHistorySession]
    typealias TranscriptLoader = (AgentHistorySession) async -> AgentHistoryTranscript
    typealias SessionResumer = @MainActor (AgentHistorySession, InspectorPaneContext) -> Void
    typealias SessionForker = @MainActor (
        AgentHistorySession, AgentHistoryForkPlacement, InspectorPaneContext
    ) -> Void

    private struct TabState {
        var hostKey: String = "local"
        var selectedSessionID: String?
        var transcript: AgentHistoryTranscript?
        var isLoadingTranscript = false
    }

    private let registry: InspectorRegistry
    private let sessionLoader: SessionLoader?
    private let remoteSessionLoader: RemoteSessionLoader?
    private let transcriptLoader: TranscriptLoader
    private let sessionResumer: SessionResumer
    private let sessionForker: SessionForker
    private var sessionsByHost: [String: [AgentHistorySession]] = [:] {
        didSet { presentedSessionCache.removeAll() }
    }
    private var presentedSessionCache: [String: (activeIDs: Set<String>, sessions: [AgentHistorySession])] = [:]
    private var loadingHosts: Set<String> = []
    private var fullHistoryHosts: Set<String> = []
    private var loadedFullHistoryHosts: Set<String> = []
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptTasks: [UUID: Task<Void, Never>] = [:]
    private var tabStates: [UUID: TabState] = [:]
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var backgroundIndexTimer: Timer?
    private var backgroundIndexTask: Task<Void, Never>?

    init(
        registry: InspectorRegistry,
        sessionLoader: SessionLoader? = nil,
        remoteSessionLoader: RemoteSessionLoader? = nil,
        transcriptLoader: @escaping TranscriptLoader = {
            await AgentHistoryStore.transcript(for: $0)
        },
        sessionResumer: @escaping SessionResumer =
            BuiltInAgentHistoryInspectorProvider.resume,
        sessionForker: @escaping SessionForker =
            BuiltInAgentHistoryInspectorProvider.fork
    ) {
        self.registry = registry
        self.sessionLoader = sessionLoader
        self.remoteSessionLoader = remoteSessionLoader
        self.transcriptLoader = transcriptLoader
        self.sessionResumer = sessionResumer
        self.sessionForker = sessionForker

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: OhMyGhosttySettings.didChangeNotification,
            object: OhMyGhosttySettings.shared,
            queue: .main
        ) { [weak self] notification in
            let key = notification.userInfo?[
                OhMyGhosttySettings.changedKeyUserInfoKey
            ] as? String
            if key == "general.language" {
                Task { @MainActor [weak self] in
                    self?.refreshLocalization()
                }
            } else if key == "agents.historyBackgroundIndexing" {
                Task { @MainActor [weak self] in self?.configureBackgroundIndexing() }
            } else if key == "agents.historyLimit" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    sessionsByHost.removeAll()
                    loadingHosts.removeAll()
                    for context in presentedContexts.values {
                        loadOnDemand(context: context)
                    }
                }
            }
        })
        configureBackgroundIndexing()
    }

    deinit {
        backgroundIndexTimer?.invalidate()
        backgroundIndexTask?.cancel()
        for task in loadTasks.values { task.cancel() }
        for task in transcriptTasks.values { task.cancel() }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func register() throws {
        let descriptor = InspectorPaneDescriptor(
            id: Self.paneID,
            title: AgentHistoryStrings.current.title,
            systemImage: "clock.arrow.circlepath",
            source: .plugin(Self.pluginID),
            preferredWidth: RightInspectorMetrics.defaultWidth,
            minimumWidth: 200
        )
        try registry.registerPluginPane(
            descriptor,
            lifecycle: { [weak self] event in self?.handle(event) },
            action: { [weak self] action in self?.handle(action) }
        )
    }

    private func refreshLocalization() {
        do {
            try registry.updatePluginPaneTitle(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                title: AgentHistoryStrings.current.title
            )
        } catch {
            Self.logger.error(
                "failed to localize Agent History: \(error.localizedDescription, privacy: .public)"
            )
        }
        publishPresentedContexts()
    }

    func forgetTab(_ tabID: UUID) {
        transcriptTasks.removeValue(forKey: tabID)?.cancel()
        tabStates.removeValue(forKey: tabID)
        presentedContexts.removeValue(forKey: tabID)
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            presentedContexts[context.tabID] = context
            let hostKey = hostKey(for: context)
            var state = tabStates[context.tabID] ?? .init(hostKey: hostKey)
            if state.hostKey != hostKey {
                state = .init(hostKey: hostKey)
                tabStates[context.tabID] = state
            }
            publish(context)
            loadOnDemand(context: context)
            if let id = state.selectedSessionID, state.transcript == nil, !state.isLoadingTranscript {
                selectSession(id, context: context)
            }
        case .disappeared(let context):
            presentedContexts.removeValue(forKey: context.tabID)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      presentedContexts[context.tabID] == nil else { return }
                transcriptTasks[context.tabID]?.cancel()
                transcriptTasks.removeValue(forKey: context.tabID)
                tabStates[context.tabID]?.isLoadingTranscript = false
            }
        }
    }

    private func handle(_ action: InspectorPaneAction) {
        let hostKey = hostKey(for: action.context)
        switch action.kind {
        case .setAgentHistoryTimeRange(let range):
            if range == .any || range == .year {
                fullHistoryHosts.insert(hostKey)
                loadOnDemand(context: action.context)
            }
        case .refreshAgentHistory:
            reload(context: action.context)
        case .selectAgentHistorySession(let id):
            selectSession(id, context: action.context)
        case .clearAgentHistorySelection:
            clearSelection(context: action.context)
        case .resumeAgentHistorySession(let id):
            guard let session = sessionsByHost[hostKey]?.first(where: { $0.id == id }) else {
                return
            }
            sessionResumer(session, action.context)
            publishPresentedContexts()
        case .forkAgentHistorySession(let id, let placement):
            guard let session = sessionsByHost[hostKey]?.first(where: { $0.id == id }),
                  session.supportsFork else {
                return
            }
            sessionForker(session, placement, action.context)
            publishPresentedContexts()
        default:
            break
        }
    }

    private func loadOnDemand(context: InspectorPaneContext, refresh: Bool = false) {
        let hostKey = hostKey(for: context)
        if !refresh, sessionsByHost[hostKey] != nil,
           !fullHistoryHosts.contains(hostKey) || loadedFullHistoryHosts.contains(hostKey) {
            publish(context)
            return
        }
        guard !loadingHosts.contains(hostKey) else {
            publish(context)
            return
        }
        loadingHosts.insert(hostKey)
        publish(context)

        let isSSH: String? = if case .sshReady(let ssh, _) = context.session.state {
            ssh.alias
        } else {
            nil
        }

        let taskID = UUID()
        let cutoff = fullHistoryHosts.contains(hostKey) ? nil : AgentHistoryTimeFilter.quarter.cutoff()
        let limit = Int(OhMyGhosttySettings.shared.agentHistoryLimit)
        loadTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            let loaded: [AgentHistorySession]
            if let alias = isSSH {
                let access = AgentHistoryRemoteAccess(alias: alias)
                if let remoteSessionLoader { loaded = await remoteSessionLoader(access) } else {
                    loaded = await AgentHistoryStore.loadRemote(access: access, maximumSessions: limit, updatedAfter: cutoff)
                }
            } else {
                // Paint once. A provisional cached list made the session count
                // jump whenever the authoritative scan disagreed with it.
                guard presentedContexts[context.tabID] != nil else {
                    loadingHosts.remove(hostKey)
                    loadTasks.removeValue(forKey: taskID)
                    return
                }
                if let sessionLoader { loaded = await sessionLoader() } else {
                    loaded = await AgentHistoryStore.load(maximumSessions: limit, updatedAfter: cutoff)
                }
            }
            guard !Task.isCancelled else { return }
            sessionsByHost[hostKey] = loaded
            if isSSH == nil {
                // Opening Agent History is what keeps its search index current.
                updateSearchIndex(with: loaded, isComplete: cutoff == nil && loaded.count < limit)
            }
            if cutoff == nil { loadedFullHistoryHosts.insert(hostKey) }
            loadingHosts.remove(hostKey)
            loadTasks.removeValue(forKey: taskID)
            publishPresentedContexts()
            if cutoff != nil, fullHistoryHosts.contains(hostKey),
               let visible = presentedContexts.values.first(where: { self.hostKey(for: $0) == hostKey }) {
                loadOnDemand(context: visible)
            }
        }
    }

    /// An injected loader means a test or preview owns the sessions; the
    /// user's real index is left alone.
    private func updateSearchIndex(with sessions: [AgentHistorySession], isComplete: Bool) {
        guard sessionLoader == nil else { return }
        AgentHistorySearchIndex.shared.scheduleUpdate(sessions: sessions, pruneMissing: isComplete)
    }

    /// With the setting on, the index follows new sessions even while Agent
    /// History stays closed. Off, it is updated only when the pane loads.
    private func configureBackgroundIndexing() {
        backgroundIndexTimer?.invalidate()
        backgroundIndexTimer = nil
        backgroundIndexTask?.cancel()
        backgroundIndexTask = nil
        guard sessionLoader == nil, OhMyGhosttySettings.shared.agentHistoryBackgroundIndexing else { return }
        refreshSearchIndexInBackground()
        backgroundIndexTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSearchIndexInBackground() }
        }
    }

    private func refreshSearchIndexInBackground() {
        backgroundIndexTask?.cancel()
        let limit = Int(OhMyGhosttySettings.shared.agentHistoryLimit)
        backgroundIndexTask = Task.detached(priority: .background) {
            let sessions = await AgentHistoryStore.load(maximumSessions: limit)
            guard !Task.isCancelled else { return }
            AgentHistorySearchIndex.shared.scheduleUpdate(sessions: sessions, pruneMissing: sessions.count < limit)
        }
    }

    private func reload(context: InspectorPaneContext) {
        let hostKey = hostKey(for: context)
        guard !loadingHosts.contains(hostKey) else { return }
        loadOnDemand(context: context, refresh: true)
    }

    private func hostKey(for context: InspectorPaneContext) -> String {
        if case .sshReady(let ssh, _) = context.session.state {
            return "ssh:\(ssh.alias)"
        }
        return "local"
    }

    private func selectSession(
        _ id: String,
        context: InspectorPaneContext
    ) {
        let hostKey = hostKey(for: context)
        guard let session = sessionsByHost[hostKey]?.first(where: { $0.id == id }) else {
            return
        }
        transcriptTasks[context.tabID]?.cancel()
        var state = tabStates[context.tabID] ?? .init(hostKey: hostKey)
        state.selectedSessionID = id
        if state.transcript?.sessionID == id {
            state.isLoadingTranscript = false
            tabStates[context.tabID] = state
            publish(context)
            return
        }
        state.transcript = nil
        state.isLoadingTranscript = true
        tabStates[context.tabID] = state
        publish(context)

        transcriptTasks[context.tabID] = Task { [weak self] in
            guard let self else { return }
            let transcript = await transcriptLoader(session)
            guard !Task.isCancelled,
                  tabStates[context.tabID]?.selectedSessionID == id else { return }
            tabStates[context.tabID]?.transcript = transcript
            tabStates[context.tabID]?.isLoadingTranscript = false
            transcriptTasks.removeValue(forKey: context.tabID)
            if let current = presentedContexts[context.tabID] { publish(current) }
        }
    }

    private func clearSelection(context: InspectorPaneContext) {
        transcriptTasks[context.tabID]?.cancel()
        tabStates[context.tabID]?.selectedSessionID = nil
        tabStates[context.tabID]?.transcript = nil
        tabStates[context.tabID]?.isLoadingTranscript = false
        publish(context)
    }

    private func publishPresentedContexts() {
        for context in presentedContexts.values { publish(context) }
    }

    private func publish(_ context: InspectorPaneContext) {
        let hostKey = hostKey(for: context)
        let state = tabStates[context.tabID] ?? .init(hostKey: hostKey)
        let activeIDs = Self.activeSessionIDs()
        let hostSessions = sessionsByHost[hostKey]
        let presentedSessions: [AgentHistorySession]
        if let cached = presentedSessionCache[hostKey], cached.activeIDs == activeIDs {
            presentedSessions = cached.sessions
        } else {
            presentedSessions = (hostSessions ?? []).map { session in
                var session = session
                session.isActive = activeIDs.contains(session.id)
                return session
            }
            presentedSessionCache[hostKey] = (activeIDs, presentedSessions)
        }
        let isLoading = loadingHosts.contains(hostKey)
        let hostLabel: String? = if case .sshReady(let ssh, _) = context.session.state {
            ssh.alias
        } else {
            nil
        }
        do {
            try registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: context.tabID,
                content: .agentHistory(.init(
                    hostLabel: hostLabel,
                    sessions: presentedSessions,
                    selectedSessionID: state.selectedSessionID,
                    transcript: state.transcript,
                    isLoadingSessions: isLoading,
                    isLoadingTranscript: state.isLoadingTranscript
                ))
            )
        } catch {
            Self.logger.error(
                "failed to publish Agent History: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func activeSessionIDs() -> Set<String> {
        var result = Set<String>()
        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                guard let descriptor = controller.agentResumeDescriptor(for: surface),
                      let conversationID = descriptor.conversationID else { continue }
                if descriptor.scope == .local {
                    result.insert("\(descriptor.agent.rawValue):\(conversationID.rawValue)")
                } else if let target = descriptor.sshReplay?.transferTarget {
                    result.insert("ssh:\(target):\(descriptor.agent.rawValue):\(conversationID.rawValue)")
                }
            }
        }
        return result
    }

    private static func resume(
        _ session: AgentHistorySession,
        context: InspectorPaneContext
    ) {
        let isRemote = session.remoteHost != nil

        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                guard let descriptor = controller.agentResumeDescriptor(for: surface),
                      descriptor.agent == session.agent,
                      descriptor.conversationID == session.conversationID else {
                    continue
                }
                if !isRemote, descriptor.scope == .local {
                    controller.focusSurface(surface)
                    return
                } else if isRemote, descriptor.scope == .remote,
                          descriptor.sshReplay?.transferTarget == session.remoteHost {
                    controller.focusSurface(surface)
                    return
                }
            }
        }

        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let executablePath = Bundle.main.executablePath else { return }

        if let remoteHost = session.remoteHost {
            guard let activeReplay = replayDescriptor(for: remoteHost, context: context) else { return }

            let workingDirectory = session.workingDirectory ?? context.workingDirectory
            let descriptor = AgentResumeDescriptor(
                agent: session.agent,
                conversationID: session.conversationID,
                scope: .remote,
                workingDirectory: workingDirectory,
                sshReplay: activeReplay
            )
            guard let command = descriptor.restorationCommand(
                executablePath: executablePath,
                verifyLocalStore: false
            ) else { return }

            var configuration = Ghostty.SurfaceConfiguration()
            configuration.workingDirectory = context.session.local.workingDirectory
            configuration.command = TerminalController.replaySurvivalCommand(command)
            let parent = TerminalController.all.first(where: {
                $0.tabSessionID == context.tabID
            })?.window ?? TerminalController.preferredParent?.window
            guard let controller = TerminalController.newTab(
                appDelegate.ghostty,
                from: parent,
                withBaseConfig: configuration
            ), let surface = controller.surfaceTree.first else { return }
            controller.adoptAgentResumeDescriptor(descriptor, for: surface, title: session.title)
            return
        }

        guard FileManager.default.fileExists(atPath: session.sourcePath) else { return }
        let workingDirectory = session.workingDirectory ?? context.workingDirectory
        let descriptor = AgentResumeDescriptor(
            agent: session.agent,
            conversationID: session.conversationID,
            scope: .local,
            workingDirectory: workingDirectory
        )
        guard let command = descriptor.restorationCommand(
            executablePath: executablePath,
            verifyLocalStore: false
        ) else { return }

        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = workingDirectory
        configuration.command = TerminalController.replaySurvivalCommand(command)
        let parent = TerminalController.all.first(where: {
            $0.tabSessionID == context.tabID
        })?.window ?? TerminalController.preferredParent?.window
        guard let controller = TerminalController.newTab(
            appDelegate.ghostty,
            from: parent,
            withBaseConfig: configuration
        ), let surface = controller.surfaceTree.first else { return }
        controller.adoptAgentResumeDescriptor(descriptor, for: surface, title: session.title)
    }

    /// The SSH invocation that reaches `remoteHost`: the Inspector pane's own
    /// connection when it has one, otherwise a plain `ssh <alias>`.
    private static func replayDescriptor(
        for remoteHost: String,
        context: InspectorPaneContext
    ) -> SSHReplayDescriptor? {
        let replay: SSHReplayDescriptor? = switch context.session.state {
        case .local:
            nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID)
        }
        return replay ?? SSHPlugin.configuration(alias: remoteHost).map {
            SSHReplayDescriptor(
                version: 1,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: true,
                cache: true,
                args: [$0.alias]
            )
        }
    }

    /// Starts the Agent's native fork of `session`. The fork gets a new
    /// conversation ID from the Agent, so no resume descriptor is adopted
    /// here; the Agent's own hooks identify the new pane.
    private static func fork(
        _ session: AgentHistorySession,
        placement: AgentHistoryForkPlacement,
        context: InspectorPaneContext
    ) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let executablePath = Bundle.main.executablePath else { return }
        var configuration = Ghostty.SurfaceConfiguration()
        if let remoteHost = session.remoteHost {
            guard let replay = replayDescriptor(for: remoteHost, context: context),
                  let command = remoteForkCommand(
                      for: session,
                      replay: replay,
                      executablePath: executablePath,
                      fallbackWorkingDirectory: context.workingDirectory
                  ) else { return }
            configuration.workingDirectory = context.session.local.workingDirectory
            configuration.command = TerminalController.replaySurvivalCommand(command)
        } else {
            guard FileManager.default.fileExists(atPath: session.sourcePath),
                  let command = forkCommand(for: session) else { return }
            configuration.workingDirectory = session.workingDirectory ?? context.workingDirectory
            configuration.command = TerminalController.replaySurvivalCommand(command)
        }

        let host = TerminalController.all.first(where: { $0.tabSessionID == context.tabID })
        if placement != .newTab, let host,
           let source = host.surfaceTree.first(where: { $0.id == context.surfaceID })
               ?? host.focusedSurface ?? host.surfaceTree.first {
            _ = host.newDirectorySplit(
                at: source,
                direction: placement == .splitRight ? .right : .down,
                configuration: configuration
            )
            return
        }
        _ = TerminalController.newTab(
            appDelegate.ghostty,
            from: host?.window ?? TerminalController.preferredParent?.window,
            withBaseConfig: configuration
        )
    }

    /// The local native fork, run in the user's login shell so the Agent CLI
    /// resolves from its normal PATH. nil when the manifest declares no fork.
    nonisolated static func forkCommand(for session: AgentHistorySession) -> String? {
        guard let arguments = session.forkArguments else { return nil }
        let argv = [session.agent.definition.command] + arguments
        guard argv.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { return nil }
        let invocation = argv.map(shellQuote).joined(separator: " ")
        let shell = "\"${SHELL:-/bin/zsh}\""
        return "\(shell) -l -i -c \(shellQuote(invocation)); exec \(shell) -l"
    }

    /// The `+ssh` replay that forks `session` on its remote host. `+ssh` owns
    /// the per-agent fork dialect and refuses agents without one.
    nonisolated static func remoteForkCommand(
        for session: AgentHistorySession,
        replay: SSHReplayDescriptor,
        executablePath: String,
        fallbackWorkingDirectory: String? = nil
    ) -> String? {
        guard session.supportsFork else { return nil }
        return replay.command(
            executablePath: executablePath,
            remoteWorkingDirectory: session.workingDirectory ?? fallbackWorkingDirectory,
            remoteAgent: session.agent,
            conversationID: session.conversationID,
            forkConversation: true
        )
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
