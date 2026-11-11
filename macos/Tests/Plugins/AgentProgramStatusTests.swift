import AppKit
import Combine
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct AgentProgramStatusTests {
    @Test func completionNotificationsRespectSettingsAndDeduplicateStatusSources() {
        func activity(_ state: TabActivityState, message: String? = nil) -> TabActivity {
            .init(source: "codex", state: state, label: "Codex", message: message, detail: nil, progress: nil, icon: nil)
        }
        #expect(AgentActivityNotification.kind(previous: activity(.working), next: activity(.done),
            completionEnabled: true, attentionEnabled: true) == .completed)
        #expect(AgentActivityNotification.kind(previous: nil, next: activity(.done),
            completionEnabled: true, attentionEnabled: true) == nil)
        #expect(AgentActivityNotification.kind(previous: activity(.done), next: activity(.done, message: "changed"),
            completionEnabled: true, attentionEnabled: true) == nil)
        #expect(AgentActivityNotification.kind(previous: activity(.working), next: activity(.done),
            completionEnabled: false, attentionEnabled: true) == nil)
        #expect(AgentActivityNotification.kind(previous: activity(.working), next: activity(.needsAttention),
            completionEnabled: false, attentionEnabled: true) == .attention)
        #expect(AgentActivityNotification.kind(previous: activity(.working), next: activity(.needsAttention),
            completionEnabled: true, attentionEnabled: false) == nil)
        #expect(AgentActivityNotification.kind(previous: activity(.done), next: activity(.idle),
            completionEnabled: true, attentionEnabled: true) == nil)
    }

    @Test func codexNativeReportsReplaceStateAndOptionalFields() throws {
        var status = AgentProgramStatus()
        #expect(status.consume("state=idle:app=codex") == true)
        #expect(status.activity?.source == "codex")
        #expect(status.consume("state=working:app=codex:progress=50:msg=aGVsbG8=") == true)
        #expect(status.activity?.state == .working)
        #expect(status.activity?.progress == 0.5)
        #expect(status.activity?.message == "hello")
        #expect(status.consume("state=done:app=codex") == true)
        #expect(status.activity?.state == .done)
        #expect(status.activity?.progress == nil && status.activity?.message == nil)
        #expect(status.acknowledge() == true)
        #expect(status.activity?.state == .idle)
        #expect(status.consume("state=done:app=codex") == true)
        #expect(status.activity?.state == .idle)
        #expect(status.consume("state=blocked:app=codex:kind=question") == true)
        #expect(status.activity?.attentionKind == .question)
        #expect(status.consume("state=clear") == true)
        #expect(status.activity == nil && status.records.isEmpty)
    }

    @Test func antigravityNativeReportsSupportStatesAttentionAndAliases() {
        var status = AgentProgramStatus()
        #expect(status.consume("state=working:app=antigravity") == true)
        #expect(status.activity?.source == "antigravity" && status.activity?.state == .working)
        #expect(status.consume("state=blocked:kind=permission:app=antigravity:msg=QWx3YXlzIGFsbG93") == true)
        #expect(status.activity?.state == .needsAttention && status.activity?.attentionKind == .permission)
        #expect(status.activity?.message == "Always allow")
        #expect(status.consume("state=blocked:kind=question:app=agy:msg=V2hpY2ggb3B0aW9uPw==") == true)
        #expect(status.activity?.source == "antigravity" && status.activity?.attentionKind == .question)
        #expect(status.consume("state=done:app=jetski:msg=Q29tcGxldGVk") == true)
        #expect(status.activity?.source == "antigravity" && status.activity?.state == .done)
        #expect(status.consume("state=error:app=antigravity-cli:msg=RmFpbGVk") == true)
        #expect(status.activity?.state == .error)
        #expect(status.consume("state=idle:app=antigravity") == true)
        #expect(status.activity?.state == .idle)
    }

    @Test func malformedReportsCannotClearAnotherNamespace() {
        var status = AgentProgramStatus()
        #expect(status.consume("state=working:app=claude:id=one/child") == true)
        #expect(status.consume("state=done:app=codex:id=two") == true)
        #expect(status.consume("state=clear:id=../") == false)
        #expect(status.records.count == 2)
        #expect(status.consume("state=future:app=codex") == false)
        #expect(status.consume("state=working:app=codex:msg=AA==") == false)
        #expect(status.activity?.state == .done)
        #expect(status.consume("state=clear:id=one") == true)
        #expect(status.records.map(\.id) == ["two"])
        for index in 0..<40 {
            #expect(status.consume("state=idle:app=codex:id=task\(index)") == true)
        }
        #expect(status.records.count == 32)
    }

    @Test func nativeStatusSurvivesLegacyHooksAndRemoteMetadata() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let connection = "omg-ssh-program-status-test"
        surface.contextSignal = .init(action: .start, id: connection,
            metadata: "type=remote;targethost=cloud;cwd=/tmp")
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=working:app=codex")
        #expect(controller.agentActivities[surface.id]?.state == .working)
        surface.contextSignal = .init(action: .start, id: "omg-agent-codex-42",
            metadata: "type=app;omg_agent=codex;omg_scope=remote;omg_state=idle")
        #expect(controller.agentActivities[surface.id]?.state == .working)
        surface.contextSignal = .init(action: .start, id: connection,
            metadata: "type=remote;targethost=cloud;cwd=/tmp")
        #expect(controller.agentActivities[surface.id]?.state == .working)
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=done:app=codex")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        let snapshot = try #require(controller.capturePaneSessionState(for: surface.id))
        #expect(snapshot.programStatus?.activity?.state == .done)
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
        surface.contextSignal = .init(action: .end, id: connection, metadata: "status=0;cwd=/tmp")
        #expect(controller.agentActivities[surface.id] == nil)
    }

    @Test func actualPTYDeliversCodex7501ThroughTheCoreToTheController() async throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let script = """
        printf '\\033]7501;state=idle:app=codex\\007'
        sleep 0.1
        printf '\\033]7501;state=working:app=codex\\033\\\\'
        sleep 0.1
        printf '\\033]7501;state=done:app=codex\\007'
        sleep 15
        """
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c " + Ghostty.Shell.quote(script)
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        var states: [TabActivityState] = []
        let observation = controller.$agentActivities.sink {
            if let state = $0[surface.id]?.state, states.last != state { states.append(state) }
        }
        defer { observation.cancel() }
        for _ in 0..<300 where states.last != .done {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(states == [.idle, .working, .done])
        #expect(controller.agentActivities[surface.id]?.icon == SupportedAgent.codex.icon)
    }

    @Test func antigravityIdleProgramStatusYieldsToHookStatesWhileNonIdleProgramStatusWins() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let pgid = Int(getpgrp())

        // Startup native OSC 7501 `state=idle:app=antigravity` establishes idle baseline.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=idle:app=antigravity")
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // Local OSC 3008 Hook `PreInvocation` (`working`) must NOT be masked by native `idle`!
        surface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-\(pgid)",
            metadata: "type=app;omg_agent=antigravity;omg_scope=local;omg_liveness=pgid;omg_state=working;omg_conversation=conv-1")
        #expect(controller.agentActivities[surface.id]?.state == .working)

        // Non-idle native OSC 7501 (`blocked` permission prompt) overrides Hook `working`.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=blocked:kind=permission:app=antigravity")
        #expect(controller.agentActivities[surface.id]?.state == .needsAttention)
        #expect(controller.agentActivities[surface.id]?.attentionKind == .permission)

        // When native OSC 7501 returns to `idle` and Hook emits `Stop` (`done`), `done` surfaces
        // and user acknowledgement clears it back to `idle`.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=idle:app=antigravity")
        surface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-\(pgid)",
            metadata: "type=app;omg_agent=antigravity;omg_scope=local;omg_liveness=pgid;omg_state=done;omg_conversation=conv-1")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
    }

    @Test func acknowledgedRemoteCompletionStaysIdleAfterSessionRestoreAndRuntimeSnapshotReplay() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)

        // Simulate an SSH session where both OSC 3008 Hook and native OSC 7501 completed (`done`),
        // then the user cleared/acknowledged the completion before closing OMG.
        surface.contextSignal = .init(action: .start, id: "omg-ssh-ack-restore",
            metadata: "type=remote;targethost=cloud;cwd=/srv")
        surface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-77",
            metadata: "type=app;omg_agent=antigravity;omg_scope=remote;omg_state=done;omg_conversation=conv-ssh")
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=done:app=antigravity:msg=RG9uZQ==")
        #expect(controller.agentActivities[surface.id]?.state == .done)

        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
        #expect(surface.acknowledgedAgentStatus != nil)

        // Archive workspace state, apply inline->direct runtime replacement on quit, and restore.
        var archived = TerminalWorkspaceSessionState(controller)
        let replacementID = UUID()
        let remoteRuntime = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "cloud", localWorkingDirectory: "/tmp"),
            revision: "remote",
            policy: .init()
        )
        archived.prepareRuntimeQuit([
            surface.id: .init(pane: replacementID, descriptor: remoteRuntime, create: false),
        ])
        let restoredTreeState = try archived.instantiate(restoreSessions: true)
        let restoredController = TerminalController(app, withSurfaceTree: restoredTreeState.surfaceTree)
        _ = restoredController.window
        defer { restoredController.window?.delegate = nil; restoredController.window?.close() }
        let restoredSurface = try #require(restoredController.surfaceTree.first)
        #expect(restoredSurface.id == replacementID)
        #expect(restoredSurface.acknowledgedAgentStatus == surface.acknowledgedAgentStatus)

        // Even if an empty outer runtime sync arrives before the remote snapshot,
        // the replayed `done` snapshot stays `.idle` instead of re-marking as `.done`.
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-77",
            metadata: "type=app;omg_agent=antigravity;omg_scope=remote;omg_state=done;omg_conversation=conv-ssh")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=done:app=antigravity:msg=RG9uZQ==")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        #expect(restoredController.agentActivities[restoredSurface.id]?.state == .idle)

        // Starting a new live turn clears the persisted acknowledgement, so a subsequent
        // detached completion while OMG is closed DOES surface as `.done` on reopen.
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-77",
            metadata: "type=app;omg_agent=antigravity;omg_scope=remote;omg_state=working;omg_conversation=conv-ssh")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=working:app=antigravity")
        #expect(restoredController.agentActivities[restoredSurface.id]?.state == .working)
        #expect(restoredSurface.acknowledgedAgentStatus == nil)

        let secondArchive = TerminalWorkspaceSessionState(restoredController)
        let secondRestoredState = try secondArchive.instantiate(restoreSessions: true)
        let secondController = TerminalController(app, withSurfaceTree: secondRestoredState.surfaceTree)
        _ = secondController.window
        defer { secondController.window?.delegate = nil; secondController.window?.close() }
        let secondSurface = try #require(secondController.surfaceTree.first)
        secondSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        secondSurface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-77",
            metadata: "type=app;omg_agent=antigravity;omg_scope=remote;omg_state=done;omg_conversation=conv-ssh")
        secondSurface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=done:app=antigravity:msg=RG9uZQ==")
        secondSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        #expect(secondController.agentActivities[secondSurface.id]?.state == .done)

        // Restore Tabs mode never carries acknowledged completion state into fresh tabs.
        let restoreTabsState = try archived.instantiate(restoreSessions: false)
        #expect(restoreTabsState.surfaceTree.first?.acknowledgedAgentStatus == nil)
    }
}
