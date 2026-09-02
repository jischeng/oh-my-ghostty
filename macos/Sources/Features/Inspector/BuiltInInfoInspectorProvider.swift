import AppKit
import Darwin
import Foundation
import OSLog

extension Notification.Name {
    static let terminalPaneSessionContextsDidChange = Notification.Name(
        "com.oh-my-ghostty.terminal-pane-session-contexts-did-change"
    )
}

enum InspectorPortForwardStatus: Equatable, Sendable {
    case starting
    case active
    case failed(String)
}

struct InspectorPortForwardItem: Identifiable, Equatable, Sendable {
    let id: String
    let remoteHost: String
    let remotePort: Int
    let localPort: Int?
    let processName: String?
    let status: InspectorPortForwardStatus
}

struct InspectorPortForwardList: Equatable, Sendable {
    let hostAlias: String
    let items: [InspectorPortForwardItem]
}

struct PortForwardTarget: Equatable, Sendable {
    static let loopbackHost = "127.0.0.1"

    let host: String
    let port: Int

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    var sshHost: String { host.contains(":") ? "[\(host)]" : host }
    var displayValue: String {
        host == Self.loopbackHost ? String(port) : "\(sshHost):\(port)"
    }

    static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(value), validPort(port) {
            return .init(host: loopbackHost, port: port)
        }

        let host: String
        let portText: String
        if value.hasPrefix("["), let closing = value.lastIndex(of: "]"),
           value.index(after: closing) < value.endIndex,
           value[value.index(after: closing)] == ":" {
            host = String(value[value.index(after: value.startIndex)..<closing])
            portText = String(value[value.index(closing, offsetBy: 2)...])
        } else if let separator = value.lastIndex(of: ":"),
                  !value[..<separator].contains(":") {
            host = String(value[..<separator])
            portText = String(value[value.index(after: separator)...])
        } else {
            return nil
        }
        guard validHost(host), let port = Int(portText), validPort(port) else {
            return nil
        }
        return .init(host: host, port: port)
    }

    private static func validPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_:%")
        )
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct InspectorInfoContent: Equatable, Sendable {
    /// Reserved for a future machine-status summary. Nil keeps the section hidden.
    let status: InspectorField?
    let fields: [InspectorField]
    let portForwards: InspectorPortForwardList
}

