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
        #expect(status.activity?.state == .working)
        #expect(status.consume("state=clear:id=one") == true)
        #expect(status.records.map(\.id) == ["two"])
        #expect(status.activity?.state == .done)
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
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
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

    @Test func antigravityTier1ProgramStatusHasStrictAuthorityOverSameAgentHooks() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let pgid = Int(getpgrp())

        // Startup native OSC 7501 `state=idle:app=antigravity` establishes Tier 1 ownership.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=idle:app=antigravity")
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // Same-agent Tier 2 Hook (`working`, `done`, `needsAttention`) is metadata-only
        // and MUST NOT resurface over Tier 1 `idle`.
        surface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-\(pgid)",
            metadata: "type=app;omg_agent=antigravity;omg_scope=local;omg_liveness=pgid;omg_state=working;omg_conversation=conv-1")
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // When Tier 1 reports `working`, same-agent Tier 2 `needsAttention` MUST NOT
        // override Tier 1 because `antigravity` natively supports OSC 7501 `blocked`.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=working:app=antigravity")
        #expect(controller.agentActivities[surface.id]?.state == .working)
        surface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-\(pgid)",
            metadata: "type=app;omg_agent=antigravity;omg_scope=local;omg_liveness=pgid;omg_state=needsAttention;omg_attention=question;omg_conversation=conv-1")
        #expect(controller.agentActivities[surface.id]?.state == .working)

        // Native OSC 7501 `blocked` drives attention directly.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=blocked:kind=permission:app=antigravity")
        #expect(controller.agentActivities[surface.id]?.state == .needsAttention)
        #expect(controller.agentActivities[surface.id]?.attentionKind == .permission)

        // Native OSC 7501 `done` is NOT cross-channel-wiped by a Tier 2 `working` hook,
        // and user acknowledgement clears it back to `idle` without stale Tier 2 resurfacing.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=done:app=antigravity")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        surface.contextSignal = .init(action: .start, id: "omg-agent-antigravity-\(pgid)",
            metadata: "type=app;omg_agent=antigravity;omg_scope=local;omg_liveness=pgid;omg_state=working;omg_event=prompt;omg_conversation=conv-1")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
    }

    @Test func acknowledgedRemoteCompletionStaysIdleAfterSessionRestoreAndRuntimeSnapshotReplay() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
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
        let restoredController = TerminalController(
            app,
            withSurfaceTree: restoredTreeState.surfaceTree,
            workspaceCoordinator: coordinator
        )
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
        let secondController = TerminalController(
            app,
            withSurfaceTree: secondRestoredState.surfaceTree,
            workspaceCoordinator: coordinator
        )
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

    @Test func preObserverSnapshotReplayAndPidHookPollingPreserveAcknowledgedIdleState() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)

        // PID-scoped hook agent (`pi`) completes under its own live node PID while the outer
        // wrapper process group has a distinct PGID.
        let pid = ProcessInfo.processInfo.processIdentifier
        let wrapperPGID: pid_t = pid == 42424 ? 42425 : 42424
        surface.contextSignal = .init(action: .start, id: "omg-agent-pi-\(pid)",
            metadata: "type=app;omg_agent=pi;omg_scope=local;omg_liveness=pid;omg_state=done")
        #expect(controller.agentActivities[surface.id]?.state == .done)

        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
        #expect(surface.acknowledgedAgentStatus != nil)

        // Foreground process polling with a different wrapper PGID or an incoming `.idle` signal
        // must NOT overwrite the PID-scoped signal or wipe `acknowledgedAgentStatus`.
        controller.applyDetectedAgent(.pi, processGroupID: Int(wrapperPGID), surfaceID: surface.id)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
        #expect(surface.acknowledgedAgentStatus != nil)

        surface.contextSignal = .init(action: .start, id: "omg-agent-pi-\(pid)",
            metadata: "type=app;omg_agent=pi;omg_scope=local;omg_liveness=pid;omg_state=idle")
        #expect(controller.agentActivities[surface.id]?.state == .idle)
        #expect(surface.acknowledgedAgentStatus != nil)

        // Archive workspace state and emit the replayed runtime `omg-agent-sync` batch onto
        // `restoredSurface` BEFORE `TerminalController` loads its window and subscribes.
        let archived = TerminalWorkspaceSessionState(controller)
        let restoredTreeState = try archived.instantiate(restoreSessions: true)
        let restoredSurface = try #require(restoredTreeState.surfaceTree.first)
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-pi-\(pid)",
            metadata: "type=app;omg_agent=pi;omg_scope=local;omg_liveness=pid;omg_state=done")
        restoredSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")

        let restoredController = TerminalController(
            app,
            withSurfaceTree: restoredTreeState.surfaceTree,
            workspaceCoordinator: coordinator
        )
        _ = restoredController.window
        defer { restoredController.window?.delegate = nil; restoredController.window?.close() }
        #expect(restoredController.agentActivities[restoredSurface.id]?.state == .idle)
        #expect(restoredSurface.acknowledgedAgentStatus != nil)
    }

    @Test func subRecordsInheritAppIdentityAndPrioritizeBlockedOverWorking() {
        var status = AgentProgramStatus()
        #expect(status.consume("state=working:app=codex:id=main") == true)
        // Sub-record without `app=` inherits `codex` from parent `main` and outranks `working`.
        #expect(status.consume("state=blocked:kind=permission:id=main/approval:msg=QWxsb3c=") == true)
        #expect(status.activity?.source == "codex")
        #expect(status.activity?.state == .needsAttention)
        #expect(status.activity?.attentionKind == .permission)
        #expect(status.activity?.message == "Allow")

        // Parent heartbeat `working` must not mask child `blocked`.
        #expect(status.consume("state=working:app=codex:id=main") == true)
        #expect(status.activity?.state == .needsAttention)

        // Clearing child `main/approval` restores parent `working`.
        #expect(status.consume("state=clear:id=main/approval") == true)
        #expect(status.activity?.state == .working)

        // Pane fallback agent resolves `app=` when a sub-record arrives before any explicit `app=`.
        var fallbackStatus = AgentProgramStatus()
        #expect(fallbackStatus.consume("state=blocked:kind=question:id=prompt", fallbackAgent: .claude) == true)
        #expect(fallbackStatus.activity?.source == "claude")
        #expect(fallbackStatus.activity?.state == .needsAttention)
        #expect(fallbackStatus.activity?.attentionKind == .question)

        // New foreground working turn supersedes unacknowledged prior-turn `done`.
        var multiTurn = AgentProgramStatus()
        #expect(multiTurn.consume("state=done:app=codex:id=turn1") == true)
        #expect(multiTurn.activity?.state == .done)
        #expect(multiTurn.consume("state=working:app=codex:id=turn2") == true)
        #expect(multiTurn.activity?.state == .working)
        #expect(multiTurn.consume("state=idle:app=codex:id=turn2") == true)
        #expect(multiTurn.activity?.state == .idle)
    }

    @Test func hookAttentionSurfacesOverGenericProgramWorkingAndPassiveEventsDoNotAcknowledge() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let pgid = Int(getpgrp())

        // For an agent without native OSC 7501 `blocked` support (`codex`), generic OSC 7501
        // `working` still allows an explicit Tier 2 Hook `needsAttention` for the same agent.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=working:app=codex")
        surface.contextSignal = .init(action: .start, id: "omg-agent-codex-\(pgid)",
            metadata: "type=app;omg_agent=codex;omg_scope=local;omg_liveness=pgid;omg_state=needsAttention;omg_attention=permission")
        #expect(controller.agentActivities[surface.id]?.state == .needsAttention)
        #expect(controller.agentActivities[surface.id]?.attentionKind == .permission)

        // Tier 1 `done` is NOT wiped by a Tier 2 Hook `working` signal; clear Tier 1 before
        // testing pure Hook completion acknowledgement timing below.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=done:app=codex")
        surface.contextSignal = .init(action: .start, id: "omg-agent-codex-\(pgid)",
            metadata: "type=app;omg_agent=codex;omg_scope=local;omg_liveness=pgid;omg_state=working;omg_event=prompt")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=clear")

        // Sub-150ms / pre-arrival passive events must NOT wipe a fresh `done` badge.
        let beforeDone = ProcessInfo.processInfo.systemUptime
        surface.contextSignal = .init(action: .start, id: "omg-agent-codex-\(pgid)",
            metadata: "type=app;omg_agent=codex;omg_scope=local;omg_liveness=pgid;omg_state=done")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface, eventTimestamp: beforeDone - 0.5)
        #expect(controller.agentActivities[surface.id]?.state == .done)
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface, eventTimestamp: beforeDone + 0.05)
        #expect(controller.agentActivities[surface.id]?.state == .done)

        // Intentional interaction after arrival cleanly acknowledges `done -> idle`.
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface, eventTimestamp: ProcessInfo.processInfo.systemUptime + 0.25)
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // Synthetic AppKit/Accessibility events with `eventTimestamp == 0` normalize to `systemUptime`
        // rather than being permanently blocked by `0 < arrived + 0.15`.
        surface.contextSignal = .init(action: .start, id: "omg-agent-codex-\(pgid)",
            metadata: "type=app;omg_agent=codex;omg_scope=local;omg_liveness=pgid;omg_state=working;omg_event=prompt")
        surface.contextSignal = .init(action: .start, id: "omg-agent-codex-\(pgid)",
            metadata: "type=app;omg_agent=codex;omg_scope=local;omg_liveness=pgid;omg_state=done")
        #expect(controller.agentActivities[surface.id]?.state == .done)
        Thread.sleep(forTimeInterval: 0.17)
        controller.acknowledgeTerminalAgentStateFromUserInput(on: surface, eventTimestamp: 0)
        #expect(controller.agentActivities[surface.id]?.state == .idle)
    }

    @Test func claudeCodeNativeStatusClearAndAgentPreservation() throws {
        #expect(AgentProgramStatus.resolveAgent("claude-code") == .claude)
        #expect(AgentProgramStatus.resolveAgent("Claude Code") == .claude)
        #expect(AgentProgramStatus.resolveAgent("CLAUDE-CODE") == .claude)

        // Empty status with no app and no fallback must not insert a zombie nil-agent record.
        var empty = AgentProgramStatus()
        #expect(empty.consume("state=idle") == false)
        #expect(empty.records.isEmpty)
        #expect(empty.consume("state=working:app=unknown-non-agent") == false)
        #expect(empty.records.isEmpty)

        // Resolved `app=claude-code` is preserved across subsequent app-less updates and
        // is never clobbered by an unrecognized `app=` token.
        var status = AgentProgramStatus()
        #expect(status.consume("state=idle:app=claude-code") == true)
        #expect(status.activity?.source == "claude")
        #expect(status.activity?.state == .idle)
        #expect(status.activity?.icon == SupportedAgent.claude.icon)

        #expect(status.consume("state=working") == true)
        #expect(status.activity?.source == "claude")
        #expect(status.activity?.state == .working)

        #expect(status.consume("state=working:app=unknown-non-agent") == false)
        #expect(status.activity?.source == "claude")
        #expect(status.activity?.state == .working)

        #expect(status.consume("state=clear") == true)
        #expect(status.records.isEmpty)
        #expect(status.activity == nil)

        // Controller integration: `state=clear` removes `agentProgramStatuses[surface.id]`
        // so Tier 3 title spinner detection is never permanently locked out.
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)

        // Establish a non-typed local Claude context (Tier 3 eligible).
        controller.applyDetectedAgent(.claude, processGroupID: Int(getpgrp()), surfaceID: surface.id)
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // Native OSC 7501 `app=claude-code` takes Tier 1 ownership, then `state=clear` releases it.
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=working:app=claude-code")
        #expect(controller.agentActivities[surface.id]?.source == "claude")
        #expect(controller.agentActivities[surface.id]?.state == .working)

        surface.contextSignal = .init(action: .start, id: "omg-program-status",
            metadata: "state=clear")
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // Tier 3 title spinner immediately works again because `agentProgramStatuses` was cleared.
        controller.updateAgentTitleActivity("◐ Claude Code", for: surface.id)
        #expect(controller.agentActivities[surface.id]?.state == .working)
    }

    @Test func claudeStopFailureErrorSurfacesOverNativeOSC7501WorkingAndIdle() throws {
        let enabled = OhMyGhosttySettings.shared.agentStatusHooksEnabled
        OhMyGhosttySettings.shared.agentStatusHooksEnabled = true
        defer { OhMyGhosttySettings.shared.agentStatusHooksEnabled = enabled }

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let coordinator = TerminalWorkspaceCoordinator(store: TerminalWorkspaceStore(fileURL: nil))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let pid = ProcessInfo.processInfo.processIdentifier

        // 1. OSC 7501 working -> StopFailure error -> OSC 7501 idle -> acknowledge -> idle.
        surface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=working:app=claude-code"
        )
        #expect(controller.agentActivities[surface.id]?.state == .working)

        surface.contextSignal = .init(
            action: .start,
            id: "omg-agent-claude-\(pid)",
            metadata: "type=app;omg_agent=claude;omg_scope=local;omg_liveness=pid;omg_state=error;omg_conversation=conv-err-1"
        )
        #expect(controller.agentActivities[surface.id]?.state == .error)

        surface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=idle:app=claude-code"
        )
        // Tier 1 `idle` must NOT swallow unacknowledged Tier 2 `StopFailure` `error`!
        #expect(controller.agentActivities[surface.id]?.state == .error)

        controller.acknowledgeTerminalAgentState(for: surface)
        #expect(controller.agentActivities[surface.id]?.state == .idle)

        // 2. OSC 7501 working -> StopFailure error -> OSC 7501 idle -> next working turn -> working.
        surface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=working:app=claude-code"
        )
        #expect(controller.agentActivities[surface.id]?.state == .working)

        surface.contextSignal = .init(
            action: .start,
            id: "omg-agent-claude-\(pid)",
            metadata: "type=app;omg_agent=claude;omg_scope=local;omg_liveness=pid;omg_state=error;omg_conversation=conv-err-1"
        )
        #expect(controller.agentActivities[surface.id]?.state == .error)

        surface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=idle:app=claude-code"
        )
        #expect(controller.agentActivities[surface.id]?.state == .error)

        // Next turn `OSC 7501 state=working` acknowledges prior reducer `error` and resumes `working`.
        surface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=working:app=claude-code"
        )
        #expect(controller.agentActivities[surface.id]?.state == .working)
    }
}
