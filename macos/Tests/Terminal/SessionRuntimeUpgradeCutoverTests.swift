import AppKit
import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SessionRuntimeUpgradeCutoverTests {
    private struct EndpointArchiveFixture: Codable {
        var version: Int
        var endpoints: [SessionRuntimeCatalogEndpoint]
    }

    private struct EpochFixture: Codable {
        var epoch: Int
    }

    private struct PaneFixture: Encodable {
        var pwd: String?
        var uuid: String
        var title: String?
        var isUserSetTitle: Bool?
        var agentResumeDescriptor: AgentResumeDescriptor?
        var sshResumeDescriptor: SSHResumeDescriptor?
        var acknowledgedAgentStatus: AcknowledgedAgentStatus?
        var runtimeDescriptor: SessionRuntimeDescriptor?
        var runtimeCreateOnRestore: Bool?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: TerminalWorkspaceSessionState.Pane.CodingKeys.self)
            try container.encode(pwd, forKey: .pwd)
            try container.encode(uuid, forKey: .uuid)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(isUserSetTitle, forKey: .isUserSetTitle)
            try container.encodeIfPresent(agentResumeDescriptor, forKey: .agentResumeDescriptor)
            try container.encodeIfPresent(sshResumeDescriptor, forKey: .sshResumeDescriptor)
            try container.encodeIfPresent(acknowledgedAgentStatus, forKey: .acknowledgedAgentStatus)
            try container.encodeIfPresent(runtimeDescriptor, forKey: .runtimeDescriptor)
            try container.encodeIfPresent(runtimeCreateOnRestore, forKey: .runtimeCreateOnRestore)
        }
    }

    private indirect enum NodeFixture: Encodable {
        case leaf(PaneFixture)
        case split(direction: TerminalWorkspaceSessionState.Node.Direction, ratio: Double, left: NodeFixture, right: NodeFixture)

        private struct BranchFixture: Encodable {
            var direction: TerminalWorkspaceSessionState.Node.Direction
            var ratio: Double
            var left: NodeFixture
            var right: NodeFixture
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: TerminalWorkspaceSessionState.Node.CodingKeys.self)
            switch self {
            case .leaf(let pane):
                try container.encode(pane, forKey: .view)
            case .split(let direction, let ratio, let left, let right):
                try container.encode(
                    BranchFixture(direction: direction, ratio: ratio, left: left, right: right),
                    forKey: .split
                )
            }
        }
    }

    private struct TreeFixture: Encodable {
        var version = 1
        var root: NodeFixture?
        var zoomed: TerminalWorkspaceSessionState.Tree.Path?
    }

    private struct SessionStateFixture: Encodable {
        var focusedSurface: String?
        var surfaceTree: TreeFixture
        var effectiveFullscreenMode: FullscreenMode?
        var tabColor: TerminalTabColor?
        var titleOverride: String?
        var tabSessionID: String?
        var tabCreatedAt: Date?
    }

    @MainActor
    @Test func cutoverIsChannelIsolatedAndPreservesSiblingChannelData() throws {
        let root = URL(fileURLWithPath: "/tmp/omg-cut-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let supportDev = root.appendingPathComponent("Support/OMG Dev", isDirectory: true)
        let supportRelease = root.appendingPathComponent("Support/OMG", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDev, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportRelease, withIntermediateDirectories: true)

        let suiteName = "CutoverSSHRegistryTest." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] })
        let sshConn = try GitSSHConnection(destination: "prodbox", options: ["-p", "2222"])
        _ = registry.addConfigured(sshConn)
        let hostEncoder = JSONEncoder()
        hostEncoder.outputFormatting = [.sortedKeys]
        let hostsBeforeData = try hostEncoder.encode(registry.hosts)

        let devVersionsOld = supportDev.appendingPathComponent("session-runtime/versions/rev-from-versions", isDirectory: true)
        try FileManager.default.createDirectory(at: devVersionsOld, withIntermediateDirectories: true)
        try Data("rev-from-versions\n".utf8).write(to: devVersionsOld.appendingPathComponent("revision"))

        let devPendingCloses = supportDev.appendingPathComponent("session-runtime/pending-closes.json")
        try Data("[]".utf8).write(to: devPendingCloses)

        let devEndpointsURL = supportDev.appendingPathComponent("session-runtime/endpoints.json")
        let devArchive = EndpointArchiveFixture(
            version: 1,
            endpoints: [
                SessionRuntimeCatalogEndpoint(
                    descriptor: SessionRuntimeDescriptor(connection: nil, revision: "rev-local-older", policy: .init()),
                    lastUsedAt: Date(timeIntervalSince1970: 100)
                ),
                SessionRuntimeCatalogEndpoint(
                    descriptor: SessionRuntimeDescriptor(connection: nil, revision: "rev-from-endpoints", policy: .init()),
                    lastUsedAt: Date(timeIntervalSince1970: 200)
                ),
                SessionRuntimeCatalogEndpoint(
                    descriptor: SessionRuntimeDescriptor(connection: sshConn, revision: "rev-ssh-old", policy: .init()),
                    lastUsedAt: Date(timeIntervalSince1970: 150)
                ),
            ]
        )
        try OMGPrivateFileWriter.writeAtomically(JSONEncoder().encode(devArchive), to: devEndpointsURL)

        let devWorkspacePane = PaneFixture(
            pwd: "/tmp/dev-project",
            uuid: UUID().uuidString,
            title: "Dev",
            isUserSetTitle: false,
            runtimeDescriptor: SessionRuntimeDescriptor(
                connection: nil,
                revision: "rev-from-workspace",
                policy: .init(),
                localWorkingDirectory: "/tmp/dev-project"
            ),
            runtimeCreateOnRestore: nil
        )
        let devTabID = UUID()
        let devWorkspaceID = TerminalWorkspace.defaultID
        let devWindowID = UUID()
        let devGroupID = UUID()
        let devStateData = try JSONEncoder().encode(
            SessionStateFixture(
                focusedSurface: devWorkspacePane.uuid,
                surfaceTree: .init(root: .leaf(devWorkspacePane)),
                tabColor: .blue,
                tabSessionID: devTabID.uuidString,
                tabCreatedAt: Date(timeIntervalSince1970: 50)
            )
        )
        var devCatalog = TerminalWorkspaceState()
        devCatalog.register(devTabID, owner: .init(window: devWindowID, workspace: devWorkspaceID, group: devGroupID))
        let devSnapshot = TerminalWorkspaceSessionStore.Snapshot(
            version: 2,
            tabs: [TerminalWorkspaceSessionStore.Tab(
                id: devTabID,
                workspace: devWorkspaceID,
                state: devStateData,
                group: devGroupID,
                selected: true,
                frame: nil,
                fullscreen: false,
                window: devWindowID
            )],
            generation: 1,
            catalog: devCatalog,
            explicitlyEmpty: false,
            foregroundTab: devTabID
        )
        let devStateURL = supportDev.appendingPathComponent("workspaces/state.json")
        try OMGPrivateFileWriter.writeAtomically(JSONEncoder().encode(devSnapshot), to: devStateURL)

        let runRoot = home.appendingPathComponent(".omg/run", isDirectory: true)
        let devStampedDir = runRoot.appendingPathComponent("stamped-dev-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: devStampedDir, withIntermediateDirectories: true)
        let canonicalDevPath = supportDev.resolvingSymlinksInPath().path
        try Data((canonicalDevPath + "\n").utf8).write(to: devStampedDir.appendingPathComponent("support-root"))

        let devLegacyDirs = [
            "rev-from-versions",
            "rev-from-endpoints",
            "rev-from-workspace",
            "rev-bundled",
        ].map {
            SessionRuntimeConnections.legacyLocalStateDirectory(
                supportRoot: supportDev,
                revision: $0,
                homeDirectory: home
            )
        }
        for dir in devLegacyDirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("marker".utf8).write(to: dir.appendingPathComponent("host.lock"))
        }

        let releaseStampedDir = runRoot.appendingPathComponent("stamped-release-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseStampedDir, withIntermediateDirectories: true)
        try Data((supportRelease.resolvingSymlinksInPath().path + "\n").utf8)
            .write(to: releaseStampedDir.appendingPathComponent("support-root"))
        let releaseUnstampedDir = SessionRuntimeConnections.legacyLocalStateDirectory(
            supportRoot: supportRelease,
            revision: "rev-from-versions",
            homeDirectory: home
        )
        try FileManager.default.createDirectory(at: releaseUnstampedDir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: releaseUnstampedDir.appendingPathComponent("keep.txt"))

        let releaseSentinel = supportRelease.appendingPathComponent("session-runtime/versions/rev-from-versions/revision")
        try FileManager.default.createDirectory(at: releaseSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep-release\n".utf8).write(to: releaseSentinel)

        let ran = try SessionRuntimeUpgradeCutover.performIfNeeded(
            applicationSupportRoot: supportDev,
            homeDirectory: home,
            bundledRevision: "rev-bundled",
            terminateProcesses: false
        )
        #expect(ran)

        #expect(!FileManager.default.fileExists(atPath: devStampedDir.path))
        for dir in devLegacyDirs {
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
        #expect(FileManager.default.fileExists(atPath: releaseStampedDir.path))
        #expect(FileManager.default.fileExists(atPath: releaseUnstampedDir.appendingPathComponent("keep.txt").path))
        #expect(FileManager.default.fileExists(atPath: releaseSentinel.path))

        #expect(!FileManager.default.fileExists(atPath: supportDev.appendingPathComponent("session-runtime/versions").path))
        #expect(!FileManager.default.fileExists(atPath: devPendingCloses.path))

        let sanitizedEndpoints = try JSONDecoder().decode(
            EndpointArchiveFixture.self,
            from: Data(contentsOf: devEndpointsURL)
        )
        let localEndpoints = sanitizedEndpoints.endpoints.filter { $0.descriptor.isLocal }
        let sshEndpoints = sanitizedEndpoints.endpoints.filter { !$0.descriptor.isLocal }
        #expect(localEndpoints.count == 1)
        #expect(localEndpoints.first?.descriptor.revision == "rev-bundled")
        #expect(localEndpoints.first?.lastUsedAt == Date(timeIntervalSince1970: 200))
        #expect(sshEndpoints.count == 1)
        #expect(sshEndpoints.first?.descriptor.revision == "rev-bundled")
        #expect(try hostEncoder.encode(registry.hosts) == hostsBeforeData)

        let epochURL = supportDev.appendingPathComponent("session-runtime/runtime-epoch.json")
        let epoch = try JSONDecoder().decode(EpochFixture.self, from: Data(contentsOf: epochURL))
        #expect(epoch.epoch == SessionRuntimeUpgradeCutover.currentEpoch)
        let permissions = try FileManager.default.attributesOfItem(atPath: epochURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @MainActor
    @Test func workspaceSanitizationPreservesGraphMetadataAndResetsPaneSessions() throws {
        let root = URL(fileURLWithPath: "/tmp/omg-cut-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("Support/OMG", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let windowID = UUID()
        let wsDefault = TerminalWorkspace.defaultID
        let wsSecond = UUID()
        let groupDefault = UUID()
        let groupSecond = UUID()
        let tabOne = UUID()
        let tabTwo = UUID()
        let tabParked = UUID()

        let paneLocalLeftOld = UUID().uuidString
        let paneLocalRightOld = UUID().uuidString
        let paneSSHOld = UUID().uuidString
        let paneParkedOld = UUID().uuidString

        let agentResume = AgentResumeDescriptor(
            agent: .codex,
            conversationID: AgentConversationID("conv-123"),
            scope: .local,
            workingDirectory: "/tmp/local-active",
            restoredTitle: "Codex Session"
        )
        let sshReplay = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: true,
            terminfo: true,
            cache: true,
            args: ["devbox"],
            localWorkingDirectory: "/tmp/local-origin"
        )
        let sshResume = SSHResumeDescriptor(
            sshReplay: sshReplay,
            remoteWorkingDirectory: "/srv/remote-dir",
            localWorkingDirectory: "/tmp/local-origin",
            awaitingReconnect: false,
            interruptedAgent: nil
        )

        let splitLeft = PaneFixture(
            pwd: "/tmp/local-active",
            uuid: paneLocalLeftOld,
            title: "Custom Left",
            isUserSetTitle: true,
            agentResumeDescriptor: agentResume,
            runtimeDescriptor: SessionRuntimeDescriptor(
                connection: nil,
                revision: "old-rev-a",
                policy: .init(),
                localWorkingDirectory: "/tmp/local-initial",
                initialWorkingDirectory: "/tmp/local-initial"
            )
        )
        let splitRight = PaneFixture(
            pwd: nil,
            uuid: paneLocalRightOld,
            title: "Right Fallback",
            isUserSetTitle: false,
            runtimeDescriptor: SessionRuntimeDescriptor(
                connection: nil,
                revision: "old-rev-b",
                policy: .init(),
                localWorkingDirectory: "/tmp/right-local",
                initialWorkingDirectory: nil
            )
        )
        let sshPane = PaneFixture(
            pwd: "/srv/remote-work",
            uuid: paneSSHOld,
            title: "Remote Box",
            isUserSetTitle: true,
            sshResumeDescriptor: sshResume,
            runtimeDescriptor: SessionRuntimeDescriptor(
                connection: try GitSSHConnection(destination: "devbox"),
                revision: "old-rev-ssh",
                policy: .init(),
                localWorkingDirectory: "/tmp/local-origin",
                initialWorkingDirectory: "/srv/remote-work"
            )
        )
        let parkedPane = PaneFixture(
            pwd: "/tmp/parked-dir",
            uuid: paneParkedOld,
            title: "Parked Tab",
            isUserSetTitle: false,
            runtimeDescriptor: SessionRuntimeDescriptor(
                connection: nil,
                revision: "old-rev-parked",
                policy: .init(),
                localWorkingDirectory: "/tmp/parked-dir"
            )
        )

        let stateOne = SessionStateFixture(
            focusedSurface: paneLocalRightOld,
            surfaceTree: .init(
                root: .split(
                    direction: .horizontal,
                    ratio: 0.35,
                    left: .leaf(splitLeft),
                    right: .leaf(splitRight)
                )
            ),
            tabColor: .purple,
            titleOverride: "Workspace Split Tab",
            tabSessionID: tabOne.uuidString,
            tabCreatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let stateTwo = SessionStateFixture(
            focusedSurface: paneSSHOld,
            surfaceTree: .init(root: .leaf(sshPane)),
            tabColor: .teal,
            tabSessionID: tabTwo.uuidString,
            tabCreatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let stateParked = SessionStateFixture(
            focusedSurface: paneParkedOld,
            surfaceTree: .init(root: .leaf(parkedPane)),
            tabColor: .orange,
            tabSessionID: tabParked.uuidString,
            tabCreatedAt: Date(timeIntervalSince1970: 3_000)
        )

        var catalog = TerminalWorkspaceState()
        catalog.workspaces = [
            TerminalWorkspace(id: wsDefault, name: "Default", symbol: "terminal", color: "accent"),
            TerminalWorkspace(id: wsSecond, name: "Backend", symbol: "server.rack", color: "blue"),
        ]
        catalog.register(tabOne, owner: .init(window: windowID, workspace: wsDefault, group: groupDefault))
        catalog.register(tabTwo, owner: .init(window: windowID, workspace: wsDefault, group: groupDefault))
        catalog.register(tabParked, owner: .init(window: windowID, workspace: wsSecond, group: groupSecond))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = TerminalWorkspaceSessionStore.Snapshot(
            version: 2,
            tabs: [
                .init(id: tabOne, workspace: wsDefault, state: try encoder.encode(stateOne),
                      group: groupDefault, selected: false, frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                      fullscreen: false, window: windowID),
                .init(id: tabTwo, workspace: wsDefault, state: try encoder.encode(stateTwo),
                      group: groupDefault, selected: true, frame: nil, fullscreen: false, window: windowID),
                .init(id: tabParked, workspace: wsSecond, state: try encoder.encode(stateParked),
                      group: groupSecond, selected: true, frame: nil, fullscreen: false, window: windowID),
            ],
            generation: 7,
            catalog: catalog,
            explicitlyEmpty: false,
            foregroundTab: tabTwo
        )
        let snapshotData = try encoder.encode(snapshot)

        let workspacesDir = support.appendingPathComponent("workspaces", isDirectory: true)
        let stateURL = workspacesDir.appendingPathComponent("state.json")
        let previousURL = workspacesDir.appendingPathComponent("state.json.previous")
        let sessionsURL = workspacesDir.appendingPathComponent("sessions.json")
        try OMGPrivateFileWriter.writeAtomically(snapshotData, to: stateURL)
        try OMGPrivateFileWriter.writeAtomically(snapshotData, to: previousURL)
        try OMGPrivateFileWriter.writeAtomically(snapshotData, to: sessionsURL)

        let ran = try SessionRuntimeUpgradeCutover.performIfNeeded(
            applicationSupportRoot: support,
            homeDirectory: home,
            bundledRevision: "rev-new-epoch",
            terminateProcesses: false
        )
        #expect(ran)

        for fileURL in [stateURL, previousURL, sessionsURL] {
            let updated = try JSONDecoder().decode(
                TerminalWorkspaceSessionStore.Snapshot.self,
                from: Data(contentsOf: fileURL)
            )
            #expect(updated.isComplete)
            #expect(updated.tabs.map(\.id) == [tabOne, tabTwo, tabParked])
            #expect(updated.catalog == catalog)
            #expect(updated.foregroundTab == tabTwo)

            let updatedOne = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: updated.tabs[0].state)
            #expect(updatedOne.tabColor == .purple)
            #expect(updatedOne.titleOverride == "Workspace Split Tab")
            guard case .split(let branch) = updatedOne.surfaceTree.root,
                  case .leaf(let newLeft) = branch.left,
                  case .leaf(let newRight) = branch.right else {
                Issue.record("Expected split hierarchy to be preserved")
                return
            }
            #expect(branch.direction == .horizontal)
            #expect(branch.ratio == 0.35)

            #expect(newLeft.uuid != paneLocalLeftOld)
            #expect(UUID(uuidString: newLeft.uuid) != nil)
            #expect(newLeft.pwd == "/tmp/local-active")
            #expect(newLeft.title == "Custom Left")
            #expect(newLeft.isUserSetTitle == true)
            #expect(newLeft.agentResumeDescriptor == agentResume)
            #expect(newLeft.runtimeCreateOnRestore == true)
            #expect(newLeft.runtimeDescriptor?.revision == "rev-new-epoch")
            #expect(newLeft.runtimeDescriptor?.initialWorkingDirectory == "/tmp/local-active")

            #expect(newRight.uuid != paneLocalRightOld)
            #expect(updatedOne.focusedSurface == newRight.uuid)
            #expect(newRight.pwd == nil)
            #expect(newRight.title == "Right Fallback")
            #expect(newRight.isUserSetTitle == false)
            #expect(newRight.runtimeCreateOnRestore == true)
            #expect(newRight.runtimeDescriptor?.revision == "rev-new-epoch")
            #expect(newRight.runtimeDescriptor?.initialWorkingDirectory == "/tmp/right-local")

            // Verify raw tab.state JSON preserves `"pwd":null` for SurfaceView decoding.
            let rawOne = try #require(
                try JSONSerialization.jsonObject(with: updated.tabs[0].state) as? [String: Any]
            )
            let rawTree = try #require(rawOne["surfaceTree"] as? [String: Any])
            let rawRoot = try #require(rawTree["root"] as? [String: Any])
            let rawSplit = try #require(rawRoot["split"] as? [String: Any])
            let rawRight = try #require(rawSplit["right"] as? [String: Any])
            let rawRightView = try #require(rawRight["view"] as? [String: Any])
            #expect(rawRightView["pwd"] is NSNull)

            let updatedTwo = try JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: updated.tabs[1].state)
            #expect(updatedTwo.tabColor == .teal)
            let newSSH = try #require(updatedTwo.surfaceTree.root?.panes.first)
            #expect(newSSH.uuid != paneSSHOld)
            #expect(updatedTwo.focusedSurface == newSSH.uuid)
            #expect(newSSH.pwd == "/srv/remote-work")
            #expect(newSSH.title == "Remote Box")
            #expect(newSSH.isUserSetTitle == true)
            #expect(newSSH.sshResumeDescriptor == sshResume)
            #expect(newSSH.runtimeCreateOnRestore == true)
            #expect(newSSH.runtimeDescriptor?.revision == "rev-new-epoch")
            #expect(newSSH.runtimeDescriptor?.initialWorkingDirectory == "/srv/remote-work")
        }
    }

    @Test func cutoverIsIdempotentAtEpoch2AndUpgradesEpoch1() throws {
        let root = URL(fileURLWithPath: "/tmp/omg-cut-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("Support/OMG Dev", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let epochURL = support.appendingPathComponent("session-runtime/runtime-epoch.json")
        try OMGPrivateFileWriter.writeAtomically(JSONEncoder().encode(EpochFixture(epoch: 1)), to: epochURL)

        let firstRun = try SessionRuntimeUpgradeCutover.performIfNeeded(
            applicationSupportRoot: support,
            homeDirectory: home,
            bundledRevision: "rev-2",
            terminateProcesses: false
        )
        #expect(firstRun)
        let updatedEpoch = try JSONDecoder().decode(EpochFixture.self, from: Data(contentsOf: epochURL))
        #expect(updatedEpoch.epoch == SessionRuntimeUpgradeCutover.currentEpoch)

        let sentinel = support.appendingPathComponent("session-runtime/pending-closes.json")
        try Data("[]".utf8).write(to: sentinel)

        let secondRun = try SessionRuntimeUpgradeCutover.performIfNeeded(
            applicationSupportRoot: support,
            homeDirectory: home,
            bundledRevision: "rev-3",
            terminateProcesses: false
        )
        #expect(!secondRun)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath:
        Bundle.main.resourceURL!.appendingPathComponent("session-runtime/omgd").path),
        "Requires the bundled Session Runtime helper"))
    func cutoverTerminatesOnlyOwnChannelOMGDProcesses() async throws {
        let root = URL(fileURLWithPath: "/tmp/omg-cut-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let supportDev = root.appendingPathComponent("Support/OMG Dev", isDirectory: true)
        let supportRelease = root.appendingPathComponent("Support/OMG", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDev, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportRelease, withIntermediateDirectories: true)

        let helper = Bundle.main.resourceURL!.appendingPathComponent("session-runtime/omgd")
        let devRunDir = SessionRuntimeConnections.legacyLocalStateDirectory(
            supportRoot: supportDev,
            revision: "rev-proc-dev",
            homeDirectory: home
        )
        let releaseRunDir = SessionRuntimeConnections.legacyLocalStateDirectory(
            supportRoot: supportRelease,
            revision: "rev-proc-rel",
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: devRunDir.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: releaseRunDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((supportDev.resolvingSymlinksInPath().path + "\n").utf8)
            .write(to: devRunDir.appendingPathComponent("support-root"))
        try Data((supportRelease.resolvingSymlinksInPath().path + "\n").utf8)
            .write(to: releaseRunDir.appendingPathComponent("support-root"))

        let devHost = Process()
        devHost.executableURL = helper
        devHost.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        devHost.arguments = ["host-local", devRunDir.path, "--", "/bin/sh", "-i"]
        devHost.standardInput = FileHandle.nullDevice
        devHost.standardOutput = FileHandle.nullDevice
        devHost.standardError = FileHandle.nullDevice

        let releaseHost = Process()
        releaseHost.executableURL = helper
        releaseHost.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        releaseHost.arguments = ["host-local", releaseRunDir.path, "--", "/bin/sh", "-i"]
        releaseHost.standardInput = FileHandle.nullDevice
        releaseHost.standardOutput = FileHandle.nullDevice
        releaseHost.standardError = FileHandle.nullDevice

        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        bystander.standardInput = FileHandle.nullDevice
        bystander.standardOutput = FileHandle.nullDevice
        bystander.standardError = FileHandle.nullDevice

        defer {
            if devHost.isRunning { devHost.terminate() }
            if releaseHost.isRunning { releaseHost.terminate() }
            if bystander.isRunning { bystander.terminate() }
        }

        try devHost.run()
        try releaseHost.run()
        try bystander.run()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: devRunDir.appendingPathComponent("host.sock").path)
            || !FileManager.default.fileExists(atPath: releaseRunDir.appendingPathComponent("host.sock").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: devRunDir.appendingPathComponent("host.sock").path))
        try #require(FileManager.default.fileExists(atPath: releaseRunDir.appendingPathComponent("host.sock").path))
        try #require(devHost.isRunning)
        try #require(releaseHost.isRunning)

        let fakeRecord = ["pid": bystander.processIdentifier]
        try JSONSerialization.data(withJSONObject: fakeRecord).write(
            to: devRunDir.appendingPathComponent("sessions/\(UUID().uuidString.lowercased()).json")
        )

        let ran = try SessionRuntimeUpgradeCutover.performIfNeeded(
            applicationSupportRoot: supportDev,
            homeDirectory: home,
            bundledRevision: "rev-proc-dev",
            terminateProcesses: true
        )
        #expect(ran)
        for _ in 0..<50 where devHost.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!devHost.isRunning)
        #expect(!FileManager.default.fileExists(atPath: devRunDir.path))
        #expect(releaseHost.isRunning)
        #expect(FileManager.default.fileExists(atPath: releaseRunDir.path))
        #expect(bystander.isRunning)
    }
}
