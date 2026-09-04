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
    typealias TranscriptLoader = (AgentHistorySession) async -> AgentHistoryTranscript
    typealias SessionResumer = (AgentHistorySession, InspectorPaneContext) -> Void
    typealias SessionForker = (AgentHistorySession, InspectorPaneContext) -> Void

    private struct TabState {
        var selectedSessionID: String?
        var transcript: AgentHistoryTranscript?
        var isLoadingTranscript = false
    }

    private let registry: InspectorRegistry
    private let cachedSessionLoader: SessionLoader
    private let sessionLoader: SessionLoader
    private let transcriptLoader: TranscriptLoader
    private let sessionResumer: SessionResumer
    private let sessionForker: SessionForker
    private var sessions: [AgentHistorySession]?
    private var isLoadingSessions = false
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
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
                        sessions = nil
                    } else {
                        reload()
                    }
                }
            }
        })
    }

    deinit {
        loadTask?.cancel()
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
            publish(context)
            if sessions == nil, !isLoadingSessions { loadOnDemand() }
        case .disappeared(let context):
            // Context replacement is delivered as disappeared + appeared for
            // the same tab. Defer cleanup one runloop so replacement does not
            // cancel useful work, while a genuinely hidden Inspector leaves no
            // cache scan or transcript parser running in the background.
            presentedContexts.removeValue(forKey: context.tabID)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      presentedContexts[context.tabID] == nil,
                      presentedContexts.isEmpty else { return }
                loadTask?.cancel()
                loadTask = nil
                isLoadingSessions = false
                for task in transcriptTasks.values { task.cancel() }
                transcriptTasks.removeAll()
                for tabID in Array(tabStates.keys) where
                    tabStates[tabID]?.isLoadingTranscript == true {
                    tabStates[tabID] = .init()
                }
            }
        }
    }

    private func handle(_ action: InspectorPaneAction) {
        switch action.kind {
        case .refreshAgentHistory:
            reload()
        case .selectAgentHistorySession(let id):
            selectSession(id, context: action.context)
        case .clearAgentHistorySelection:
            clearSelection(context: action.context)
        case .resumeAgentHistorySession(let id):
            guard let session = sessions?.first(where: { $0.id == id }) else {
                return
            }
            sessionResumer(session, action.context)
            publishPresentedContexts()
        case .forkAgentHistorySession(let id):
            guard let session = sessions?.first(where: { $0.id == id }) else {
                return
            }
            sessionForker(session, action.context)
            publishPresentedContexts()
        default:
            break
        }
    }

    private func loadOnDemand() {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoadingSessions = true
        publishPresentedContexts()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let cached = await cachedSessionLoader()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            if !cached.isEmpty {
                applyLoadedSessions(cached)
                isLoadingSessions = false
                publishPresentedContexts()
            }

            guard !presentedContexts.isEmpty else {
                loadTask = nil
                isLoadingSessions = false
                return
            }
            let refreshed = await sessionLoader()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            applyLoadedSessions(refreshed)
            isLoadingSessions = false
            loadTask = nil
            publishPresentedContexts()
        }
    }

    private func reload() {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoadingSessions = true
        publishPresentedContexts()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await sessionLoader()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            applyLoadedSessions(loaded)
            isLoadingSessions = false
            loadTask = nil
            publishPresentedContexts()
        }
    }

    private func applyLoadedSessions(_ loaded: [AgentHistorySession]) {
        sessions = loaded
        let availableIDs = Set(loaded.map(\.id))
        for tabID in Array(tabStates.keys) where
            tabStates[tabID]?.selectedSessionID.map({
                !availableIDs.contains($0)
            }) == true {
            tabStates[tabID] = .init()
        }
    }

    private func selectSession(
        _ id: String,
        context: InspectorPaneContext
    ) {
        guard let session = sessions?.first(where: { $0.id == id }) else {
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
        tabStates[context.tabID] = .init()
        publish(context)
    }

    private func publishPresentedContexts() {
        for context in presentedContexts.values { publish(context) }
    }

    private func publish(_ context: InspectorPaneContext) {
        let state = tabStates[context.tabID] ?? .init()
        let activeIDs = Self.activeSessionIDs()
        let presentedSessions = (sessions ?? []).map { session in
            var session = session
            session.isActive = activeIDs.contains(session.id)
            return session
        }
        do {
            try registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
                tabID: context.tabID,
                content: .agentHistory(.init(
                    sessions: presentedSessions,
                    selectedSessionID: state.selectedSessionID,
                    transcript: state.transcript,
                    isLoadingSessions: isLoadingSessions,
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
                      descriptor.scope == .local,
                      let conversationID = descriptor.conversationID else { continue }
                result.insert("\(descriptor.agent.rawValue):\(conversationID.rawValue)")
            }
        }
        return result
    }

    private static func resume(
        _ session: AgentHistorySession,
        context: InspectorPaneContext
    ) {
        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                guard let descriptor = controller.agentResumeDescriptor(for: surface),
                      descriptor.scope == .local,
                      descriptor.agent == session.agent,
                      descriptor.conversationID == session.conversationID else {
                    continue
                }
                controller.focusSurface(surface)
                return
            }
        }

        guard FileManager.default.fileExists(atPath: session.sourcePath),
              let appDelegate = NSApp.delegate as? AppDelegate,
              let executablePath = Bundle.main.executablePath else { return }
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
        guard FileManager.default.fileExists(atPath: session.sourcePath),
              let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let workingDirectory = session.workingDirectory ?? context.workingDirectory
        guard let command = forkCommand(for: session) else {
            // Fallback to regular resume if agent doesn't define custom fork
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
