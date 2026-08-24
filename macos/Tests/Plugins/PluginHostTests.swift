import Foundation
import Testing
@testable import Ghostty

@MainActor
struct PluginHostTests {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func officialSSHInstallationEnablesTheWorkspaceProvider() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-official-plugin-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: support)
            UserDefaults.standard.removeObject(forKey: "OMG.Plugin.Enabled.\(SSHPlugin.pluginID)")
        }
        let manager = PluginInstallationManager(applicationSupport: support)
        try manager.installOfficial(SSHPlugin.pluginID)
        #expect(manager.isInstalled(SSHPlugin.pluginID))
        #expect(manager.isEnabled(SSHPlugin.pluginID))
        try manager.disable(SSHPlugin.pluginID)
        #expect(!manager.isEnabled(SSHPlugin.pluginID))
    }

    @Test func pluginInstallationKeepsCodeAndDataSeparate() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-plugin-manager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let manager = PluginInstallationManager(applicationSupport: support)
        let package = manager.pluginsDirectory.appendingPathComponent("dev.example.hello", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            id: "dev.example.hello",
            version: "0.1.0",
            executable: "bin/hello",
            capabilities: [.sessionStatus]
        )
        try JSONEncoder().encode(manifest).write(
            to: package.appendingPathComponent("manifest.json")
        )
        manager.reload()
        #expect(manager.installed == [manifest])
        try manager.disable(manifest.id)
        #expect(manager.disabledIDs.contains(manifest.id))
        #expect(manager.dataURL(for: manifest.id).path.contains("PluginData"))
        try manager.uninstall(manifest.id)
        #expect(manager.installed.isEmpty)
    }

    @Test func authorizationIntersectsRequestedAndManifestCapabilities() throws {
        let manifest = PluginManifest(
            id: "dev.ghostty.agent-status",
            version: "0.1.0",
            executable: "agent-status",
            capabilities: [.terminalEvents, .sessionStatus]
        )
        let policy = PluginAuthorizationPolicy(manifests: [manifest.id: manifest])
        let hello = PluginHello(
            pluginID: manifest.id,
            pluginVersion: manifest.version,
            supportedProtocolVersions: [1],
            requestedCapabilities: [.sessionStatus, .terminalControl],
            nonce: "nonce"
        )

        let welcome = try policy.authorize(
            hello,
            expectedPluginID: manifest.id,
            expectedNonce: "nonce",
            hostVersion: "test"
        ).get()

        #expect(welcome.grantedCapabilities == [.sessionStatus])
    }

    @Test func authorizationRejectsIdentityAndVersionMismatch() {
        let manifest = PluginManifest(
            id: "dev.ghostty.agent-status",
            version: "0.1.0",
            executable: "agent-status",
            capabilities: [.terminalEvents]
        )
        let policy = PluginAuthorizationPolicy(manifests: [manifest.id: manifest])

        let wrongNonce = policy.authorize(
            .init(
                pluginID: manifest.id,
                pluginVersion: manifest.version,
                supportedProtocolVersions: [1],
                requestedCapabilities: [],
                nonce: "wrong"
            ),
            expectedPluginID: manifest.id,
            expectedNonce: "expected",
            hostVersion: "test"
        )
        #expect(failureCode(wrongNonce) == .permissionDenied)

        let wrongVersion = policy.authorize(
            .init(
                pluginID: manifest.id,
                pluginVersion: manifest.version,
                supportedProtocolVersions: [99],
                requestedCapabilities: [],
                nonce: "expected"
            ),
            expectedPluginID: manifest.id,
            expectedNonce: "expected",
            hostVersion: "test"
        )
        #expect(failureCode(wrongVersion) == .incompatibleVersion)
    }

    @Test func statusStoreRejectsStaleAndForeignUpdates() throws {
        let store = TabActivityStore()
        let initial = PluginSetSessionStatus(
            sessionID: sessionID,
            revision: 1,
            status: .init(agent: "Codex", title: nil, state: .running),
            ttlMilliseconds: nil
        )

        #expect(store.set(initial, pluginID: "status", sessionExists: { _ in true }) == nil)
        #expect(store.status(for: sessionID)?.state == .running)
        #expect(store.set(initial, pluginID: "status", sessionExists: { _ in true })?.code == .staleRevision)

        let foreign = PluginSetSessionStatus(
            sessionID: sessionID,
            revision: 2,
            status: .init(agent: "Other", title: nil, state: .failed),
            ttlMilliseconds: nil
        )
        #expect(
            store.set(foreign, pluginID: "other", sessionExists: { _ in true })?.code == .permissionDenied
        )
        #expect(store.status(for: sessionID)?.agent == "Codex")
    }

    @Test func statusStoreRejectsInvalidDeclarativePresentationData() {
        let store = TabActivityStore()
        let invalidIcon = PluginSetSessionStatus(
            sessionID: sessionID,
            revision: 1,
            status: .init(
                agent: "Codex",
                title: nil,
                state: .running,
                progress: 2,
                icon: .init(kind: .systemSymbol, name: "../arbitrary-file")
            ),
            ttlMilliseconds: nil
        )

        #expect(store.set(
            invalidIcon,
            pluginID: "status",
            sessionExists: { _ in true }
        )?.code == .invalidMessage)
        let unsafeIcon = PluginSetSessionStatus(
            sessionID: sessionID,
            revision: 1,
            status: .init(
                agent: "Codex",
                title: nil,
                state: .running,
                icon: .init(kind: .systemSymbol, name: "../arbitrary-file")
            ),
            ttlMilliseconds: nil
        )
        #expect(store.set(
            unsafeIcon,
            pluginID: "status",
            sessionExists: { _ in true }
        )?.code == .invalidMessage)
        #expect(store.activity(for: sessionID) == nil)
    }

    @Test func statusStoreExpiresAndDisconnectsOwnedEntries() {
        let store = TabActivityStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let expiring = PluginSetSessionStatus(
            sessionID: sessionID,
            revision: 1,
            status: .init(agent: "Codex", title: nil, state: .completed),
            ttlMilliseconds: 1_000
        )

        #expect(store.set(expiring, pluginID: "status", sessionExists: { _ in true }, now: now) == nil)
        store.removeExpired(at: now.addingTimeInterval(0.5))
        #expect(store.status(for: sessionID) != nil)
        store.removeExpired(at: now.addingTimeInterval(1))
        #expect(store.status(for: sessionID) == nil)

        let persistent = PluginSetSessionStatus(
            sessionID: sessionID,
            revision: 2,
            status: .init(agent: "Codex", title: nil, state: .waiting),
            ttlMilliseconds: nil
        )
        #expect(store.set(persistent, pluginID: "status", sessionExists: { _ in true }) == nil)
        store.disconnect(pluginID: "status")
        #expect(store.status(for: sessionID) == nil)
    }

    @Test func routerEnforcesCapabilityAndAcknowledgesAcceptedCommands() {
        let deniedStore = TabActivityStore()
        let deniedRouter = PluginMessageRouter(
            pluginID: "status",
            grantedCapabilities: [],
            statusStore: deniedStore,
            sessionExists: { _ in true }
        )
        let request = statusRequest(revision: 1)
        let denied = deniedRouter.handle(request)
        #expect(failure(from: denied)?.code == .permissionDenied)

        let allowedStore = TabActivityStore()
        let allowedRouter = PluginMessageRouter(
            pluginID: "status",
            grantedCapabilities: [.sessionStatus],
            statusStore: allowedStore,
            sessionExists: { _ in true }
        )
        let accepted = allowedRouter.handle(request)
        guard case .acknowledgement(let acknowledgement) = accepted.body else {
            Issue.record("Expected acknowledgement")
            return
        }
        #expect(acknowledgement.acceptedSequence == request.sequence)
        #expect(accepted.correlationID == request.sequence)
        #expect(allowedStore.status(for: sessionID)?.state == .running)
    }

    @Test func statusIconRequiresItsOwnCapability() {
        let store = TabActivityStore()
        let request = PluginWireMessage(
            sequence: 20,
            body: .setSessionStatus(.init(
                sessionID: sessionID,
                revision: 1,
                status: .init(
                    agent: "Codex",
                    title: nil,
                    state: .running,
                    icon: .init(kind: .systemSymbol, name: "bolt.fill")
                ),
                ttlMilliseconds: nil
            ))
        )
        let denied = PluginMessageRouter(
            pluginID: "status",
            grantedCapabilities: [.sessionStatus],
            statusStore: store,
            sessionExists: { _ in true }
        ).handle(request)
        #expect(failure(from: denied)?.code == .permissionDenied)

        let accepted = PluginMessageRouter(
            pluginID: "status",
            grantedCapabilities: [.sessionStatus, .tabIcon],
            statusStore: store,
            sessionExists: { _ in true }
        ).handle(request)
        guard case .acknowledgement = accepted.body else {
            Issue.record("Expected icon-capable acknowledgement")
            return
        }
        #expect(store.activity(for: sessionID)?.icon?.name == "bolt.fill")
    }

    private func statusRequest(revision: UInt64) -> PluginWireMessage {
        .init(
            sequence: 10,
            body: .setSessionStatus(.init(
                sessionID: sessionID,
                revision: revision,
                status: .init(agent: "Codex", title: nil, state: .running),
                ttlMilliseconds: nil
            ))
        )
    }

    private func failure(
        from message: PluginWireMessage
    ) -> PluginProtocolFailure? {
        guard case .failure(let failure) = message.body else { return nil }
        return failure
    }

    private func failureCode(
        _ result: Result<PluginWelcome, PluginProtocolFailure>
    ) -> PluginProtocolFailure.Code? {
        guard case .failure(let failure) = result else { return nil }
        return failure.code
    }
}
