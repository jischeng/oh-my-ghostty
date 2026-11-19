import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SessionRuntimeRevisionHandoffTests {
    private actor MockHandoffTransport: SessionRuntimeRevisionHandoffTransport {
        struct ProbeCall: Equatable, Sendable {
            let revision: String
            let paneID: UUID
            let interactive: Bool
        }

        struct CloseCall: Equatable, Sendable {
            let revision: String
            let paneID: UUID
            let interactive: Bool
            let timeoutSeconds: Int
        }

        var probeResult: Result<SessionRuntimeRevisionHandoffProbeResult, Error>
        var closeResult: Result<Void, Error>
        private(set) var probeCalls: [ProbeCall] = []
        private(set) var closeCalls: [CloseCall] = []

        init(
            probeResult: Result<SessionRuntimeRevisionHandoffProbeResult, Error> = .success(.gone),
            closeResult: Result<Void, Error> = .success(())
        ) {
            self.probeResult = probeResult
            self.closeResult = closeResult
        }

        func probe(
            sourceDescriptor: SessionRuntimeDescriptor,
            paneID: UUID,
            interactive: Bool
        ) async throws -> SessionRuntimeRevisionHandoffProbeResult {
            probeCalls.append(.init(revision: sourceDescriptor.revision, paneID: paneID, interactive: interactive))
            return try probeResult.get()
        }

        func closeSession(
            sourceDescriptor: SessionRuntimeDescriptor,
            paneID: UUID,
            interactive: Bool,
            timeoutSeconds: Int
        ) async throws {
            closeCalls.append(.init(
                revision: sourceDescriptor.revision,
                paneID: paneID,
                interactive: interactive,
                timeoutSeconds: timeoutSeconds
            ))
            try closeResult.get()
        }

        func recordedProbeCalls() -> [ProbeCall] { probeCalls }
        func recordedCloseCalls() -> [CloseCall] { closeCalls }
    }

    private func makeContext(
        paneID: UUID = UUID(),
        savedWorkingDirectory: String? = "/srv/repo",
        savedAgentResume: AgentResumeDescriptor? = nil
    ) throws -> SessionRuntimeRevisionHandoffContext {
        let connection = try GitSSHConnection(destination: "devbox")
        let source = SessionRuntimeDescriptor(connection: connection, revision: "rev-0216-old", policy: .init())
        let target = SessionRuntimeDescriptor(connection: connection, revision: "rev-0221-new", policy: .init())
        return SessionRuntimeRevisionHandoffContext(
            paneID: paneID,
            sourceDescriptor: source,
            targetDescriptor: target,
            savedWorkingDirectory: savedWorkingDirectory,
            savedAgentResume: savedAgentResume
        )
    }

    @Test func restoreNormalizationDetectsIncompatibleRemoteSnapshotRevisionAndSkipsLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let bundledRuntime = resources.appendingPathComponent("session-runtime", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledRuntime, withIntermediateDirectories: true)
        try Data("rev-0221\n".utf8).write(to: bundledRuntime.appendingPathComponent("revision"))
        try Data("7abe5365444c63ee8df6\n".utf8).write(to: bundledRuntime.appendingPathComponent("snapshot-revision"))

        // Local runtime shares one state directory and attaches live holders directly: no revision handoff.
        let localOld = SessionRuntimeDescriptor(
            connection: nil,
            revision: "rev-0216",
            policy: .init(),
            localWorkingDirectory: "/tmp"
        )
        let localNorm = SessionRuntimeConnections.restoreNormalization(
            localOld,
            applicationSupportRoot: support,
            resources: resources
        )
        #expect(localNorm.descriptor.revision == "rev-0221")
        #expect(localNorm.handoffSourceDescriptor == nil)

        let connection = try GitSSHConnection(destination: "devbox")

        // Same revision: no handoff.
        let currentSSH = SessionRuntimeDescriptor(connection: connection, revision: "rev-0221", policy: .init())
        let currentNorm = SessionRuntimeConnections.restoreNormalization(
            currentSSH,
            applicationSupportRoot: support,
            resources: resources
        )
        #expect(currentNorm.descriptor.revision == "rev-0221")
        #expect(currentNorm.handoffSourceDescriptor == nil)

        // Compatible cached snapshot-revision: stays on previous revision, no handoff.
        let compatSSH = SessionRuntimeDescriptor(connection: connection, revision: "rev-compat", policy: .init())
        let compatDir = support.appendingPathComponent("session-runtime/versions/rev-compat", isDirectory: true)
        try FileManager.default.createDirectory(at: compatDir, withIntermediateDirectories: true)
        try Data("rev-compat\n".utf8).write(to: compatDir.appendingPathComponent("revision"))
        try Data("7abe5365444c63ee8df6\n".utf8).write(to: compatDir.appendingPathComponent("snapshot-revision"))
        let compatNorm = SessionRuntimeConnections.restoreNormalization(
            compatSSH,
            applicationSupportRoot: support,
            resources: resources
        )
        #expect(compatNorm.descriptor.revision == "rev-compat")
        #expect(compatNorm.handoffSourceDescriptor == nil)

        // Incompatible cached snapshot-revision (v0.21.6 -> v0.22.1): requires graceful handoff!
        let incompatSSH = SessionRuntimeDescriptor(connection: connection, revision: "rev-0216", policy: .init())
        let incompatDir = support.appendingPathComponent("session-runtime/versions/rev-0216", isDirectory: true)
        try FileManager.default.createDirectory(at: incompatDir, withIntermediateDirectories: true)
        try Data("rev-0216\n".utf8).write(to: incompatDir.appendingPathComponent("revision"))
        try Data("59c5cc7b4d1fe408faf5\n".utf8).write(to: incompatDir.appendingPathComponent("snapshot-revision"))
        let incompatNorm = SessionRuntimeConnections.restoreNormalization(
            incompatSSH,
            applicationSupportRoot: support,
            resources: resources
        )
        #expect(incompatNorm.descriptor.revision == "rev-0221")
        #expect(incompatNorm.handoffSourceDescriptor == incompatSSH)

        // Missing local version cache for an older SSH revision: still requires handoff probe!
        let missingSSH = SessionRuntimeDescriptor(connection: connection, revision: "rev-pruned", policy: .init())
        let missingNorm = SessionRuntimeConnections.restoreNormalization(
            missingSSH,
            applicationSupportRoot: support,
            resources: resources
        )
        #expect(missingNorm.descriptor.revision == "rev-0221")
        #expect(missingNorm.handoffSourceDescriptor == missingSSH)
    }

    @Test func holdsAutoResumeWhenPreviousSessionAliveThenGracefullyClosesSingleSessionAndResumes() async throws {
        let paneID = UUID()
        let context = try makeContext(paneID: paneID)
        let agyResume = SessionRuntimeHandoffResume(
            agent: "antigravity",
            conversationID: "conv-agy-1234",
            cwd: "/srv/repo"
        )
        let transport = MockHandoffTransport(
            probeResult: .success(.alive(pid: 4242, cwd: "/srv/repo", resume: agyResume)),
            closeResult: .success(())
        )
        let coordinator = SessionRuntimeRevisionHandoffCoordinator(context: context)

        // 1. Probe finds live session -> MUST hold auto-resume and NOT close anything.
        let probeResolution = await coordinator.runProbe(interactive: false, transport: transport)
        #expect(probeResolution == .stay(.awaitingUser(
            isConfirmedAlive: true,
            pid: 4242,
            cwd: "/srv/repo",
            resume: agyResume,
            probeError: nil
        )))
        #expect(await transport.recordedCloseCalls().isEmpty)

        // 2. User triggers Graceful Handoff -> closes ONLY this single paneID on previousRevision, then launches currentRevision with resume.
        let handoffResolution = await coordinator.performGracefulHandoff(transport: transport, timeoutSeconds: 12)
        let closeCalls = await transport.recordedCloseCalls()
        #expect(closeCalls.count == 1)
        #expect(closeCalls[0].revision == "rev-0216-old")
        #expect(closeCalls[0].paneID == paneID)
        #expect(closeCalls[0].interactive == true)
        #expect(closeCalls[0].timeoutSeconds == 12)

        #expect(handoffResolution == .launch(SessionRuntimeRevisionHandoffLaunchPlan(
            paneID: paneID,
            descriptor: context.targetDescriptor,
            workingDirectory: "/srv/repo",
            resume: agyResume
        )))
    }

    @Test func autoProceedsSeamlesslyWhenPreviousSessionAlreadyExitedOrGone() async throws {
        let paneID = UUID()
        let context = try makeContext(paneID: paneID)
        let claudeResume = SessionRuntimeHandoffResume(
            agent: "claude",
            conversationID: "conv-claude-789",
            cwd: "/srv/backend"
        )

        let exitedTransport = MockHandoffTransport(
            probeResult: .success(.exited(ended: "process_exited", cwd: "/srv/backend", resume: claudeResume))
        )
        let coordinator = SessionRuntimeRevisionHandoffCoordinator(context: context)
        let exitedResolution = await coordinator.runProbe(interactive: false, transport: exitedTransport)
        #expect(exitedResolution == .launch(SessionRuntimeRevisionHandoffLaunchPlan(
            paneID: paneID,
            descriptor: context.targetDescriptor,
            workingDirectory: "/srv/backend",
            resume: claudeResume
        )))
        #expect(await exitedTransport.recordedCloseCalls().isEmpty)

        // Gone on remote host -> uses saved macOS AgentResumeDescriptor if present.
        let savedResume = AgentResumeDescriptor(
            agent: .antigravity,
            conversationID: AgentConversationID("conv-saved-555"),
            scope: .remote,
            workingDirectory: "/srv/saved"
        )
        let goneContext = try makeContext(
            paneID: paneID,
            savedWorkingDirectory: "/srv/saved",
            savedAgentResume: savedResume
        )
        let goneTransport = MockHandoffTransport(probeResult: .success(.gone))
        let goneCoordinator = SessionRuntimeRevisionHandoffCoordinator(context: goneContext)
        let goneResolution = await goneCoordinator.runProbe(interactive: false, transport: goneTransport)
        #expect(goneResolution == .launch(SessionRuntimeRevisionHandoffLaunchPlan(
            paneID: paneID,
            descriptor: goneContext.targetDescriptor,
            workingDirectory: "/srv/saved",
            resume: SessionRuntimeHandoffResume(
                agent: "antigravity",
                conversationID: "conv-saved-555",
                cwd: "/srv/saved"
            )
        )))
        #expect(await goneTransport.recordedCloseCalls().isEmpty)
    }

    @Test func closeFailureRefusesDoubleResumeAndPreservesStateForRetry() async throws {
        let paneID = UUID()
        let context = try makeContext(paneID: paneID)
        let resume = SessionRuntimeHandoffResume(
            agent: "antigravity",
            conversationID: "conv-lock-999",
            cwd: "/srv/repo"
        )
        let timeoutError = NSError(
            domain: "OMGSessionRuntimeHandoff",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the previous session to exit."]
        )
        let transport = MockHandoffTransport(
            probeResult: .success(.alive(pid: 888, cwd: "/srv/repo", resume: resume)),
            closeResult: .failure(timeoutError)
        )
        let coordinator = SessionRuntimeRevisionHandoffCoordinator(context: context)

        _ = await coordinator.runProbe(interactive: false, transport: transport)
        let failedResolution = await coordinator.performGracefulHandoff(transport: transport)
        #expect(failedResolution == .stay(.closeFailed(
            message: "Timed out waiting for the previous session to exit.",
            cwd: "/srv/repo",
            resume: resume
        )))
        #expect(coordinator.state.effectiveResume == resume)
    }

    @Test func unreachableSSHHostHoldsAutoResumeAndFreshShellLeavesOldSessionUntouched() async throws {
        let paneID = UUID()
        let savedResume = AgentResumeDescriptor(
            agent: .claude,
            conversationID: AgentConversationID("conv-offline-1"),
            scope: .remote,
            workingDirectory: "/srv/offline"
        )
        let context = try makeContext(
            paneID: paneID,
            savedWorkingDirectory: "/srv/offline",
            savedAgentResume: savedResume
        )
        let sshError = NSError(
            domain: "OMGSessionRuntimeHandoff",
            code: 255,
            userInfo: [NSLocalizedDescriptionKey: "ssh: connect to host devbox port 22: Operation timed out"]
        )
        let transport = MockHandoffTransport(probeResult: .failure(sshError))
        let coordinator = SessionRuntimeRevisionHandoffCoordinator(context: context)

        let resolution = await coordinator.runProbe(interactive: false, transport: transport)
        #expect(resolution == .stay(.awaitingUser(
            isConfirmedAlive: false,
            pid: nil,
            cwd: "/srv/offline",
            resume: SessionRuntimeHandoffResume(
                agent: "claude",
                conversationID: "conv-offline-1",
                cwd: "/srv/offline"
            ),
            probeError: "ssh: connect to host devbox port 22: Operation timed out"
        )))

        // Fresh shell fallback uses a new UUID, drops --resume, and never closes the old session.
        let freshID = UUID()
        let freshPlan = coordinator.freshShellPlan(newPaneID: freshID)
        #expect(freshPlan.paneID == freshID)
        #expect(freshPlan.paneID != paneID)
        #expect(freshPlan.descriptor == context.targetDescriptor)
        #expect(freshPlan.workingDirectory == "/srv/offline")
        #expect(freshPlan.resume == nil)
        #expect(await transport.recordedCloseCalls().isEmpty)
    }

    @Test func plainShellHandoffWorksWithoutAgentResume() async throws {
        let paneID = UUID()
        let context = try makeContext(paneID: paneID, savedWorkingDirectory: "/srv/work", savedAgentResume: nil)
        let transport = MockHandoffTransport(
            probeResult: .success(.alive(pid: 99, cwd: "/srv/work", resume: nil)),
            closeResult: .success(())
        )
        let coordinator = SessionRuntimeRevisionHandoffCoordinator(context: context)

        let probeResolution = await coordinator.runProbe(interactive: false, transport: transport)
        #expect(probeResolution == .stay(.awaitingUser(
            isConfirmedAlive: true,
            pid: 99,
            cwd: "/srv/work",
            resume: nil,
            probeError: nil
        )))

        let handoffResolution = await coordinator.performGracefulHandoff(transport: transport)
        #expect(handoffResolution == .launch(SessionRuntimeRevisionHandoffLaunchPlan(
            paneID: paneID,
            descriptor: context.targetDescriptor,
            workingDirectory: "/srv/work",
            resume: nil
        )))
    }

    @Test func openRequestIncludesResumeOnlyWhenSpawningRemoteSessionAndProbeDecodesJSON() throws {
        let connection = try GitSSHConnection(destination: "devbox")
        let remote = SessionRuntimeDescriptor(connection: connection, revision: "rev-0221", policy: .init())
        let resume = SessionRuntimeHandoffResume(
            agent: "antigravity",
            conversationID: "conv-42",
            cwd: "/srv/app"
        )
        let paneID = UUID()

        let createJSON = try #require(
            try JSONSerialization.jsonObject(
                with: Data(remote.openRequest(pane: paneID, attachExisting: false, resume: resume).utf8)
            ) as? [String: Any]
        )
        let encodedResume = try #require(createJSON["resume"] as? [String: String])
        #expect(encodedResume["agent"] == "antigravity")
        #expect(encodedResume["conversation_id"] == "conv-42")
        #expect(encodedResume["cwd"] == "/srv/app")

        let attachJSON = try #require(
            try JSONSerialization.jsonObject(
                with: Data(remote.openRequest(pane: paneID, attachExisting: true, recreateIfGone: false, resume: resume).utf8)
            ) as? [String: Any]
        )
        #expect(attachJSON["resume"] == nil)

        // Control-only connection JSON works without cached local version artifacts.
        let controlData = try SessionRuntimeConnections.handoffConnectionConfiguration(remote, interactive: false)
        let controlJSON = try #require(
            try JSONSerialization.jsonObject(with: controlData) as? [String: Any]
        )
        #expect(controlJSON["auto_install"] as? Bool == false)
        #expect(controlJSON["revision"] as? String == "rev-0221")
        #expect(controlJSON["bundle"] as? String == "")

        // Probe JSON decoding.
        let alivePayload = Data("""
        {"status":"alive","pid":321,"cwd":"/srv/app","resume":{"agent":"codex","conversation_id":"c-1","cwd":"/srv/app"}}
        """.utf8)
        #expect(try SessionRuntimeRevisionHandoffProbeResult.decode(alivePayload) == .alive(
            pid: 321,
            cwd: "/srv/app",
            resume: SessionRuntimeHandoffResume(agent: "codex", conversationID: "c-1", cwd: "/srv/app")
        ))
        #expect(try SessionRuntimeRevisionHandoffProbeResult.decode(Data(#"{"status":"gone"}"#.utf8)) == .gone)

        // Localized copy sanity.
        let en = SessionRuntimeRevisionHandoffStrings(language: .english)
        let zh = SessionRuntimeRevisionHandoffStrings(language: .simplifiedChinese)
        #expect(en.handoffActionTitle(hasResume: true) == "Hand Off & Resume")
        #expect(zh.handoffActionTitle(hasResume: true) == "优雅接管并恢复")
        #expect(en.openFreshShellTitle == "Open Fresh Shell")
        #expect(zh.openFreshShellTitle == "仅打开新终端")
    }
}
