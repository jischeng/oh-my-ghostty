import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct NewSessionInheritanceTests {
    private let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
                                             cache: false, args: ["devbox"], localWorkingDirectory: "/Users/me/src")
    private let conversation = AgentConversationID("conv-123")

    @Test func defaultsPreserveTabDirectoryAndSplitSSHBehavior() {
        #expect(NewSessionInheritance.defaultValue(for: .tab) == .workingDirectory)
        #expect(NewSessionInheritance.defaultValue(for: .split) == .ssh)
        #expect(NewSessionInheritance.allCases.map(\.rawValue) == ["default", "directory", "ssh", "agent", "agentResume"])
        #expect(!NewSessionInheritance.workingDirectory.inheritsSSH)
        #expect(NewSessionInheritance.agentNewSession.inheritsSSH && NewSessionInheritance.agentResume.inheritsSSH)
        #expect(!NewSessionInheritance.ssh.inheritsAgent)
    }

    @Test func nonAgentLevelsNeverBuildAnAgentLaunch() {
        for level in [NewSessionInheritance.defaultDirectory, .workingDirectory, .ssh] {
            #expect(NewSessionInheritance.agentLaunch(
                level: level, agent: .claude, conversationID: conversation, remote: nil,
                localWorkingDirectory: "/tmp", executablePath: "/omg"
            ) == nil)
        }
    }

    @Test func localAgentStartsNewSessionOrResumesTheSameID() throws {
        let fresh = try #require(NewSessionInheritance.agentLaunch(
            level: .agentNewSession, agent: .claude, conversationID: conversation, remote: nil,
            localWorkingDirectory: "/tmp/project", executablePath: "/omg"
        ))
        #expect(fresh.descriptor.scope == .local)
        #expect(fresh.descriptor.conversationID == nil)
        #expect(fresh.descriptor.workingDirectory == "/tmp/project")
        #expect(!fresh.command.contains("conv-123"))

        let resumed = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .claude, conversationID: conversation, remote: nil,
            localWorkingDirectory: "/tmp/project", executablePath: "/omg"
        ))
        #expect(resumed.descriptor.conversationID == conversation)
        #expect(resumed.command.contains("conv-123"))
    }

    @Test func resumeFallsBackToNewSessionWithoutIDOrResumeSupport() throws {
        let withoutID = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .claude, conversationID: nil, remote: nil,
            localWorkingDirectory: "/tmp", executablePath: "/omg"
        ))
        #expect(withoutID.descriptor.conversationID == nil)
        // Amp declares no resume arguments.
        let unsupported = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .amp, conversationID: conversation, remote: nil,
            localWorkingDirectory: "/tmp", executablePath: "/omg"
        ))
        #expect(unsupported.descriptor.conversationID == nil)
        #expect(!unsupported.command.contains("conv-123"))
    }

    @Test func remoteAgentKeepsTheSSHConnectionAndRemoteDirectory() throws {
        let fresh = try #require(NewSessionInheritance.agentLaunch(
            level: .agentNewSession, agent: .codex, conversationID: conversation, remote: .init(replay: replay, workingDirectory: "/srv/app"),
            localWorkingDirectory: "/Users/me/src", executablePath: "/omg"
        ))
        #expect(fresh.descriptor.scope == .remote)
        #expect(fresh.descriptor.sshReplay == replay)
        #expect(fresh.descriptor.workingDirectory == "/srv/app")
        #expect(fresh.command.contains("'--remote-agent=codex'"))
        #expect(fresh.command.contains("'--remote-working-directory=/srv/app'"))
        #expect(!fresh.command.contains("--remote-agent-session"))

        let resumed = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .codex, conversationID: conversation, remote: .init(replay: replay, workingDirectory: "/srv/app"),
            localWorkingDirectory: "/Users/me/src", executablePath: "/omg"
        ))
        #expect(resumed.command.contains("'--remote-agent-session=conv-123'"))
        #expect(resumed.descriptor.conversationID == conversation)
    }

    @Test func agentConfigurationRunsTheLaunchWithoutRuntimeBackend() throws {
        let launch = try #require(NewSessionInheritance.agentLaunch(
            level: .agentNewSession, agent: .claude, conversationID: nil, remote: nil,
            localWorkingDirectory: "/tmp", executablePath: "/omg"
        ))
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.environmentVariables[SessionRuntimeDescriptor.environmentKey] = "{}"
        inherited.environmentVariables["OMG_RUNTIME_SOCKET"] = "/tmp/sock"
        inherited.initialInput = "ls\n"
        let configuration = NewSessionInheritance.configuration(for: launch, inherited: inherited,
                                                                localWorkingDirectory: "/tmp")
        #expect(configuration.workingDirectory == "/tmp")
        #expect(configuration.command == TerminalController.replaySurvivalCommand(launch.command))
        #expect(configuration.initialInput == nil)
        #expect(configuration.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
        #expect(configuration.environmentVariables["OMG_RUNTIME_SOCKET"] == nil)
    }

    @MainActor
    @Test func splitLevelsFromRemotePaneControlSSHInheritance() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        let descriptor = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp"),
            revision: "test", policy: .init()
        )
        view.runtimeDescriptor = descriptor
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        try descriptor.configure(&config)
        config.workingDirectory = "/remote/only"

        let directory = try controller.newSplitLaunch(inherited: config, from: view, level: .workingDirectory)
        #expect(directory.configuration?.workingDirectory == "/tmp")
        #expect(directory.configuration?.command == nil)
        #expect(directory.agentDescriptor == nil)
        #expect(directory.configuration?.environmentVariables["OH_MY_GHOSTTY_SESSION"] ==
            controller.tabSessionID.uuidString)

        let fallback = try controller.newSplitLaunch(inherited: config, from: view, level: .defaultDirectory)
        #expect(fallback.configuration?.workingDirectory == nil)
        #expect(fallback.configuration?.command == nil)

        let tab = controller.newTabLaunch(inherited: config, from: view, level: .defaultDirectory)
        #expect(tab.configuration?.workingDirectory == nil)
        #expect(tab.configuration?.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
    }

    @MainActor
    @Test func agentLevelsReuseTheFocusedPaneAgentDescriptor() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        view.pwd = "/tmp/agent-project"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }

        // Without an Agent, Agent levels fall back to the SSH/directory result.
        let plain = try controller.newSplitLaunch(inherited: config, from: view, level: .agentResume)
        #expect(plain.agentDescriptor == nil)

        controller.adoptAgentResumeDescriptor(
            AgentResumeDescriptor(agent: .claude, conversationID: conversation, scope: .local,
                                  workingDirectory: "/tmp/agent-project"),
            for: view
        )
        let fresh = try controller.newSplitLaunch(inherited: config, from: view, level: .agentNewSession)
        #expect(fresh.agentDescriptor?.agent == .claude)
        #expect(fresh.agentDescriptor?.conversationID == nil)
        #expect(fresh.configuration?.workingDirectory == "/tmp/agent-project")
        #expect(fresh.configuration?.command?.contains("conv-123") == false)

        let resumed = controller.newTabLaunch(inherited: config, from: view, level: .agentResume)
        #expect(resumed.agentDescriptor?.conversationID == conversation)
        #expect(resumed.configuration?.command?.contains("conv-123") == true)
    }

    @MainActor
    @Test func settingsPersistBothEntriesIndependently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-inheritance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.newTabInheritance == .workingDirectory)
        #expect(settings.newSplitInheritance == .ssh)
        settings.newTabInheritance = .defaultDirectory
        settings.newSplitInheritance = .agentResume
        #expect(NewSessionInheritance.current(for: .tab, settings: settings) == .defaultDirectory)
        #expect(NewSessionInheritance.current(for: .split, settings: settings) == .agentResume)
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.newTabInheritance == .defaultDirectory)
        #expect(restored.newSplitInheritance == .agentResume)
        let ids = OhMyGhosttySettings.descriptors.map(\.id)
        #expect(ids.contains("sessions.newTabInheritance") && ids.contains("sessions.newSplitInheritance"))
    }

    @MainActor
    @Test func localRuntimeDoesNotInterceptPassthroughOrForegroundSSHOrLeakRemotePwd() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp/local-origin"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        view.runtimeDescriptor = .init(
            connection: nil,
            revision: "local-rev",
            policy: .init(),
            localWorkingDirectory: "/tmp/local-origin"
        )
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }

        let connectionID = "omg-ssh-\(UUID().uuidString)"
        let passthroughReplay = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: true,
            terminfo: true,
            cache: true,
            args: ["-o", "StrictHostKeyChecking=accept-new", "passthrough-box"],
            localWorkingDirectory: "/tmp/local-origin"
        )
        view.pendingSSHLaunchReplay = passthroughReplay
        view.contextSignal = .init(
            action: .start,
            id: connectionID,
            metadata: "type=remote;targethost=passthrough-box;localcwd=/tmp/local-origin;cwd=/srv/remote-only"
        )
        view.pwd = "/srv/remote-only"

        // Archive/state capture on a local-runtime pane showing non-inline SSH
        // must persist the pre-SSH local directory rather than the remote pwd.
        #expect(TerminalWorkspaceSessionState.Pane(view).pwd == "/tmp/local-origin")

        var inheritedSplit = Ghostty.SurfaceConfiguration()
        inheritedSplit.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        inheritedSplit.workingDirectory = "/srv/remote-only"
        let split = try #require(try controller.splitConfiguration(
            inherited: inheritedSplit,
            from: view,
            runtimeRevision: "local-next",
            localRuntimeEnabled: true
        ))
        #expect(split.workingDirectory == "/tmp/local-origin")
        #expect(split.command?.contains("'+ssh'") == true)
        #expect(split.command?.contains("'--remote-working-directory=/srv/remote-only'") == true)
        #expect(split.command?.contains("'passthrough-box'") == true)
        let splitRuntime = try JSONDecoder().decode(
            SessionRuntimeDescriptor.self,
            from: Data(try #require(split.environmentVariables[SessionRuntimeDescriptor.environmentKey]).utf8)
        )
        #expect(splitRuntime.isLocal)
        #expect(splitRuntime.localWorkingDirectory == "/tmp/local-origin")
        #expect(splitRuntime.initialWorkingDirectory == "/tmp/local-origin")

        var inheritedTab = Ghostty.SurfaceConfiguration()
        inheritedTab.context = GHOSTTY_SURFACE_CONTEXT_TAB
        inheritedTab.workingDirectory = "/srv/remote-only"
        let localTab = controller.newTabLaunch(inherited: inheritedTab, from: view, level: .workingDirectory)
        #expect(localTab.configuration?.workingDirectory == "/tmp/local-origin")
        #expect(localTab.configuration?.command == nil)

        let sshTab = controller.newTabLaunch(inherited: inheritedTab, from: view, level: .ssh)
        #expect(sshTab.configuration?.workingDirectory == "/tmp/local-origin")
        #expect(sshTab.configuration?.command?.contains("'+ssh'") == true)
        #expect(sshTab.configuration?.command?.contains("'--remote-working-directory=/srv/remote-only'") == true)
        #expect(sshTab.sshDescriptor?.localWorkingDirectory == "/tmp/local-origin")
        #expect(sshTab.sshDescriptor?.remoteWorkingDirectory == "/srv/remote-only")
    }

    @MainActor
    @Test func chainedNewSSHSessionsPreserveOriginalLocalDirectoryBeforeAndAfterConnect() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp/chained-local"
        let pane1 = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        let controller = TerminalController(app, withSurfaceTree: .init(view: pane1))
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }

        let inlineRemote = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "dev@cloud", options: ["-p", "2222"],
                                             localWorkingDirectory: "/tmp/chained-local"),
            revision: "remote-rev",
            policy: .init()
        )
        pane1.runtimeInlineSession = SessionRuntimeInlineSession(
            descriptor: inlineRemote,
            pane: UUID(),
            connectionID: "omg-ssh-inline-chain1",
            socket: URL(fileURLWithPath: "/tmp/unused.sock"),
            helperPID: ProcessInfo.processInfo.processIdentifier,
            bootID: try #require(SessionRuntimeInlineSession.currentBootID),
            workingDirectory: "/srv/hop1"
        )
        pane1.pwd = "/srv/hop1"

        // Hop 1 -> Hop 2 via split launch; adopt before +ssh has even started.
        let launch2 = try controller.newSplitLaunch(inherited: nil, from: pane1, level: .ssh)
        #expect(launch2.configuration?.workingDirectory == "/tmp/chained-local")
        var pane2Config = Ghostty.SurfaceConfiguration()
        pane2Config.command = "/bin/sleep 60"
        pane2Config.workingDirectory = launch2.configuration?.workingDirectory
        let pane2 = try #require(controller.newSplit(at: pane1, direction: .right, baseConfig: pane2Config))
        controller.adoptInheritedLaunch(launch2, for: pane2)

        // Immediately chain Hop 2 -> Hop 3 before pane2's +ssh emits OSC 3008!
        let launch3 = controller.newTabLaunch(inherited: nil, from: pane2, level: .ssh)
        #expect(launch3.configuration?.workingDirectory == "/tmp/chained-local")
        #expect(launch3.configuration?.command?.contains("'--remote-working-directory=/srv/hop1'") == true)
        #expect(launch3.configuration?.command?.contains("'dev@cloud'") == true)
        #expect(launch3.sshDescriptor?.localWorkingDirectory == "/tmp/chained-local")

        // Now pane2 connects to /srv/hop2 and then exits SSH cleanly (status=0).
        pane2.contextSignal = .init(
            action: .start,
            id: "omg-ssh-chain2",
            metadata: "type=remote;targethost=cloud;localcwd=/tmp/chained-local;cwd=/srv/hop2"
        )
        let launchAfterReady = try controller.newSplitLaunch(inherited: nil, from: pane2, level: .ssh)
        #expect(launchAfterReady.configuration?.workingDirectory == "/tmp/chained-local")
        #expect(launchAfterReady.configuration?.command?.contains("'--remote-working-directory=/srv/hop2'") == true)

        pane2.contextSignal = .init(
            action: .end,
            id: "omg-ssh-chain2",
            metadata: "status=0;cwd=/tmp/chained-local"
        )
        #expect(pane2.sshResumeDescriptor == nil)
        #expect(pane2.pendingSSHLaunchReplay == nil)
        #expect(!controller.sourceIsRemote(pane2))
        #expect(controller.paneSessionContext(for: pane2)?.workingDirectory == "/tmp/chained-local")
    }

    @MainActor
    @Test func disabledGhosttyDirectoryInheritanceAndMissingLocalDirectoryStillRunSSH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOMG = root.appendingPathComponent("fake-omg")
        try "#!/bin/sh\nprintf 'RAN:%s\\n' \"$*\"\n".write(to: fakeOMG, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeOMG.path)

        let deletedLocalDir = root.appendingPathComponent("deleted-local").path
        let missingReplay = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: false,
            terminfo: false,
            cache: false,
            args: ["-F", "./config", "cloud"],
            localWorkingDirectory: deletedLocalDir
        )
        let command = try #require(missingReplay.command(
            executablePath: fakeOMG.path,
            remoteWorkingDirectory: "/srv/app"
        ))
        let proc = Process()
        let out = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = root
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0)
        #expect(output.contains("RAN:+ssh"))

        // Disabled Ghostty split/tab directory inheritance omits both local and
        // remote cwd overrides while still connecting to the same SSH host.
        let cfgFile = root.appendingPathComponent("ghostty.conf")
        try "tab-inherit-working-directory = false\nsplit-inherit-working-directory = false\n"
            .write(to: cfgFile, atomically: true, encoding: .utf8)
        let disabledGhosttyConfig = Ghostty.Config(at: cfgFile.path, finalize: true)
        #expect(!disabledGhosttyConfig.tabInheritWorkingDirectory)
        #expect(!disabledGhosttyConfig.splitInheritWorkingDirectory)

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: base)
        view.runtimeDescriptor = .init(
            connection: try GitSSHConnection(destination: "cloud", localWorkingDirectory: "/tmp/local"),
            revision: "test",
            policy: .init(),
            initialWorkingDirectory: "/srv/app"
        )
        view.pwd = "/srv/app"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }

        var disabledSplit = Ghostty.SurfaceConfiguration()
        disabledSplit.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        disabledSplit.workingDirectory = nil
        let splitLaunch = try controller.newSplitLaunch(
            inherited: disabledSplit,
            from: view,
            level: .ssh,
            ghosttyConfig: disabledGhosttyConfig
        )
        #expect(splitLaunch.configuration?.workingDirectory == nil)
        #expect(splitLaunch.configuration?.environmentVariables[
            Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey
        ] == "1")
        #expect(splitLaunch.configuration?.command?.contains("'+ssh'") == true)
        #expect(splitLaunch.configuration?.command?.contains("--remote-working-directory") == false)

        let disabledTab = controller.newTabLaunch(
            inherited: disabledSplit,
            from: view,
            level: .workingDirectory,
            ghosttyConfig: disabledGhosttyConfig
        )
        #expect(disabledTab.configuration?.workingDirectory == nil)
        #expect(disabledTab.configuration?.environmentVariables[
            Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey
        ] == "1")

        let defaultTab = controller.newTabLaunch(inherited: disabledSplit, from: view, level: .defaultDirectory)
        #expect(defaultTab.configuration?.workingDirectory == nil)
        #expect(defaultTab.configuration?.environmentVariables[
            Ghostty.SurfaceConfiguration.suppressInheritCwdEnvironmentKey
        ] == "1")

        // OpenSSH -o interactive option classification parity.
        #expect(ForegroundSSHProcessDetector.interactiveDestination(
            ["-o", "StrictHostKeyChecking=accept-new", "-o", "User ubuntu", "-o", "RemoteCommand=none", "cloud"]
        ) == "cloud")
        #expect(ForegroundSSHProcessDetector.interactiveDestination(
            ["-L", "8080:127.0.0.1:80", "cloud"]
        ) == "cloud")
        for nonInteractive in [
            ["-o", "RemoteCommand=ls", "cloud"],
            ["-o", "RequestTTY=no", "cloud"],
            ["-o", "SessionType=none", "cloud"],
            ["-o", "BatchMode=yes", "cloud"],
            ["-o", "ForkAfterAuthentication=yes", "cloud"],
            ["-o", "ControlMaster=check", "cloud"],
            ["-N", "-L", "8080:127.0.0.1:80", "cloud"],
        ] {
            #expect(ForegroundSSHProcessDetector.interactiveDestination(nonInteractive) == nil)
        }
    }
}