@MainActor
final class BuiltInInfoInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "ssh-port-forwarding"
    )

    static let pluginID = SSHPlugin.pluginID
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
    typealias RemoteProcessResolver = (
        _ alias: String,
        _ remoteHost: String,
        _ remotePort: Int
    ) async -> String?
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

    private let registry: InspectorRegistry
    private let persistenceURL: URL
    private let processLauncher: ProcessLauncher
    private let localPortAllocator: LocalPortAllocator
    private let forwardReadiness: ForwardReadiness
    private let remoteProcessResolver: RemoteProcessResolver
    private let openURL: URLOpener
    private let copyAddress: AddressCopier
    private var desiredForwards: Set<DesiredForward>
    private var runtimeForwards: [String: RuntimeForward] = [:]
    private var processRefreshTasks: [String: Task<Void, Never>] = [:]
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var servers = ConnectionServers()
    private var isRegistered = false
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        registry: InspectorRegistry,
        persistenceURL: URL? = nil,
        processLauncher: @escaping ProcessLauncher = BuiltInInfoInspectorProvider.launchProcess,
        localPortAllocator: @escaping LocalPortAllocator = BuiltInInfoInspectorProvider.allocateLocalPort,
        forwardReadiness: @escaping ForwardReadiness = BuiltInInfoInspectorProvider.waitUntilForwardReady,
        remoteProcessResolver: @escaping RemoteProcessResolver = BuiltInInfoInspectorProvider.resolveRemoteProcess,
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        copyAddress: @escaping AddressCopier = BuiltInInfoInspectorProvider.copyToPasteboard
    ) {
        let resolvedPersistenceURL = persistenceURL ?? PluginInstallationManager.shared
            .dataURL(for: SSHPlugin.pluginID)
            .appendingPathComponent("port-forwards.json")
        self.registry = registry
        self.persistenceURL = resolvedPersistenceURL
        self.processLauncher = processLauncher
        self.localPortAllocator = localPortAllocator
        self.forwardReadiness = forwardReadiness
        self.remoteProcessResolver = remoteProcessResolver
        self.openURL = openURL
        self.copyAddress = copyAddress
        self.desiredForwards = Self.loadDesiredForwards(from: resolvedPersistenceURL)

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
                source: .plugin(Self.pluginID),
                preferredWidth: RightInspectorMetrics.defaultWidth,
                minimumWidth: 240
            )
            try registry.registerPluginPane(
                descriptor,
                lifecycle: { [weak self] event in self?.handle(event) },
                action: { [weak self] action in self?.handle(action) }
            )
            isRegistered = true
            synchronizeWithTerminalControllers()
        } else {
            shutdown()
            presentedContexts.removeAll()
            registry.unregister(source: .plugin(Self.pluginID))
            isRegistered = false
        }
    }

    private func refreshLocalization() {
        guard isRegistered else { return }
        do {
            try registry.updatePluginPaneTitle(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
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
        let running = runtimeForwards.values
        runtimeForwards.removeAll()
        for task in processRefreshTasks.values { task.cancel() }
        processRefreshTasks.removeAll()
        for forward in running { forward.stop() }
    }

    func synchronizeConnections(_ next: ConnectionServers) {
        servers = next

        let staleIDs = runtimeForwards.compactMap { id, runtime in
            next.connected.contains(runtime.desired.serverID) ? nil : id
        }
        for id in staleIDs { stopRuntimeForward(id: id) }

        for desired in desiredForwards where runtimeForwards[desired.id] == nil {
            guard let alias = next.readyAliases[desired.serverID] else { continue }
            startRuntimeForward(desired, alias: alias)
        }
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
            publish(context)
        case .disappeared(let context):
            presentedContexts.removeValue(forKey: context.tabID)
        }
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
                if desired.target.isLoopback {
                    startProcessRefresh(
                        id: desired.id,
                        token: token,
                        alias: alias,
                        remoteHost: desired.remoteHost,
                        remotePort: desired.remotePort
                    )
                }
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

    private func startProcessRefresh(
        id: String,
        token: UUID,
        alias: String,
        remoteHost: String,
        remotePort: Int
    ) {
        processRefreshTasks.removeValue(forKey: id)?.cancel()
        processRefreshTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let processName = await remoteProcessResolver(
                    alias,
                    remoteHost,
                    remotePort
                )
                guard !Task.isCancelled,
                      var runtime = runtimeForwards[id],
                      runtime.token == token,
                      runtime.status == .active else { return }
                if runtime.processName != processName {
                    runtime.processName = processName
                    runtimeForwards[id] = runtime
                    publishPresentedContexts()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopRuntimeForward(id: String) {
        processRefreshTasks.removeValue(forKey: id)?.cancel()
        guard let runtime = runtimeForwards.removeValue(forKey: id) else { return }
        runtime.stop()
    }

    private func processDidTerminate(
        id: String,
        token: UUID,
        status: Int32,
        errorOutput: String
    ) {
        guard var runtime = runtimeForwards[id], runtime.token == token else { return }
        processRefreshTasks.removeValue(forKey: id)?.cancel()
        if case .failed = runtime.status {
            return
        }
        runtime.status = .failed(Self.sshFailureDescription(
            status: status,
            errorOutput: errorOutput,
            localPort: runtime.localPort
        ))
        runtimeForwards[id] = runtime
        publishPresentedContexts()
    }

    private func publishPresentedContexts() {
        guard isRegistered else { return }
        for context in presentedContexts.values { publish(context) }
    }

    private func publish(_ context: InspectorPaneContext) {
        let strings = InfoStrings.current
        let content: InspectorPaneContent
        switch context.session.state {
        case .local:
            content = .empty(
                title: strings.infoTitle,
                message: strings.connectPrompt()
            )
        case .sshConnecting(let ssh):
            content = .empty(
                title: strings.infoTitle,
                message: strings.waitingForHost(ssh.alias)
            )
        case .sshReady(let ssh, _):
            if let serverID = ssh.serverID {
                content = .info(.init(
                    status: nil,
                    fields: [],
                    portForwards: self.content(
                        for: serverID,
                        alias: ssh.alias
                    )
                ))
            } else {
                content = .empty(
                    title: strings.infoTitle,
                    message: strings.identityUnavailable()
                )
            }
        }
        do {
            try registry.updatePluginContent(
                paneID: Self.paneID,
                pluginID: Self.pluginID,
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

    nonisolated private static func validPort(_ port: Int) -> Bool {
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
        guard case .sshReady(let ssh, _) = context.session.state,
              let serverID = ssh.serverID else { return nil }
        return (serverID, ssh.alias)
    }

    nonisolated private static func launchProcess(
        alias: String,
        remoteHost: String,
        remotePort: Int,
        localPort: Int,
        termination: @escaping (Int32, String) -> Void
    ) throws -> () -> Void {
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-\(UUID().uuidString).err")
        guard FileManager.default.createFile(
            atPath: errorURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let process = Process()
        let forwardHost = PortForwardTarget(
            host: remoteHost,
            port: remotePort
        ).sshHost
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.monitorScript,
            "omg-ssh-port-forward",
            String(ProcessInfo.processInfo.processIdentifier),
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):\(forwardHost):\(remotePort)",
            alias,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        process.terminationHandler = { process in
            try? errorHandle.close()
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            try? FileManager.default.removeItem(at: errorURL)
            let output = String(
                bytes: data.prefix(16_384),
                encoding: .utf8
            ) ?? ""
            termination(process.terminationStatus, output)
        }
        do {
            try process.run()
        } catch {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
            throw error
        }
        return {
            if process.isRunning { process.terminate() }
        }
    }

    nonisolated private static let monitorScript = """
    parent_pid="$1"
    shift
    /usr/bin/ssh "$@" &
    ssh_pid=$!
    cleanup() {
      /bin/kill "$ssh_pid" 2>/dev/null || true
      wait "$ssh_pid" 2>/dev/null || true
    }
    trap cleanup EXIT HUP INT TERM
    while /bin/kill -0 "$parent_pid" 2>/dev/null && /bin/kill -0 "$ssh_pid" 2>/dev/null; do
      /bin/sleep 1
    done
    if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
      /bin/kill "$ssh_pid" 2>/dev/null || true
    fi
    wait "$ssh_pid"
    status=$?
    trap - EXIT HUP INT TERM
    exit "$status"
    """

    nonisolated private static func waitUntilForwardReady(
        localPort: Int
    ) async -> Bool {
        for _ in 0..<100 {
            if !canBind(port: localPort) { return true }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return false
    }

    private static func failureDescription(_ error: Error) -> String {
        if let posix = error as? POSIXError {
            return InfoStrings.current.allocatePortFailed(posix.localizedDescription)
        }
        return error.localizedDescription
    }

    private static func sshFailureDescription(
        status: Int32,
        errorOutput: String,
        localPort: Int
    ) -> String {
        let strings = InfoStrings.current
        let lower = errorOutput.lowercased()
        if lower.contains("address already in use") || lower.contains("cannot listen to port") {
            return strings.localPortInUse(localPort)
        }
        if lower.contains("permission denied") {
            return strings.authenticationFailed
        }
        if lower.contains("host key verification failed") {
            return strings.hostKeyFailed
        }
        if lower.contains("could not resolve hostname") {
            return strings.resolveHostFailed
        }
        if lower.contains("connection refused") {
            return strings.connectionRefused
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return strings.connectionTimedOut
        }
        let message = errorOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
            .map { String($0.prefix(240)) }
        return message ?? strings.sshExited(status: status)
    }

    nonisolated private static func resolveRemoteProcess(
        alias: String,
        remoteHost _: String,
        remotePort: Int
    ) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let command = Self.remoteProcessCommand(port: remotePort)
            let remoteCommand = "exec /bin/sh -c \(Self.shellQuote(command))"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ConnectionAttempts=1",
                alias,
                remoteCommand,
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timeout = Task.detached {
                try? await Task.sleep(for: .seconds(6))
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let decoded = String(
                bytes: data.prefix(512),
                encoding: .utf8
            ) else { return nil }
            let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 128,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return nil
            }
            return value
        }.value
    }

    nonisolated private static func remoteProcessCommand(port: Int) -> String {
        """
        port=\(port)
        pid=''
        fallback=''
        if command -v lsof >/dev/null 2>&1; then
          pid=$(lsof -nP -iTCP:$port -sTCP:LISTEN -F p 2>/dev/null | sed -n 's/^p//p' | head -n 1)
          fallback=$(lsof -nP -iTCP:$port -sTCP:LISTEN -F c 2>/dev/null | sed -n 's/^c//p' | head -n 1)
        elif command -v ss >/dev/null 2>&1; then
          socket=$(ss -H -ltnp "sport = :$port" 2>/dev/null | head -n 1)
          pid=$(printf '%s' "$socket" | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p')
          fallback=$(printf '%s' "$socket" | sed -n 's/.*users:(("\\([^"]*\\)".*/\\1/p')
        elif command -v fuser >/dev/null 2>&1; then
          pid=$(fuser "$port/tcp" 2>/dev/null | awk '{print $1}')
        fi
        if [ -n "$pid" ] && command -v ps >/dev/null 2>&1; then
          args=$(ps -p "$pid" -o args= 2>/dev/null | head -n 1)
          executable=${args%% *}
          if [ -n "$executable" ]; then
            printf '%s\\n' "${executable##*/}"
            exit 0
          fi
        fi
        [ -n "$fallback" ] && printf '%s\\n' "$fallback"
        """
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func copyToPasteboard(_ value: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    nonisolated private static func allocateLocalPort(preferredPort: Int) throws -> Int {
        if validPort(preferredPort), canBind(port: preferredPort) {
            return preferredPort
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    nonisolated private static func canBind(port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var reuseAddress: Int32 = 1
        _ = withUnsafePointer(to: &reuseAddress) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
