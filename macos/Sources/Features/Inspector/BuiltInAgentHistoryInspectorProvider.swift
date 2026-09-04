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
    typealias SessionResumer = (AgentHistorySession, InspectorPaneContext) -> Void
    typealias SessionForker = (AgentHistorySession, InspectorPaneContext) -> Void

    private struct TabState {
        var hostKey: String = "local"
        var sessions: [AgentHistorySession]?
        var isLoadingSessions = false
        var selectedSessionID: String?
        var transcript: AgentHistoryTranscript?
        var isLoadingTranscript = false
    }

    private let registry: InspectorRegistry
    private let cachedSessionLoader: SessionLoader
    private let sessionLoader: SessionLoader
    private let remoteSessionLoader: RemoteSessionLoader
    private let transcriptLoader: TranscriptLoader
    private let sessionResumer: SessionResumer
    private let sessionForker: SessionForker
    private var loadGenerations: [UUID: UInt64] = [:]
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptTasks: [UUID: Task<Void, Never>] = [:]
    private var tabStates: [UUID: TabState] = [:]
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        registry: InspectorRegistry,
        cachedSessionLoader: @escaping SessionLoader = {
            await AgentHistoryStore.loadCached(
                maximumSessions: Int(OhMyGhosttySettings.shared.agentHistoryLimit)
            )
        },
        sessionLoader: @escaping SessionLoader = {
            await AgentHistoryStore.load(
                maximumSessions: Int(OhMyGhosttySettings.shared.agentHistoryLimit)
            )
        },
        remoteSessionLoader: @escaping RemoteSessionLoader = { access in
            await AgentHistoryStore.loadRemote(
                access: access,
                maximumSessions: Int(OhMyGhosttySettings.shared.agentHistoryLimit)
            )
        },
        transcriptLoader: @escaping TranscriptLoader = {
            await AgentHistoryStore.transcript(for: $0)
        },
        sessionResumer: @escaping SessionResumer =
            BuiltInAgentHistoryInspectorProvider.resume,
        sessionForker: @escaping SessionForker =
            BuiltInAgentHistoryInspectorProvider.fork
    ) {
        self.registry = registry
        self.cachedSessionLoader = cachedSessionLoader
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
            } else if key == "agents.historyLimit" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if presentedContexts.isEmpty {
                        tabStates.removeAll()
                    } else {
                        for context in presentedContexts.values {
                            reload(context: context)
                        }
                    }
                }
            }
        })
    }

    deinit {
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

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            presentedContexts[context.tabID] = context
            var state = tabStates[context.tabID] ?? .init()
            let hostKey = hostKey(for: context)
            if state.hostKey != hostKey {
                state = .init(hostKey: hostKey)
                tabStates[context.tabID] = state
            }
            publish(context)
            if state.sessions == nil, !state.isLoadingSessions {
                loadOnDemand(context: context)
            }
        case .disappeared(let context):
            presentedContexts.removeValue(forKey: context.tabID)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      presentedContexts[context.tabID] == nil else { return }
                loadTasks[context.tabID]?.cancel()
                loadTasks.removeValue(forKey: context.tabID)
                transcriptTasks[context.tabID]?.cancel()
                transcriptTasks.removeValue(forKey: context.tabID)
                if presentedContexts.isEmpty {
                    tabStates.removeAll()
                }
            }
        }
    }

    private func handle(_ action: InspectorPaneAction) {
        switch action.kind {
        case .refreshAgentHistory:
            reload(context: action.context)
        case .selectAgentHistorySession(let id):
            selectSession(id, context: action.context)
        case .clearAgentHistorySelection:
            clearSelection(context: action.context)
        case .resumeAgentHistorySession(let id):
            guard let session = tabStates[action.context.tabID]?.sessions?.first(where: { $0.id == id }) else {
                return
            }
            sessionResumer(session, action.context)
            publishPresentedContexts()
        case .forkAgentHistorySession(let id):
            guard let session = tabStates[action.context.tabID]?.sessions?.first(where: { $0.id == id }) else {
                return
            }
            sessionForker(session, action.context)
            publishPresentedContexts()
        default:
            break
        }
    }

    private func loadOnDemand(context: InspectorPaneContext) {
        let tabID = context.tabID
        loadTasks[tabID]?.cancel()
        let nextGen = (loadGenerations[tabID] ?? 0) &+ 1
        loadGenerations[tabID] = nextGen
        var state = tabStates[tabID] ?? .init(hostKey: hostKey(for: context))
        state.isLoadingSessions = true
        tabStates[tabID] = state
        publish(context)

        let isSSH: String?
        if case .sshReady(let ssh, _) = context.session.state {
            isSSH = ssh.alias
        } else {
            isSSH = nil
        }

        loadTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            if let alias = isSSH {
                let access = AgentHistoryRemoteAccess(alias: alias)
                let loaded = await remoteSessionLoader(access)
                guard !Task.isCancelled, loadGenerations[tabID] == nextGen else { return }
                applyLoadedSessions(loaded, for: tabID)
                loadTasks.removeValue(forKey: tabID)
                if let current = presentedContexts[tabID] { publish(current) }
            } else {
                let cached = await cachedSessionLoader()
                guard !Task.isCancelled, loadGenerations[tabID] == nextGen else { return }
                if !cached.isEmpty {
                    applyLoadedSessions(cached, for: tabID)
                    if let current = presentedContexts[tabID] { publish(current) }
                }

                guard presentedContexts[tabID] != nil else {
                    loadTasks.removeValue(forKey: tabID)
                    return
                }
                let refreshed = await sessionLoader()
                guard !Task.isCancelled, loadGenerations[tabID] == nextGen else { return }
                applyLoadedSessions(refreshed, for: tabID)
                loadTasks.removeValue(forKey: tabID)
                if let current = presentedContexts[tabID] { publish(current) }
            }
        }
    }

    private func reload(context: InspectorPaneContext) {
        let tabID = context.tabID
        loadTasks[tabID]?.cancel()
        let nextGen = (loadGenerations[tabID] ?? 0) &+ 1
        loadGenerations[tabID] = nextGen
        var state = tabStates[tabID] ?? .init(hostKey: hostKey(for: context))
        state.isLoadingSessions = true
        tabStates[tabID] = state
        publish(context)

        let isSSH: String?
        if case .sshReady(let ssh, _) = context.session.state {
            isSSH = ssh.alias
        } else {
            isSSH = nil
        }

        loadTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            let loaded: [AgentHistorySession]
            if let alias = isSSH {
                let access = AgentHistoryRemoteAccess(alias: alias)
                loaded = await remoteSessionLoader(access)
            } else {
                loaded = await sessionLoader()
            }
            guard !Task.isCancelled, loadGenerations[tabID] == nextGen else { return }
            applyLoadedSessions(loaded, for: tabID)
            loadTasks.removeValue(forKey: tabID)
            if let current = presentedContexts[tabID] { publish(current) }
        }
    }

    private func applyLoadedSessions(_ loaded: [AgentHistorySession], for tabID: UUID) {
        var state = tabStates[tabID] ?? .init()
        state.sessions = loaded
        state.isLoadingSessions = false
        let availableIDs = Set(loaded.map(\.id))
        if let selected = state.selectedSessionID, !availableIDs.contains(selected) {
            state.selectedSessionID = nil
            state.transcript = nil
            state.isLoadingTranscript = false
        }
        tabStates[tabID] = state
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
        guard let session = tabStates[context.tabID]?.sessions?.first(where: { $0.id == id }) else {
            return
        }
        transcriptTasks.removeValue(forKey: context.tabID)?.cancel()
        var state = tabStates[context.tabID] ?? .init()
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
        transcriptTasks.removeValue(forKey: context.tabID)?.cancel()
        tabStates[context.tabID]?.selectedSessionID = nil
        tabStates[context.tabID]?.transcript = nil
        tabStates[context.tabID]?.isLoadingTranscript = false
        publish(context)
    }

    private func publishPresentedContexts() {
        for context in presentedContexts.values { publish(context) }
    }

    private func publish(_ context: InspectorPaneContext) {
        let state = tabStates[context.tabID] ?? .init()
        let activeIDs = Self.activeSessionIDs()
        let presentedSessions = (state.sessions ?? []).map { session in
            var session = session
            session.isActive = activeIDs.contains(session.id)
            return session
        }
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
                    isLoadingSessions: state.isLoadingSessions,
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
            let replay: SSHReplayDescriptor? = switch context.session.state {
            case .local:
                nil
            case .sshConnecting(let ssh), .sshReady(let ssh, _):
                ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID)
            }
            guard let activeReplay = replay ?? (SSHPlugin.configuration(alias: remoteHost).map {
                SSHReplayDescriptor(
                    version: 1,
                    ssh: "/usr/bin/ssh",
                    forwardEnv: true,
                    terminfo: true,
                    cache: true,
                    args: [$0.alias]
                )
            }) else { return }

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
            controller.adoptAgentResumeDescriptor(descriptor, for: surface)
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
        controller.adoptAgentResumeDescriptor(descriptor, for: surface)
    }

    private static func fork(
        _ session: AgentHistorySession,
        context: InspectorPaneContext
    ) {
        guard session.remoteHost == nil,
              FileManager.default.fileExists(atPath: session.sourcePath),
              let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let workingDirectory = session.workingDirectory ?? context.workingDirectory
        guard let command = forkCommand(for: session) else {
            resume(session, context: context)
            return
        }

        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = workingDirectory
        configuration.command = TerminalController.replaySurvivalCommand(command)
        let parent = TerminalController.all.first(where: {
            $0.tabSessionID == context.tabID
        })?.window ?? TerminalController.preferredParent?.window
        _ = TerminalController.newTab(
            appDelegate.ghostty,
            from: parent,
            withBaseConfig: configuration
        )
    }

    nonisolated static func forkCommand(for session: AgentHistorySession) -> String? {
        let agent = session.agent
        let definition = agent.definition
        let id = session.conversationID.rawValue
        var argv: [String] = [definition.command]

        switch agent {
        case .pi:
            argv.append(contentsOf: ["--fork", id])
        case .claude:
            argv.append(contentsOf: ["--resume", id, "--fork-session"])
        case .codex:
            argv = [definition.command, "fork", id]
        case .qoder:
            argv.append(contentsOf: ["--resume", id, "--fork-session"])
        case .omp:
            argv.append(contentsOf: ["--resume=\(id)"])
        case .qwen:
            argv.append(contentsOf: ["--resume", id])
        default:
            return nil
        }

        let invocation = argv.map(shellQuote).joined(separator: " ")
        let shell = "\"${SHELL:-/bin/zsh}\""
        return "\(shell) -l -i -c \(shellQuote(invocation)); exec \(shell) -l"
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
