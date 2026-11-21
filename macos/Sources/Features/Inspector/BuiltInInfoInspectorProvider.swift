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
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "ssh-port-forwarding"
    )

    static let featureID = "builtin.info"
    static let paneID = "builtin.info"

    struct DesiredForward: Codable, Equatable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case serverID
            case remoteHost
            case remotePort
        }

        let serverID: String
        let remoteHost: String
        let remotePort: Int

        var id: String { "\(serverID)|\(remoteHost)|\(remotePort)" }
        var target: PortForwardTarget {
            .init(host: remoteHost, port: remotePort)
        }

        init(serverID: String, remoteHost: String, remotePort: Int) {
            self.serverID = serverID
            self.remoteHost = remoteHost
            self.remotePort = remotePort
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            serverID = try values.decode(String.self, forKey: .serverID)
            remoteHost = try values.decodeIfPresent(
                String.self,
                forKey: .remoteHost
            ) ?? PortForwardTarget.loopbackHost
            remotePort = try values.decode(Int.self, forKey: .remotePort)
        }
    }

    struct ConnectionServers: Equatable {
        var connected: Set<String> = []
        var readyAliases: [String: String] = [:]
    }

    typealias ProcessLauncher = (
        _ alias: String,
        _ remoteHost: String,
        _ remotePort: Int,
        _ localPort: Int,
        _ termination: @escaping (Int32, String) -> Void
    ) throws -> () -> Void
    typealias LocalPortAllocator = (_ preferredPort: Int) throws -> Int
    typealias ForwardReadiness = (_ localPort: Int) async -> Bool
    typealias RemoteProcessBatchResolver = (_ alias: String, _ ports: [Int]) async throws -> [Int: String]
    enum ProcessProbeError: Error { case unavailable, invalidOutput }

    private struct ProcessProbe: Hashable {
        let id: String
        let token: UUID
        let alias: String
        let port: Int
    }

    typealias URLOpener = (URL) -> Void
    typealias AddressCopier = (String) -> Void
    /// Locates a local conversation's transcript file, or nil if none exists yet.
    typealias AgentSessionResolver = @Sendable (SupportedAgent, AgentConversationID) async -> String?

    private struct AgentSessionKey: Hashable {
        let agent: SupportedAgent
        let conversationID: AgentConversationID
    }

    private enum AgentSessionLookup {
        case pending
        case resolved(String)
        /// Not found at this time; a new conversation may not be on disk yet.
        case missing(ContinuousClock.Instant)
    }

    private struct RuntimeForward {
        let desired: DesiredForward
        let alias: String
        let localPort: Int
        let token: UUID
        let stop: () -> Void
        var processName: String?
        var status: InspectorPortForwardStatus
    }

    private let registry: InspectorRegistry
    private let persistenceURL: URL
    private let processLauncher: ProcessLauncher
    private let localPortAllocator: LocalPortAllocator
    private let forwardReadiness: ForwardReadiness
    private let remoteProcessResolver: RemoteProcessBatchResolver
    private let processRefreshInterval: Duration
    private let openURL: URLOpener
    private let copyAddress: AddressCopier
    private var desiredForwards: Set<DesiredForward>
    private var runtimeForwards: [String: RuntimeForward] = [:]
    private var processRefreshTask: Task<Void, Never>?
    private var processRefreshDemand: Set<ProcessProbe> = []
    private var processRefreshGeneration = UUID()
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var servers = ConnectionServers()
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
        processLauncher: @escaping ProcessLauncher = BuiltInInfoInspectorProvider.launchProcess,
        localPortAllocator: @escaping LocalPortAllocator = BuiltInInfoInspectorProvider.allocateLocalPort,
        forwardReadiness: @escaping ForwardReadiness = BuiltInInfoInspectorProvider.waitUntilForwardReady,
        remoteProcessBatchResolver: @escaping RemoteProcessBatchResolver = BuiltInInfoInspectorProvider.resolveRemoteProcesses,
        processRefreshInterval: Duration = .seconds(30),
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        copyAddress: @escaping AddressCopier = BuiltInInfoInspectorProvider.copyToPasteboard,
        historyService: TerminalHistoryService? = nil,
        agentSessionRetryInterval: Duration = .seconds(15),
        agentSessionResolver: @escaping AgentSessionResolver = { agent, conversationID in
            await AgentHistoryStore.session(agent: agent, conversationID: conversationID)?.sourcePath
        }
    ) {
        let support = OMGApplicationEnvironment.applicationSupportURL()
        let resolvedPersistenceURL = persistenceURL ?? support.appendingPathComponent("Info/port-forwards.json")
        // Preserve existing forwards without depending on plugin installation.
        if persistenceURL == nil, !FileManager.default.fileExists(atPath: resolvedPersistenceURL.path) {
            let legacy = support.appendingPathComponent("PluginData/builtin.ssh/port-forwards.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.createDirectory(at: resolvedPersistenceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? FileManager.default.copyItem(at: legacy, to: resolvedPersistenceURL)
            }
        }
        self.registry = registry
        self.persistenceURL = resolvedPersistenceURL
        self.processLauncher = processLauncher
        self.localPortAllocator = localPortAllocator
        self.forwardReadiness = forwardReadiness
        self.remoteProcessResolver = remoteProcessBatchResolver
        self.processRefreshInterval = processRefreshInterval
        self.openURL = openURL
        self.copyAddress = copyAddress
        self.desiredForwards = Self.loadDesiredForwards(from: resolvedPersistenceURL)
        self.historyService = historyService ?? .shared
        self.agentSessionResolver = agentSessionResolver
        self.agentSessionRetryInterval = agentSessionRetryInterval

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
        processRefreshTask?.cancel()
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
        let running = runtimeForwards.values
        runtimeForwards.removeAll()
        processRefreshTask?.cancel()
        processRefreshTask = nil
        processRefreshDemand.removeAll()
        processRefreshGeneration = UUID()
        for forward in running { forward.stop() }
    }

    func synchronizeConnections(_ next: ConnectionServers) {
        servers = next
        let paneIdentities = livePaneIdentities()
        // Registry connections still own registered forwards; plain panes keep
        // only their destination identities alive.
        let connected = next.connected.union(
            paneIdentities.keys.filter { $0.hasPrefix(Self.paneIdentityPrefix) }
        )

        let staleIDs = runtimeForwards.compactMap { id, runtime in
            connected.contains(runtime.desired.serverID) ? nil : id
        }
        for id in staleIDs { stopRuntimeForward(id: id) }

        for desired in desiredForwards where runtimeForwards[desired.id] == nil {
            guard let alias = next.readyAliases[desired.serverID]
                ?? (desired.serverID.hasPrefix(Self.paneIdentityPrefix)
                    ? paneIdentities[desired.serverID] : nil) else { continue }
            startRuntimeForward(desired, alias: alias)
        }
        reconcileProcessRefresh()
        publishPresentedContexts()
    }

    func content(for serverID: String, alias: String) -> InspectorPortForwardList {
        let items = desiredForwards
            .filter { $0.serverID == serverID }
            .sorted {
                $0.remoteHost == $1.remoteHost
                    ? $0.remotePort < $1.remotePort
                    : $0.remoteHost < $1.remoteHost
            }
            .map { desired -> InspectorPortForwardItem in
                guard let runtime = runtimeForwards[desired.id] else {
                    return .init(
                        id: desired.id,
                        remoteHost: desired.remoteHost,
                        remotePort: desired.remotePort,
                        localPort: nil,
                        processName: nil,
                        status: .starting
                    )
                }
                return .init(
                    id: desired.id,
                    remoteHost: desired.remoteHost,
                    remotePort: desired.remotePort,
                    localPort: runtime.localPort,
                    processName: runtime.processName,
                    status: runtime.status
                )
            }
        return .init(hostAlias: alias, items: items)
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            presentedContexts[context.tabID] = context
            agentHistory.retain(surfaces: Set(presentedContexts.values.compactMap(\.surfaceID)))
            observeAgentDescriptors(for: context)
            publish(context)
            reconcilePaneForwards()
        case .disappeared(let context):
            presentedContexts.removeValue(forKey: context.tabID)
            agentDescriptorObservers.removeValue(forKey: context.tabID)
            agentHistory.retain(surfaces: Set(presentedContexts.values.compactMap(\.surfaceID)))
            reconcilePaneForwards()
        }
        reconcileProcessRefresh()
    }

    private func handle(_ action: InspectorPaneAction) {
        switch action.kind {
        case .createPortForward(let targetValue):
            guard let server = Self.readyServer(action.context),
                  let target = PortForwardTarget.parse(targetValue) else { return }
            let desired = DesiredForward(
                serverID: server.id,
                remoteHost: target.host,
                remotePort: target.port
            )
            guard desiredForwards.insert(desired).inserted else { return }
            persistDesiredForwards()
            startRuntimeForward(desired, alias: server.alias)
            publishPresentedContexts()

        case .openPortForward(let id):
            guard let runtime = runtimeForwards[id],
                  runtime.status == .active,
                  let url = URL(string: "http://127.0.0.1:\(runtime.localPort)") else { return }
            openURL(url)

        case .copyPortForward(let id):
            guard let runtime = runtimeForwards[id], runtime.status == .active else { return }
            copyAddress("localhost:\(runtime.localPort)")

        case .removePortForward(let id):
            guard let desired = desiredForwards.first(where: { $0.id == id }) else { return }
            desiredForwards.remove(desired)
            stopRuntimeForward(id: id)
            persistDesiredForwards()
            publishPresentedContexts()

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

    private func startRuntimeForward(_ desired: DesiredForward, alias: String) {
        guard runtimeForwards[desired.id] == nil else { return }
        do {
            let localPort = try localPortAllocator(desired.remotePort)
            let token = UUID()
            let stop = try processLauncher(
                alias,
                desired.remoteHost,
                desired.remotePort,
                localPort
            ) { [weak self] status, errorOutput in
                Task { @MainActor [weak self] in
                    self?.processDidTerminate(
                        id: desired.id,
                        token: token,
                        status: status,
                        errorOutput: errorOutput
                    )
                }
            }
            runtimeForwards[desired.id] = .init(
                desired: desired,
                alias: alias,
                localPort: localPort,
                token: token,
                stop: stop,
                processName: nil,
                status: .starting
            )
            Task { [weak self] in
                guard let self else { return }
                let ready = await forwardReadiness(localPort)
                guard var runtime = runtimeForwards[desired.id],
                      runtime.token == token,
                      runtime.status == .starting else { return }
                guard ready else {
                    runtime.status = .failed(
                        InfoStrings.current.listenerTimeout(localPort: localPort)
                    )
                    runtimeForwards[desired.id] = runtime
                    runtime.stop()
                    publishPresentedContexts()
                    return
                }
                runtime.status = .active
                runtimeForwards[desired.id] = runtime
                publishPresentedContexts()
                reconcileProcessRefresh()
            }
        } catch {
            let message = Self.failureDescription(error)
            Self.logger.error(
                "failed to start SSH forward alias=\(alias, privacy: .public) remote=\(desired.remotePort) error=\(message, privacy: .public)"
            )
            runtimeForwards[desired.id] = .init(
                desired: desired,
                alias: alias,
                localPort: 0,
                token: UUID(),
                stop: {},
                processName: nil,
                status: .failed(message)
            )
        }
    }

    private func reconcileProcessRefresh() {
        let visibleServers = Set(presentedContexts.values.compactMap { Self.readyServer($0)?.id })
        let demand = Set(runtimeForwards.compactMap { id, runtime -> ProcessProbe? in
            guard runtime.status == .active, runtime.desired.target.isLoopback,
                  visibleServers.contains(runtime.desired.serverID) else { return nil }
            return .init(id: id, token: runtime.token, alias: runtime.alias, port: runtime.desired.remotePort)
        })
        guard demand != processRefreshDemand else { return }
        let previous = processRefreshTask
        previous?.cancel()
        processRefreshDemand = demand
        let generation = UUID()
        processRefreshGeneration = generation
        let resolver = remoteProcessResolver
        let interval = processRefreshInterval
        // A replacement waits for cancellation to settle, so rapid visibility
        // changes cannot overlap old and new SSH subprocesses.
        processRefreshTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, !demand.isEmpty else { return }
            let groups = Dictionary(grouping: demand, by: \.alias)
            var failures: [String: Int] = [:]
            var roundsUntilRetry: [String: Int] = [:]
            while !Task.isCancelled {
                for alias in groups.keys.sorted() {
                    guard !Task.isCancelled, let probes = groups[alias] else { return }
                    if let rounds = roundsUntilRetry[alias], rounds > 0 {
                        roundsUntilRetry[alias] = rounds - 1
                        continue
                    }
                    do {
                        let names = try await resolver(alias, Array(Set(probes.map(\.port))).sorted())
                        guard !Task.isCancelled else { return }
                        self?.applyProcessNames(names, probes: probes, generation: generation)
                        failures[alias] = 0
                    } catch {
                        guard !Task.isCancelled else { return }
                        // Retain cached names on transport/tool failure, and
                        // retry after 2/4 base intervals (60/120s by default).
                        let count = min(2, (failures[alias] ?? 0) + 1)
                        failures[alias] = count
                        roundsUntilRetry[alias] = (1 << count) - 1
                    }
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func applyProcessNames(_ names: [Int: String], probes: [ProcessProbe], generation: UUID) {
        guard generation == processRefreshGeneration else { return }
        var changed = false
        for probe in probes {
            guard var runtime = runtimeForwards[probe.id], runtime.token == probe.token,
                  runtime.status == .active else { continue }
            let name = names[probe.port]
            if runtime.processName != name {
                runtime.processName = name
                runtimeForwards[probe.id] = runtime
                changed = true
            }
        }
        if changed { publishPresentedContexts() }
    }

    private func stopRuntimeForward(id: String) {
        guard let runtime = runtimeForwards.removeValue(forKey: id) else { return }
        runtime.stop()
        reconcileProcessRefresh()
    }

    private func processDidTerminate(
        id: String,
        token: UUID,
        status: Int32,
        errorOutput: String
    ) {
        guard var runtime = runtimeForwards[id], runtime.token == token else { return }
        if case .failed = runtime.status {
            return
        }
        runtime.status = .failed(Self.sshFailureDescription(
            status: status,
            errorOutput: errorOutput,
            localPort: runtime.localPort
        ))
        runtimeForwards[id] = runtime
        reconcileProcessRefresh()
        publishPresentedContexts()
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

    /// Returns the cached transcript path, locating it once in the background.
    private func agentSessionPath(agent: SupportedAgent, conversationID: AgentConversationID) -> String? {
        let key = AgentSessionKey(agent: agent, conversationID: conversationID)
        switch agentSessions[key] {
        case .resolved(let path):
            return path
        case .pending:
            return nil
        case .missing(let at) where ContinuousClock.now - at < agentSessionRetryInterval:
            return nil
        case .missing, nil:
            break
        }
        agentSessions[key] = .pending
        let resolver = agentSessionResolver
        Task { [weak self] in
            let path = await resolver(agent, conversationID)
            guard let self else { return }
            agentSessions[key] = path.map(AgentSessionLookup.resolved) ?? .missing(.now)
            if path != nil { publishPresentedContexts() }
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
        let forwards: InspectorPortForwardList = switch session.state {
        case .local:
            .init(hostAlias: "", items: [])
        case .sshConnecting(let ssh):
            .init(hostAlias: ssh.alias, items: [], canCreate: false)
        case .sshReady(let ssh, _):
            self.content(for: Self.forwardingIdentity(for: ssh), alias: ssh.alias)
        }
        let content = InspectorPaneContent.info(.init(
            portForwards: forwards, historyItems: historyInfo.items,
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

    private func persistDesiredForwards() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let forwards = desiredForwards.sorted {
                if $0.serverID != $1.serverID { return $0.serverID < $1.serverID }
                if $0.remoteHost != $1.remoteHost { return $0.remoteHost < $1.remoteHost }
                return $0.remotePort < $1.remotePort
            }
            try JSONEncoder().encode(forwards).write(to: persistenceURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: persistenceURL.path
            )
        } catch {
            Self.logger.error("failed to persist SSH forwards: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadDesiredForwards(from url: URL) -> Set<DesiredForward> {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DesiredForward].self, from: data) else {
            return []
        }
        return Set(decoded.filter { validDesiredForward($0) })
    }

    private static func validDesiredForward(_ forward: DesiredForward) -> Bool {
        guard validServerID(forward.serverID), validPort(forward.remotePort) else {
            return false
        }
        let host = forward.remoteHost.contains(":")
            ? "[\(forward.remoteHost)]"
            : forward.remoteHost
        return PortForwardTarget.parse("\(host):\(forward.remotePort)") != nil
    }

    nonisolated static func validPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    nonisolated private static func validServerID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".:_+-/=")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func readyServer(
        _ context: InspectorPaneContext
    ) -> (id: String, alias: String)? {
        guard case .sshReady(let ssh, _) = context.session.state else { return nil }
        return (forwardingIdentity(for: ssh), ssh.alias)
    }

    /// Stable identity used to persist and reconcile a pane's port forwards.
    ///
    /// `omg +ssh` panes carry a verified server ID. Plain `ssh` panes inferred
    /// from the foreground process only know their destination, so their
    /// forwards follow the pane lifecycle under a destination identity.
    /// Forwards still launch through the pane's own SSH alias, which resolves
    /// the user's OpenSSH configuration.
    private static func forwardingIdentity(for ssh: PaneSessionContext.SSH) -> String {
        if let serverID = ssh.serverID { return serverID }
        return paneIdentityPrefix + ssh.alias
    }

    private static let paneIdentityPrefix = "ssh-destination:"

    /// Identities and aliases of SSH panes that are ready right now.
    private func livePaneIdentities() -> [String: String] {
        var result: [String: String] = [:]
        for context in presentedContexts.values {
            guard case .sshReady(let ssh, _) = context.session.state else { continue }
            result[Self.forwardingIdentity(for: ssh)] = ssh.alias
        }
        return result
    }

    /// Plain SSH panes are not registry connections, so their persisted
    /// forwards follow the pane lifecycle instead of `synchronizeConnections`.
    private func reconcilePaneForwards() {
        let live = livePaneIdentities()
        let stale = runtimeForwards.compactMap { id, runtime -> String? in
            runtime.desired.serverID.hasPrefix(Self.paneIdentityPrefix) &&
                live[runtime.desired.serverID] == nil ? id : nil
        }
        for id in stale { stopRuntimeForward(id: id) }
        for desired in desiredForwards
        where desired.serverID.hasPrefix(Self.paneIdentityPrefix) && runtimeForwards[desired.id] == nil {
            guard let alias = live[desired.serverID] else { continue }
            startRuntimeForward(desired, alias: alias)
        }
    }
}
