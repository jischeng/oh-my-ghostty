import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SSHRecoveryTests {
    private func controller() throws -> TerminalController {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        config.workingDirectory = "/tmp"
        return TerminalController(app.ghostty, withBaseConfig: config)
    }

    @Test func disconnectClearsLiveAgentButPreservesOfflineConversation() throws {
        let controller = try controller()
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
            terminfo: false, cache: false, args: ["cloud"])
        let id = "omg-ssh-\(UUID().uuidString)"
        let url = try #require(SSHReplayStore.url(for: id))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(replay).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        surface.contextSignal = .init(action: .start, id: id,
            metadata: "type=remote;targethost=cloud;cwd=/remote/project")
        let agent = AgentResumeDescriptor(agent: .pi,
            conversationID: try #require(AgentConversationID("conversation-123")),
            scope: .remote, workingDirectory: "/remote/project", sshReplay: replay)
        controller.adoptAgentResumeDescriptor(agent, for: surface)
        surface.contextSignal = .init(action: .end, id: id, metadata: "status=255;cwd=/tmp")
        #expect(surface.agentResumeDescriptor == nil)
        #expect(controller.agentResumeDescriptor(for: surface) == nil)
        let recovery = try #require(controller.pendingSSHRecovery(for: surface))
        #expect(recovery.interruptedAgent == agent)
        #expect(recovery.remoteWorkingDirectory == "/remote/project")
        #expect(controller.paneSessionContext(for: surface)?.workspace == nil)

        surface.contextSignal = .init(action: .end, id: "omg-agent-pi-42", metadata: "")
        #expect(controller.pendingSSHRecovery(for: surface) == recovery)
        controller.dismissSSHRecovery(for: surface)
        surface.contextSignal = .init(action: .end, id: "omg-agent-pi-43", metadata: "")
        #expect(surface.sshResumeDescriptor == nil)
    }

    @Test func fastRetryFailureUsesOneShotLaunchHandoff() throws {
        let controller = try controller()
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
            terminfo: false, cache: false, args: ["cloud"])
        let descriptor = SSHResumeDescriptor(sshReplay: replay, remoteWorkingDirectory: "/remote/work",
            localWorkingDirectory: "/tmp", awaitingReconnect: true)
        controller.adoptSSHRecoveryDescriptor(descriptor, for: surface)
        surface.pendingSSHLaunchReplay = replay
        // No replay file exists: the child already exited and removed it.
        let id = "omg-ssh-\(UUID().uuidString)"
        surface.contextSignal = .init(action: .start, id: id, metadata: "type=remote;targethost=cloud")
        #expect(surface.pendingSSHLaunchReplay == nil)
        #expect(controller.pendingSSHRecovery(for: surface) == nil)
        surface.contextSignal = .init(action: .end, id: id, metadata: "status=255;cwd=/tmp")
        #expect(controller.pendingSSHRecovery(for: surface)?.remoteWorkingDirectory == "/remote/work")
    }

    @Test func restoredOfflineIntentSurvivesLocalSignalsAndReencodes() throws {
        let controller = try controller()
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let descriptor = SSHResumeDescriptor(
            sshReplay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
                terminfo: false, cache: false, args: ["cloud"]),
            remoteWorkingDirectory: "/remote/work", localWorkingDirectory: "/tmp", awaitingReconnect: true)
        controller.adoptSSHRecoveryDescriptor(descriptor, for: surface)
        surface.contextSignal = .init(action: .end, id: "omg-agent-pi-42", metadata: "")
        #expect(controller.pendingSSHRecovery(for: surface) == descriptor)
        let data = try JSONEncoder().encode(surface)
        let archive = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let saved = try #require(archive["sshResumeDescriptor"] as? [String: Any])
        #expect(saved["awaitingReconnect"] as? Bool == true)
        #expect(saved["remoteWorkingDirectory"] as? String == "/remote/work")
        if OhMyGhosttySettings.shared.startupMode.restoresSessions {
            let restored = try JSONDecoder().decode(Ghostty.SurfaceView.self, from: data)
            #expect(restored.sshResumeDescriptor == descriptor)
            #expect(restored.agentResumeDescriptor == nil)
        }
        controller.dismissSSHRecovery(for: surface)
        #expect(controller.pendingSSHRecovery(for: surface) == nil)
    }
}
