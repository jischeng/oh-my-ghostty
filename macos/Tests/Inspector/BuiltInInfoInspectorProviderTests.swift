import Foundation
import Testing
@testable import Ghostty

@MainActor
struct BuiltInInfoInspectorProviderTests {
    @Test func forwardsOncePerAliasAndRestoresPersistedIntent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-test-\(UUID().uuidString)")
        let persistenceURL = root.appendingPathComponent("port-forwards.json")
        defer { try? FileManager.default.removeItem(at: root) }

        struct Launch: Equatable {
            let alias: String
            let host: String
            let remote: Int
            let local: Int
        }
        var launches: [Launch] = []
        var stopped: [Int] = []
        var openedURLs: [URL] = []
        var copiedAddresses: [String] = []
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: persistenceURL,
            processLauncher: { alias, host, remote, local, _ in
                launches.append(.init(
                    alias: alias,
                    host: host,
                    remote: remote,
                    local: local
                ))
                return { stopped.append(local) }
            },
            localPortAllocator: { _ in 41_000 },
            forwardReadiness: { _ in true },
            remoteProcessResolver: { _, _, _ in "node" },
            openURL: { openedURLs.append($0) },
            copyAddress: { copiedAddresses.append($0) }
        )
        try provider.setEnabled(true)

        let serverID = "hostkey-SHA256:testserver="
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-1"
        )
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        registry.presentationDidChange(
            to: BuiltInInfoInspectorProvider.paneID,
            context: context
        )
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createPortForward(target: "8080")
            )
        )

        #expect(launches.count == 1)
        #expect(launches.first?.alias == "cloud")
        #expect(launches.first?.host == PortForwardTarget.loopbackHost)
        #expect(launches.first?.remote == 8_080)
        #expect(launches.first?.local == 41_000)
        #expect(FileManager.default.fileExists(atPath: persistenceURL.path))

        try await Task.sleep(for: .milliseconds(350))
        let list = provider.content(for: serverID, alias: "cloud")
        #expect(list.items == [
            .init(
                id: "\(serverID)|127.0.0.1|8080",
                remoteHost: PortForwardTarget.loopbackHost,
                remotePort: 8_080,
                localPort: 41_000,
                processName: "node",
                status: .active
            ),
        ])
        guard case .info(let info) = registry.content(
            for: BuiltInInfoInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected typed Info content")
            return
        }
        #expect(info.status == nil)
        #expect(info.fields.isEmpty)
        #expect(info.portForwards == list)

        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .openPortForward(id: "\(serverID)|127.0.0.1|8080")
            )
        )
        #expect(openedURLs.map(\.absoluteString) == ["http://127.0.0.1:41000"])
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .copyPortForward(id: "\(serverID)|127.0.0.1|8080")
            )
        )
        #expect(copiedAddresses == ["localhost:41000"])

        // A second alias or direct-IP connection with the same authenticated
        // server identity shares the forward and keeps it alive.
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "10.0.0.12"]
        ))
        #expect(stopped.isEmpty)
        provider.synchronizeConnections(.init())
        #expect(stopped == [41_000])

        provider.shutdown()
        try provider.setEnabled(false)

        struct RestoredLaunch: Equatable {
            let alias: String
            let host: String
            let remote: Int
            let local: Int
        }
        var restoredLaunches: [RestoredLaunch] = []
        let restoredRegistry = InspectorRegistry()
        let restored = BuiltInInfoInspectorProvider(
            registry: restoredRegistry,
            persistenceURL: persistenceURL,
            processLauncher: { alias, host, remote, local, _ in
                restoredLaunches.append(.init(
                    alias: alias,
                    host: host,
                    remote: remote,
                    local: local
                ))
                return {}
            },
            localPortAllocator: { _ in 42_000 },
            forwardReadiness: { _ in true },
            remoteProcessResolver: { _, _, _ in nil },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try restored.setEnabled(true)
        restored.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "10.0.0.12"]
        ))
        #expect(restoredLaunches.count == 1)
        #expect(restoredLaunches.first?.alias == "10.0.0.12")
        #expect(restoredLaunches.first?.host == PortForwardTarget.loopbackHost)
        #expect(restoredLaunches.first?.remote == 8_080)
        #expect(restoredLaunches.first?.local == 42_000)
        restored.shutdown()
    }

    @Test func supportsExplicitTargetsAndMigratesLoopbackPersistence() async throws {
        #expect(PortForwardTarget.parse("5175") == .init(
            host: PortForwardTarget.loopbackHost,
            port: 5_175
        ))
        #expect(PortForwardTarget.parse("10.0.0.8:5175") == .init(
            host: "10.0.0.8",
            port: 5_175
        ))
        #expect(PortForwardTarget.parse("[::1]:5175") == .init(
            host: "::1",
            port: 5_175
        ))
        #expect(PortForwardTarget.parse("bad target:5175") == nil)

        let legacy = Data("""
        [{"serverID":"machine-legacy","remotePort":5175}]
        """.utf8)
        let migrated = try JSONDecoder().decode(
            [BuiltInInfoInspectorProvider.DesiredForward].self,
            from: legacy
        )
        #expect(migrated.first?.remoteHost == PortForwardTarget.loopbackHost)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var launchedHost: String?
        var processProbeCount = 0
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, host, _, _, _ in
                launchedHost = host
                return {}
            },
            localPortAllocator: { $0 },
            forwardReadiness: { _ in true },
            remoteProcessResolver: { _, _, _ in
                processProbeCount += 1
                return nil
            },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try provider.setEnabled(true)
        let serverID = "machine-target"
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-target"
        )
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createPortForward(target: "10.0.0.8:5175")
            )
        )
        await Task.yield()
        #expect(launchedHost == "10.0.0.8")
        #expect(processProbeCount == 0)
        #expect(provider.content(
            for: serverID,
            alias: "cloud"
        ).items.first?.remoteHost == "10.0.0.8")
        provider.shutdown()
    }

    @Test func duplicateAndInvalidPortsDoNotLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var launchCount = 0
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, _ in
                launchCount += 1
                return {}
            },
            localPortAllocator: { $0 },
            forwardReadiness: { _ in true },
            remoteProcessResolver: { _, _, _ in nil },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try provider.setEnabled(true)
        let serverID = "machine-0123456789abcdef"
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-2"
        )

        for port in [0, 65_536, 3_000, 3_000] {
            registry.performAction(
                paneID: BuiltInInfoInspectorProvider.paneID,
                action: .init(
                    context: context,
                    kind: .createPortForward(target: String(port))
                )
            )
        }
        #expect(launchCount == 1)
        #expect(provider.content(
            for: serverID,
            alias: "cloud"
        ).items.map(\.remotePort) == [3_000])
        provider.shutdown()
    }

    @Test func exposesDetailedSSHFailureReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var termination: ((Int32, String) -> Void)?
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, callback in
                termination = callback
                return {}
            },
            localPortAllocator: { $0 },
            forwardReadiness: { _ in
                try? await Task.sleep(for: .seconds(1))
                return false
            },
            remoteProcessResolver: { _, _, _ in nil },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try provider.setEnabled(true)
        #expect(registry.descriptor(id: BuiltInInfoInspectorProvider.paneID)?.title == "Info")

        let serverID = "hostkey-SHA256:failure="
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-failure"
        )
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createPortForward(target: "5175")
            )
        )
        termination?(255, "bind [127.0.0.1]:5175: Address already in use")
        await Task.yield()

        guard case .failed(let message) = provider.content(
            for: serverID,
            alias: "cloud"
        ).items.first?.status else {
            Issue.record("Expected a detailed forwarding failure")
            return
        }
        #expect(message == "Local port 5175 is already in use.")
        provider.shutdown()
    }

    @Test func localizesInfoStrings() {
        let english = InfoStrings(language: .english)
        let chinese = InfoStrings(language: .simplifiedChinese)
        #expect(english.infoTitle == "Info")
        #expect(chinese.infoTitle == "信息")
        #expect(english.targetPlaceholder == "Port or host:port")
        #expect(chinese.targetPlaceholder == "端口或 host:port")
        #expect(chinese.localPortInUse(5_175) == "本地端口 5175 已被占用。")
    }

    private func sshContext(
        alias: String,
        serverID: String,
        connectionID: String
    ) -> InspectorPaneContext {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: connectionID,
                metadata: "type=remote;targethost=\(alias);serverid=\(serverID);cwd=/home/test"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "remote"
        )
        return .init(
            tabID: UUID(),
            surfaceID: UUID(),
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            workspace: session.workspace,
            session: session
        )
    }
}
