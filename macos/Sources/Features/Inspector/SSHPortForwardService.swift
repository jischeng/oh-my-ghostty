import AppKit
import Foundation
import OSLog

/// Owns SSH local port forwards: the persisted intent, the app-owned `ssh -L`
/// processes behind it, and the listener-process names shown beside each port.
///
/// The service knows nothing about the Inspector. Its owner tells it which SSH
/// sessions are presented and is told when the presented list changed.
@MainActor
final class SSHPortForwardService {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "ssh-port-forwarding"
    )

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

    private struct RuntimeForward {
        let desired: DesiredForward
        let alias: String
        let localPort: Int
        let token: UUID
        let stop: () -> Void
        var processName: String?
        var status: InspectorPortForwardStatus
    }

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

    /// Sessions of the panes whose forwards are on screen. They keep plain
    /// `ssh` forwards alive and decide which listeners are worth probing.
    var presentedSessions: () -> [PaneSessionContext] = { [] }
    /// Called when a presented list may differ from what was last read.
    var onChange: () -> Void = {}

    init(
        persistenceURL: URL? = nil,
        processLauncher: @escaping ProcessLauncher = SSHPortForwardService.launchProcess,
        localPortAllocator: @escaping LocalPortAllocator = SSHPortForwardService.allocateLocalPort,
        forwardReadiness: @escaping ForwardReadiness = SSHPortForwardService.waitUntilForwardReady,
        remoteProcessBatchResolver: @escaping RemoteProcessBatchResolver = SSHPortForwardService.resolveRemoteProcesses,
        processRefreshInterval: Duration = .seconds(30),
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        copyAddress: @escaping AddressCopier = SSHPortForwardService.copyToPasteboard
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
        self.persistenceURL = resolvedPersistenceURL
        self.processLauncher = processLauncher
        self.localPortAllocator = localPortAllocator
        self.forwardReadiness = forwardReadiness
        self.remoteProcessResolver = remoteProcessBatchResolver
        self.processRefreshInterval = processRefreshInterval
        self.openURL = openURL
        self.copyAddress = copyAddress
        self.desiredForwards = Self.loadDesiredForwards(from: resolvedPersistenceURL)
    }

    deinit {
        processRefreshTask?.cancel()
    }

    func shutdown() {
        let running = runtimeForwards.values
        runtimeForwards.removeAll()
        processRefreshTask?.cancel()
        processRefreshTask = nil
        processRefreshDemand.removeAll()
        processRefreshGeneration = UUID()
        for forward in running { forward.stop() }
    }

    /// Reconciles registered-server forwards with the connections that are
    /// ready now: stale ones stop, persisted ones for a ready server start.
    func synchronizeConnections(_ next: ConnectionServers) {
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
        onChange()
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

    /// The forwards a pane shows for its current connection state.
    func list(for session: PaneSessionContext) -> InspectorPortForwardList {
        switch session.state {
        case .local:
            .init(hostAlias: "", items: [])
        case .sshConnecting(let ssh):
            .init(hostAlias: ssh.alias, items: [], canCreate: false)
        case .sshReady(let ssh, _):
            content(for: Self.forwardingIdentity(for: ssh), alias: ssh.alias)
        }
    }

    /// Plain SSH panes follow the presented panes rather than registry
    /// connections, and only presented listeners are probed.
    func presentedSessionsDidChange() {
        reconcilePaneForwards()
        reconcileProcessRefresh()
    }

    func create(target targetValue: String, session: PaneSessionContext) {
        guard let server = Self.readyServer(session),
              let target = PortForwardTarget.parse(targetValue) else { return }
        let desired = DesiredForward(
            serverID: server.id,
            remoteHost: target.host,
            remotePort: target.port
        )
        guard desiredForwards.insert(desired).inserted else { return }
        persistDesiredForwards()
        startRuntimeForward(desired, alias: server.alias)
        onChange()
    }

    /// Opening a browser is an explicit user action on an active forward.
    func open(id: String) {
        guard let runtime = runtimeForwards[id],
              runtime.status == .active,
              let url = URL(string: "http://127.0.0.1:\(runtime.localPort)") else { return }
        openURL(url)
    }

    func copy(id: String) {
        guard let runtime = runtimeForwards[id], runtime.status == .active else { return }
        copyAddress("localhost:\(runtime.localPort)")
    }

    func remove(id: String) {
        guard let desired = desiredForwards.first(where: { $0.id == id }) else { return }
        desiredForwards.remove(desired)
        stopRuntimeForward(id: id)
        persistDesiredForwards()
        onChange()
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
                    onChange()
                    return
                }
                runtime.status = .active
                runtimeForwards[desired.id] = runtime
                onChange()
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
        let visibleServers = Set(presentedSessions().compactMap { Self.readyServer($0)?.id })
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
        if changed { onChange() }
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
        onChange()
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
        _ session: PaneSessionContext
    ) -> (id: String, alias: String)? {
        guard case .sshReady(let ssh, _) = session.state else { return nil }
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
        for session in presentedSessions() {
            guard case .sshReady(let ssh, _) = session.state else { continue }
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
