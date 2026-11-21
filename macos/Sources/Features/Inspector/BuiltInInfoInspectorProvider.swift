import AppKit
import Combine
import Foundation
import OSLog

extension Notification.Name {
    static let terminalHistoryDidChange = Notification.Name("com.oh-my-ghostty.terminal-history-did-change")
    static let terminalPaneSessionContextsDidChange = Notification.Name(
        "com.oh-my-ghostty.terminal-pane-session-contexts-did-change"
    )
}

@MainActor
final class BuiltInInfoInspectorProvider {
    // Shares the forwarding category so existing log filters keep working.
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "ssh-port-forwarding"
    )

    static let featureID = "builtin.info"
    static let paneID = "builtin.info"

    typealias DesiredForward = SSHPortForwardService.DesiredForward
    typealias ConnectionServers = SSHPortForwardService.ConnectionServers
    typealias ProcessLauncher = SSHPortForwardService.ProcessLauncher
    typealias LocalPortAllocator = SSHPortForwardService.LocalPortAllocator
    typealias ForwardReadiness = SSHPortForwardService.ForwardReadiness
    typealias RemoteProcessBatchResolver = SSHPortForwardService.RemoteProcessBatchResolver
    typealias ProcessProbeError = SSHPortForwardService.ProcessProbeError
    typealias URLOpener = SSHPortForwardService.URLOpener
    typealias AddressCopier = SSHPortForwardService.AddressCopier
    /// Locates a local conversation's transcript file, or nil if none exists yet.
    typealias AgentSessionResolver = @Sendable (SupportedAgent, AgentConversationID) async -> String?

    private struct AgentSessionKey: Hashable {
        let agent: SupportedAgent
        let conversationID: AgentConversationID
    }

    private enum AgentSessionLookup {
        case pending(attempt: Int)
        case resolved(String)
        /// Not found at this time; a new conversation may not be on disk yet.
        case missing(ContinuousClock.Instant, attempt: Int)
    }

    /// An Agent writes its transcript on the first message, after it has
    /// attached to the pane, and nothing else republishes Info at that point.
    /// A few timed retries cover that gap without polling indefinitely.
    static let agentSessionTimedRetries = 6

    private let registry: InspectorRegistry
    private let portForwards: SSHPortForwardService
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var isRegistered = false
    private var notificationObservers: [NSObjectProtocol] = []
    private let historyService: TerminalHistoryService
    // Keep the Agent reader for future verified message anchors, but do not
    // subscribe or publish transcript-only rows in the Info navigation UI.
    private let agentHistory = PaneAgentHistoryService()
    private static let agentHistoryNavigationEnabled = false
    private let agentSessionResolver: AgentSessionResolver
    private let agentSessionRetryInterval: Duration
    private var agentSessions: [AgentSessionKey: AgentSessionLookup] = [:]
    private var agentDescriptorObservers: [UUID: AnyCancellable] = [:]

    init(
        registry: InspectorRegistry,
        persistenceURL: URL? = nil,
        processLauncher: @escaping ProcessLauncher = SSHPortForwardService.launchProcess,
        localPortAllocator: @escaping LocalPortAllocator = SSHPortForwardService.allocateLocalPort,
        forwardReadiness: @escaping ForwardReadiness = SSHPortForwardService.waitUntilForwardReady,
        remoteProcessBatchResolver: @escaping RemoteProcessBatchResolver = SSHPortForwardService.resolveRemoteProcesses,
        processRefreshInterval: Duration = .seconds(30),
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        copyAddress: @escaping AddressCopier = SSHPortForwardService.copyToPasteboard,
        historyService: TerminalHistoryService? = nil,
        agentSessionRetryInterval: Duration = .seconds(15),
        agentSessionResolver: @escaping AgentSessionResolver = { agent, conversationID in
            await AgentHistoryStore.session(agent: agent, conversationID: conversationID)?.sourcePath
        }
    ) {
        self.registry = registry
        self.portForwards = SSHPortForwardService(
            persistenceURL: persistenceURL,
            processLauncher: processLauncher,
            localPortAllocator: localPortAllocator,
            forwardReadiness: forwardReadiness,
            remoteProcessBatchResolver: remoteProcessBatchResolver,
            processRefreshInterval: processRefreshInterval,
            openURL: openURL,
            copyAddress: copyAddress
        )
        self.historyService = historyService ?? .shared
        self.agentSessionResolver = agentSessionResolver
        self.agentSessionRetryInterval = agentSessionRetryInterval
        portForwards.presentedSessions = { [weak self] in
            self?.presentedContexts.values.map(\.session) ?? []
        }
        portForwards.onChange = { [weak self] in self?.publishPresentedContexts() }

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalHistoryDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let surfaceID = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRegistered else { return }
                for context in self.presentedContexts.values where context.surfaceID == surfaceID {
                    self.publish(context)
                }
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPaneSessionContextsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeWithTerminalControllers()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: OhMyGhosttySettings.didChangeNotification,
            object: OhMyGhosttySettings.shared,
            queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?[
                OhMyGhosttySettings.changedKeyUserInfoKey
            ] as? String == "general.language" else { return }
            Task { @MainActor [weak self] in
                self?.refreshLocalization()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.synchronizeWithTerminalControllers()
            }
        })
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isRegistered else { return }
        if enabled {
            let descriptor = InspectorPaneDescriptor(
                id: Self.paneID,
                title: InfoStrings.current.infoTitle,
                systemImage: "info.circle",
                source: .coreFeature(Self.featureID),
                preferredWidth: RightInspectorMetrics.defaultWidth,
                minimumWidth: 240
            )
            try registry.registerCorePane(
                descriptor,
                lifecycle: { [weak self] event in self?.handle(event) },
                action: { [weak self] action in self?.handle(action) }
            )
            isRegistered = true
            synchronizeWithTerminalControllers()
        } else {
            shutdown()
            presentedContexts.removeAll()
            agentDescriptorObservers.removeAll()
            registry.unregister(source: .coreFeature(Self.featureID))
            isRegistered = false
        }
    }

    private func refreshLocalization() {
        guard isRegistered else { return }
        do {
            try registry.updateCorePaneTitle(
                paneID: Self.paneID,
                featureID: Self.featureID,
                title: InfoStrings.current.infoTitle
            )
        } catch {
            Self.logger.error(
                "failed to localize Info Inspector: \(error.localizedDescription, privacy: .public)"
            )
        }
        publishPresentedContexts()
    }

    func shutdown() {
        agentHistory.shutdown()
        portForwards.shutdown()
    }

    func synchronizeConnections(_ next: ConnectionServers) {
        portForwards.synchronizeConnections(next)
    }

    func content(for serverID: String, alias: String) -> InspectorPortForwardList {
        portForwards.content(for: serverID, alias: alias)
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            presentedContexts[context.tabID] = context
            agentHistory.retain(surfaces: Set(presentedContexts.values.compactMap(\.surfaceID)))
            observeAgentDescriptors(for: context)
            publish(context)
        case .disappeared(let context):
            presentedContexts.removeValue(forKey: context.tabID)
            agentDescriptorObservers.removeValue(forKey: context.tabID)
            agentHistory.retain(surfaces: Set(presentedContexts.values.compactMap(\.surfaceID)))
        }
        portForwards.presentedSessionsDidChange()
    }

    private func handle(_ action: InspectorPaneAction) {
        switch action.kind {
        case .createPortForward(let target):
            portForwards.create(target: target, session: action.context.session)

        case .openPortForward(let id):
            portForwards.open(id: id)

        case .copyPortForward(let id):
            portForwards.copy(id: id)

        case .removePortForward(let id):
            portForwards.remove(id: id)

        case .jumpToHistoryItem(let item):
            guard let surfaceID = action.context.surfaceID else { return }
            for controller in TerminalFocusRouter.allTerminalControllers() {
                if let surfaceView = controller.surfaceTree.first(where: { $0.id == surfaceID }) {
                    if historyService.jump(to: item, in: surfaceView) != .jumped {
                        NSSound.beep()
                        publish(action.context)
                    }
                    return
                }
            }

        default:
            break
        }
    }

    private func synchronizeWithTerminalControllers() {
        var next = ConnectionServers()
        for context in TerminalController.all.flatMap(\.paneSessionContexts.values) {
            switch context.state {
            case .local, .sshConnecting:
                break
            case .sshReady(let ssh, _):
                guard let serverID = ssh.serverID else { continue }
                next.connected.insert(serverID)
                next.readyAliases[serverID] = ssh.alias
            }
        }
        synchronizeConnections(next)
    }

    private func publishPresentedContexts() {
        guard isRegistered else { return }
        for context in presentedContexts.values { publish(context) }
    }

    private struct History {
        var items: [InspectorHistoryItem] = []
        var isAgent = false
        var agentName: String?
        var state: PaneAgentHistoryService.State = .ready
    }

    static func hidesAgentHistory(descriptorPresent: Bool, activity: TabActivity?) -> Bool {
        // A status may remain at `done` or `error` while the Agent is still
        // running. Do not mistake that pane for a plain Shell when discovery
        // has not yet attached a resume descriptor.
        descriptorPresent || activity != nil
    }

    private func currentHistory(for context: InspectorPaneContext) -> History {
        guard let surfaceID = context.surfaceID else { return .init() }
        for controller in TerminalController.all {
            guard let view = controller.surfaceTree.first(where: { $0.id == surfaceID }) else { continue }
            let descriptor = controller.agentResumeDescriptor(for: view)
            if !Self.agentHistoryNavigationEnabled,
               Self.hidesAgentHistory(descriptorPresent: descriptor != nil,
                                      activity: controller.agentActivity(for: view)) {
                agentHistory.remove(surfaceID)
                return .init(items: historyService.commands(for: surfaceID), isAgent: true)
            }
            guard let descriptor else { continue }
            let session = controller.paneSessionContext(for: view) ?? context.session
            guard let binding = PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session) else {
                agentHistory.remove(surfaceID)
                return .init(isAgent: true, agentName: descriptor.agent.displayName, state: .unavailable)
            }
            let snapshot = agentHistory.observe(surfaceID: surfaceID, binding: binding) { [weak self] in
                self?.publishPresentedContexts()
            }
            return .init(items: snapshot.items, isAgent: true, agentName: descriptor.agent.displayName,
                         state: snapshot.state)
        }
        agentHistory.remove(surfaceID)
        return .init(items: historyService.commands(for: surfaceID))
    }

    /// An Agent attaches its conversation after the pane is already visible,
    /// without any terminal history or connection event to republish on.
    private func observeAgentDescriptors(for context: InspectorPaneContext) {
        guard let surfaceID = context.surfaceID,
              let controller = TerminalController.all.first(where: { controller in
                  controller.surfaceTree.contains { $0.id == surfaceID }
              }) else {
            agentDescriptorObservers.removeValue(forKey: context.tabID)
            return
        }
        let tabID = context.tabID
        agentDescriptorObservers[tabID] = controller.$agentResumeDescriptors
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRegistered,
                          let context = self.presentedContexts[tabID] else { return }
                    self.publish(context)
                }
            }
    }

    private func currentAgent(
        for context: InspectorPaneContext,
        session: PaneSessionContext
    ) -> InspectorInfoAgent? {
        guard let surfaceID = context.surfaceID else { return nil }
        for controller in TerminalController.all {
            guard let view = controller.surfaceTree.first(where: { $0.id == surfaceID }) else { continue }
            return agentInfo(descriptor: controller.agentResumeDescriptor(for: view), session: session)
        }
        return nil
    }

    /// Presents a conversation only while it belongs to the pane's current
    /// host; a descriptor from before a connection handoff is not this pane's.
    func agentInfo(descriptor: AgentResumeDescriptor?, session: PaneSessionContext) -> InspectorInfoAgent? {
        guard let descriptor,
              let binding = PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session)
        else { return nil }
        return .init(
            agent: binding.agent,
            conversationID: binding.conversationID.rawValue,
            // Only a local transcript is a file the user can open here.
            sessionPath: binding.remoteHost == nil
                ? agentSessionPath(agent: binding.agent, conversationID: binding.conversationID) : nil,
            remoteHost: binding.remoteHost
        )
    }

    /// Returns the cached transcript path, locating it in the background.
    private func agentSessionPath(agent: SupportedAgent, conversationID: AgentConversationID) -> String? {
        let key = AgentSessionKey(agent: agent, conversationID: conversationID)
        let attempt: Int
        switch agentSessions[key] {
        case .resolved(let path):
            return path
        case .pending:
            return nil
        case .missing(let at, _) where ContinuousClock.now - at < agentSessionRetryInterval:
            return nil
        case .missing(_, let previous):
            attempt = previous + 1
        case nil:
            attempt = 1
        }
        agentSessions[key] = .pending(attempt: attempt)
        let resolver = agentSessionResolver
        let retryInterval = agentSessionRetryInterval
        Task { [weak self] in
            let path = await resolver(agent, conversationID)
            guard let self else { return }
            guard path == nil else {
                agentSessions[key] = path.map(AgentSessionLookup.resolved)
                publishPresentedContexts()
                return
            }
            agentSessions[key] = .missing(.now, attempt: attempt)
            guard attempt <= Self.agentSessionTimedRetries else { return }
            // Each wait doubles, so six lookups span about a quarter of an
            // hour by default. Republishing asks again only while a presented
            // pane still shows this conversation; otherwise the retries stop.
            try? await Task.sleep(for: retryInterval * (1 << (attempt - 1)))
            publishPresentedContexts()
        }
        return nil
    }

    private func publish(_ context: InspectorPaneContext) {
        let historyInfo = currentHistory(for: context)
        let session = context.surfaceID.flatMap { surfaceID in
            TerminalController.all.lazy.compactMap { controller -> PaneSessionContext? in
                guard let view = controller.surfaceTree.first(where: { $0.id == surfaceID }) else { return nil }
                return controller.paneSessionContext(for: view)
            }.first
        } ?? context.session
        let content = InspectorPaneContent.info(.init(
            portForwards: portForwards.list(for: session), historyItems: historyInfo.items,
            agent: currentAgent(for: context, session: session),
            isAgentSession: historyInfo.isAgent, agentName: historyInfo.agentName,
            historyState: historyInfo.state
        ))
        do {
            try registry.updateCoreContent(
                paneID: Self.paneID,
                featureID: Self.featureID,
                tabID: context.tabID,
                content: content
            )
        } catch {
            Self.logger.error("failed to publish SSH Inspector content: \(error.localizedDescription, privacy: .public)")
        }
    }
}
