import AppKit
import Foundation

extension TerminalController {
    static let programStatusResumeContextID = "omg-program-status"
    static let remoteDiscoveryResumeContextID = "omg-remote-discovery"
    private static let remoteDiscoveryDelays: [Duration] = [
        .milliseconds(450),
        .milliseconds(1_200),
        .seconds(3),
        .seconds(5),
        .seconds(8),
    ]

    func cancelRemoteConversationDiscovery(for surfaceID: UUID) {
        remoteConversationDiscoveryTokens.removeValue(forKey: surfaceID)
        remoteConversationDiscoveryTasks.removeValue(forKey: surfaceID)?.cancel()
    }

    func markPaneAwaitingRuntimeRecreate(for surfaceID: UUID) {
        guard let descriptor = agentResumeDescriptors[surfaceID],
              descriptor.conversationID != nil else { return }
        recreatingAgentSurfaceIDs.insert(surfaceID)
        agentResumeContextIDs.removeValue(forKey: surfaceID)
    }

    func claimedConversationIDs(
        for agent: SupportedAgent,
        scope: AgentExecutionScope,
        remoteTransferTarget: String? = nil,
        excludingSurfaceID: UUID
    ) -> Set<AgentConversationID> {
        var controllers = workspaceCoordinator.liveControllers
        for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalController })
        where !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }
        var claimed = Set<AgentConversationID>()
        for controller in controllers {
            for (paneID, descriptor) in controller.agentResumeDescriptors
            where paneID != excludingSurfaceID && descriptor.agent == agent && descriptor.scope == scope {
                guard let conversationID = descriptor.conversationID else { continue }
                if scope == .remote, let remoteTransferTarget {
                    let siblingTarget = descriptor.sshReplay?.transferTarget
                        ?? controller.remoteTransferTarget(for: paneID)
                    guard siblingTarget == remoteTransferTarget else { continue }
                }
                claimed.insert(conversationID)
            }
        }
        return claimed
    }

    private func remoteTransferTarget(for surfaceID: UUID) -> String? {
        guard let context = paneSessionContexts[surfaceID] else { return nil }
        switch context.state {
        case .local:
            return nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            return ssh.transferTarget
        }
    }

    private func resolvedRemoteSSHReplay(for surfaceID: UUID) -> SSHReplayDescriptor? {
        guard let context = paneSessionContexts[surfaceID] else { return nil }
        let surface = surfaceTree.first(where: { $0.id == surfaceID })
        let runtimeReplay = surface?.runtimeInlineSession?.replay
            ?? surface?.runtimeDescriptor?.connection.map { connection in
                SSHReplayDescriptor(
                    version: 1,
                    ssh: connection.executablePath,
                    forwardEnv: true,
                    terminfo: true,
                    cache: true,
                    args: connection.options + [connection.destination],
                    localWorkingDirectory: connection.localWorkingDirectory
                )
            }
        switch context.state {
        case .local:
            return nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            return ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID) ?? runtimeReplay
        }
    }

    func remoteDiscoveryConnection(
        for surface: Ghostty.SurfaceView,
        context: PaneSessionContext
    ) -> GitSSHConnection? {
        if let inlineConnection = surface.runtimeInlineSession?.descriptor.connection {
            return inlineConnection
        }
        if let runtime = surface.runtimeDescriptor, !runtime.isLocal, let connection = runtime.connection {
            return connection
        }
        if let connection = try? GitSSHConnection(session: context) {
            return connection
        }
        switch context.state {
        case .local:
            return nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            let fallbackLocalDir = surface.knownLocalWorkingDirectory ?? "/"
            return try? GitSSHConnection(session: ssh, localWorkingDirectory: fallbackLocalDir)
        }
    }

    func backfillRemoteResumeDescriptorMetadata(
        _ descriptor: inout AgentResumeDescriptor,
        for surfaceID: UUID
    ) {
        guard descriptor.scope == .remote,
              let context = paneSessionContexts[surfaceID] else { return }
        if descriptor.sshReplay == nil {
            descriptor.sshReplay = resolvedRemoteSSHReplay(for: surfaceID)
        }
        if descriptor.workingDirectory == nil,
           case .sshReady(_, let remoteCwd) = context.state,
           !remoteCwd.isEmpty {
            descriptor.workingDirectory = remoteCwd
        }
    }

    func synchronizeProgramStatusResumeDescriptor(
        status: AgentProgramStatus,
        for surface: Ghostty.SurfaceView
    ) {
        let surfaceID = surface.id
        guard let activity = status.activity,
              let agent = SupportedAgent(rawValue: activity.source) else {
            if agentReducers[surfaceID]?.currentActivity == nil,
               let contextID = agentResumeContextIDs[surfaceID],
               contextID == Self.programStatusResumeContextID ||
                contextID == Self.remoteDiscoveryResumeContextID {
                clearAgentResumeDescriptor(for: surfaceID)
            }
            return
        }

        let tapConversationID = status.activeSessionID.flatMap(AgentConversationID.init)
        guard status.isRemote || tapConversationID != nil else { return }
        let scope: AgentExecutionScope = status.isRemote ? .remote : .local

        if var existing = agentResumeDescriptors[surfaceID],
           existing.agent == agent,
           existing.scope == scope {
            var updated = existing
            if updated.conversationID == nil, let tapConversationID {
                updated.conversationID = tapConversationID
            }
            backfillRemoteResumeDescriptorMetadata(&updated, for: surfaceID)
            if updated != existing {
                agentResumeDescriptors[surfaceID] = updated
                surface.agentResumeDescriptor = updated
                enableRestorationForResumableSession()
                invalidateRestorableState()
                NotificationCenter.default.post(
                    name: .terminalPaneSessionContextsDidChange,
                    object: self
                )
            }
            if updated.conversationID != nil {
                recreatingAgentSurfaceIDs.remove(surfaceID)
                cancelRemoteConversationDiscovery(for: surfaceID)
            } else if scope == .remote {
                scheduleRemoteConversationDiscovery(for: surfaceID, preferredAgent: agent)
            }
            return
        }

        if typedAgentHookContextIDs[surfaceID] != nil,
           agentResumeDescriptors[surfaceID]?.conversationID != nil {
            return
        }

        var descriptor = AgentResumeDescriptor(
            agent: agent,
            conversationID: tapConversationID,
            scope: scope,
            workingDirectory: nil,
            sshReplay: nil
        )
        if scope == .local {
            descriptor.workingDirectory = paneSessionContexts[surfaceID]?.workingDirectory
                .flatMap { $0.isEmpty ? nil : $0 }
        } else {
            backfillRemoteResumeDescriptorMetadata(&descriptor, for: surfaceID)
        }
        guard descriptor.isValid else { return }
        agentResumeContextIDs[surfaceID] = Self.programStatusResumeContextID
        agentResumeDescriptors[surfaceID] = descriptor
        surface.agentResumeDescriptor = descriptor
        recreatingAgentSurfaceIDs.remove(surfaceID)
        enableRestorationForResumableSession()
        invalidateRestorableState()
        NotificationCenter.default.post(
            name: .terminalPaneSessionContextsDidChange,
            object: self
        )
        if scope == .remote, descriptor.conversationID == nil {
            scheduleRemoteConversationDiscovery(for: surfaceID, preferredAgent: agent)
        }
    }

    func reconcileRuntimeSnapshotResumeDescriptor(
        for surface: Ghostty.SurfaceView,
        status: AgentProgramStatus,
        reducer: AgentContextSignalReducer,
        previousDescriptor: AgentResumeDescriptor?,
        previousContextID: String?,
        wasRecreating: Bool
    ) {
        let surfaceID = surface.id
        if var current = agentResumeDescriptors[surfaceID], current.conversationID != nil {
            backfillRemoteResumeDescriptorMetadata(&current, for: surfaceID)
            if current != agentResumeDescriptors[surfaceID] {
                agentResumeDescriptors[surfaceID] = current
                surface.agentResumeDescriptor = current
            }
            recreatingAgentSurfaceIDs.remove(surfaceID)
            cancelRemoteConversationDiscovery(for: surfaceID)
            return
        }

        let activeAgent = status.activity.flatMap { SupportedAgent(rawValue: $0.source) }
            ?? reducer.currentActivity.flatMap { SupportedAgent(rawValue: $0.source) }
        if let activeAgent {
            let scope: AgentExecutionScope = (status.isRemote || reducer.hasRemoteActivity) ? .remote : .local
            if var preserved = previousDescriptor,
               preserved.agent == activeAgent,
               preserved.scope == scope,
               preserved.conversationID != nil {
                backfillRemoteResumeDescriptorMetadata(&preserved, for: surfaceID)
                agentResumeContextIDs[surfaceID] = previousContextID ?? Self.programStatusResumeContextID
                agentResumeDescriptors[surfaceID] = preserved
                surface.agentResumeDescriptor = preserved
                recreatingAgentSurfaceIDs.remove(surfaceID)
                enableRestorationForResumableSession()
                invalidateRestorableState()
                NotificationCenter.default.post(
                    name: .terminalPaneSessionContextsDidChange,
                    object: self
                )
                return
            }
            if status.activity != nil {
                synchronizeProgramStatusResumeDescriptor(status: status, for: surface)
            }
            return
        }

        // Preserve host-adopted or recreating resume descriptors across initial empty runtime hydration.
        guard var preserved = previousDescriptor,
              previousContextID == nil || wasRecreating else {
            return
        }
        backfillRemoteResumeDescriptorMetadata(&preserved, for: surfaceID)
        agentResumeContextIDs.removeValue(forKey: surfaceID)
        agentResumeDescriptors[surfaceID] = preserved
        surface.agentResumeDescriptor = preserved
        if wasRecreating {
            recreatingAgentSurfaceIDs.insert(surfaceID)
        }
        enableRestorationForResumableSession()
        invalidateRestorableState()
        NotificationCenter.default.post(
            name: .terminalPaneSessionContextsDidChange,
            object: self
        )
    }

    func isRemotePaneConnectedForDiscovery(
        surface: Ghostty.SurfaceView,
        context: PaneSessionContext
    ) -> Bool {
        guard context.isSSHSession else { return false }
        if let state = surface.runtimeConnectionState, state != .ready {
            return false
        }
        if let inlineState = surface.inlineRuntimeConnectionState, inlineState != .ready {
            return false
        }
        return true
    }

    func hasActiveTypedHookTurn(for surfaceID: UUID) -> Bool {
        guard typedAgentHookContextIDs[surfaceID] != nil,
              let state = agentReducers[surfaceID]?.currentActivity?.state else {
            return false
        }
        return state == .working || state == .needsAttention
    }

    func handlePaneSessionContextUpdateForAgentDiscovery(
        previous: PaneSessionContext?,
        current: PaneSessionContext,
        surfaceID: UUID
    ) {
        guard current.isSSHSession else { return }
        let surface = surfaceTree.first(where: { $0.id == surfaceID })

        // Promote an OSC 7501 / TAP program status that arrived before the 1s foreground
        // poll recognized `/usr/bin/ssh` (`status.isRemote == false` -> `true`).
        if var status = agentProgramStatuses[surfaceID], !status.isRemote {
            status.isRemote = true
            status.foregroundProcessGroup = nil
            agentProgramStatuses[surfaceID] = status
            if let surface {
                synchronizeProgramStatusResumeDescriptor(status: status, for: surface)
            }
        }

        if var descriptor = agentResumeDescriptors[surfaceID],
           descriptor.scope == .remote {
            let before = descriptor
            backfillRemoteResumeDescriptorMetadata(&descriptor, for: surfaceID)
            if descriptor != before {
                agentResumeDescriptors[surfaceID] = descriptor
                surface?.agentResumeDescriptor = descriptor
                invalidateRestorableState()
                NotificationCenter.default.post(
                    name: .terminalPaneSessionContextsDidChange,
                    object: self
                )
            }
        }

        guard let surface, isRemotePaneConnectedForDiscovery(surface: surface, context: current) else {
            return
        }

        if recreatingAgentSurfaceIDs.contains(surfaceID) {
            scheduleRecreatedRemoteAgentVerification(for: surfaceID)
            return
        }

        if case .sshReady = current.state {
            let becameReady: Bool = switch previous?.state {
            case .sshReady: false
            default: true
            }
            if agentResumeDescriptors[surfaceID]?.conversationID == nil {
                if let preferred = agentResumeDescriptors[surfaceID]?.agent {
                    scheduleRemoteConversationDiscovery(for: surfaceID, preferredAgent: preferred)
                } else if becameReady {
                    scheduleRemoteConversationDiscovery(
                        for: surfaceID,
                        preferredAgent: nil,
                        delays: [.milliseconds(700)]
                    )
                }
            }
            return
        }

        if agentResumeDescriptors[surfaceID]?.conversationID == nil,
           let preferred = agentResumeDescriptors[surfaceID]?.agent {
            scheduleRemoteConversationDiscovery(for: surfaceID, preferredAgent: preferred)
        }
    }

    func noteRemoteAgentDiscoveryAfterUserSubmit(on surface: Ghostty.SurfaceView) {
        let surfaceID = surface.id
        guard AgentStatusPlugin.isEnabled,
              !surface.blocksProgrammaticInput,
              let context = paneSessionContexts[surfaceID],
              isRemotePaneConnectedForDiscovery(surface: surface, context: context),
              !hasActiveTypedHookTurn(for: surfaceID) else {
            return
        }
        let hasActiveAgent = agentProgramStatuses[surfaceID]?.activity != nil
            || agentResumeDescriptors[surfaceID] != nil
            || agentActivities[surfaceID] != nil
        guard hasActiveAgent else { return }

        let preferred = agentResumeDescriptors[surfaceID]?.agent
            ?? agentProgramStatuses[surfaceID]?.activity.flatMap { SupportedAgent(rawValue: $0.source) }
            ?? agentActivities[surfaceID].flatMap { SupportedAgent(rawValue: $0.source) }
        let alreadyBound = agentResumeDescriptors[surfaceID]?.conversationID != nil
        scheduleRemoteConversationDiscovery(
            for: surfaceID,
            preferredAgent: preferred,
            delays: alreadyBound ? [.milliseconds(650), .seconds(2)] : Self.remoteDiscoveryDelays,
            restartExisting: true,
            allowAuthoritativeOverride: alreadyBound
        )
    }

    func scheduleRecreatedRemoteAgentVerification(for surfaceID: UUID) {
        guard recreatingAgentSurfaceIDs.remove(surfaceID) != nil else { return }
        guard let discoverer = remoteConversationDiscoverer,
              AgentStatusPlugin.isEnabled,
              let surface = surfaceTree.first(where: { $0.id == surfaceID }),
              let context = paneSessionContexts[surfaceID],
              isRemotePaneConnectedForDiscovery(surface: surface, context: context),
              let connection = remoteDiscoveryConnection(for: surface, context: context),
              let existing = agentResumeDescriptors[surfaceID],
              existing.scope == .remote else {
            return
        }
        cancelRemoteConversationDiscovery(for: surfaceID)
        let token = UUID()
        remoteConversationDiscoveryTokens[surfaceID] = token
        let request = makeRemoteDiscoveryRequest(
            for: surface,
            context: context,
            connection: connection,
            preferredAgent: nil,
            launchedAfter: Date().addingTimeInterval(-30)
        )
        remoteConversationDiscoveryTasks[surfaceID] = Task { @MainActor [weak self] in
            defer {
                if self?.remoteConversationDiscoveryTokens[surfaceID] == token {
                    self?.remoteConversationDiscoveryTokens.removeValue(forKey: surfaceID)
                    self?.remoteConversationDiscoveryTasks.removeValue(forKey: surfaceID)
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled,
                  let self,
                  self.remoteConversationDiscoveryTokens[surfaceID] == token else { return }
            let result = await discoverer(request)
            guard !Task.isCancelled,
                  self.remoteConversationDiscoveryTokens[surfaceID] == token,
                  self.paneSessionContexts[surfaceID]?.state == context.state else { return }
            // If a typed hook or program status already confirmed a running agent, keep it.
            if self.agentProgramStatuses[surfaceID]?.activity != nil ||
                self.agentReducers[surfaceID]?.currentActivity != nil {
                if let result, self.agentResumeDescriptors[surfaceID]?.conversationID == nil {
                    self.applyRemoteDiscoveryResult(result, for: surfaceID)
                }
                return
            }
            if let result, result.agent != nil {
                if result.agent != existing.agent {
                    self.clearAgentResumeDescriptor(for: surfaceID)
                }
                self.applyRemoteDiscoveryResult(result, for: surfaceID)
            } else if result != nil || (surface.runtimeDescriptor != nil || surface.runtimeInlineSession != nil) {
                // Probe succeeded on a recreated runtime pane and found only a plain shell (e.g. wiped store).
                if result == nil,
                   self.agentResumeContextIDs[surfaceID] == nil,
                   self.agentResumeDescriptors[surfaceID] == existing {
                    self.clearAgentResumeDescriptor(for: surfaceID)
                }
            }
        }
    }

    func scheduleRemoteConversationDiscovery(
        for surfaceID: UUID,
        preferredAgent: SupportedAgent?,
        delays: [Duration] = TerminalController.remoteDiscoveryDelays,
        restartExisting: Bool = false,
        allowAuthoritativeOverride: Bool = false
    ) {
        guard AgentStatusPlugin.isEnabled,
              let discoverer = remoteConversationDiscoverer,
              allowAuthoritativeOverride || agentResumeDescriptors[surfaceID]?.conversationID == nil,
              !hasActiveTypedHookTurn(for: surfaceID),
              let surface = surfaceTree.first(where: { $0.id == surfaceID }),
              let context = paneSessionContexts[surfaceID],
              isRemotePaneConnectedForDiscovery(surface: surface, context: context) else {
            return
        }
        if remoteConversationDiscoveryTasks[surfaceID] != nil {
            guard restartExisting else { return }
            cancelRemoteConversationDiscovery(for: surfaceID)
        }
        guard let connection = remoteDiscoveryConnection(for: surface, context: context) else { return }
        let launchedAt = Date()
        let initialConversationID = agentResumeDescriptors[surfaceID]?.conversationID
        let token = UUID()
        remoteConversationDiscoveryTokens[surfaceID] = token
        remoteConversationDiscoveryTasks[surfaceID] = Task { @MainActor [weak self] in
            defer {
                if self?.remoteConversationDiscoveryTokens[surfaceID] == token {
                    self?.remoteConversationDiscoveryTokens.removeValue(forKey: surfaceID)
                    self?.remoteConversationDiscoveryTasks.removeValue(forKey: surfaceID)
                }
            }
            var activeAgent = preferredAgent
            for delay in delays {
                if delay > .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      let self,
                      self.remoteConversationDiscoveryTokens[surfaceID] == token,
                      allowAuthoritativeOverride || self.agentResumeDescriptors[surfaceID]?.conversationID == nil,
                      !self.hasActiveTypedHookTurn(for: surfaceID),
                      let currentSurface = self.surfaceTree.first(where: { $0.id == surfaceID }),
                      let currentContext = self.paneSessionContexts[surfaceID],
                      self.isRemotePaneConnectedForDiscovery(surface: currentSurface, context: currentContext),
                      let currentConnection = self.remoteDiscoveryConnection(
                        for: currentSurface,
                        context: currentContext
                      ) else {
                    return
                }
                _ = connection
                let effectiveAgent = self.agentResumeDescriptors[surfaceID]?.agent ?? activeAgent
                let request = self.makeRemoteDiscoveryRequest(
                    for: currentSurface,
                    context: currentContext,
                    connection: currentConnection,
                    preferredAgent: effectiveAgent,
                    launchedAfter: launchedAt
                )
                let outcome = await discoverer(request)
                guard !Task.isCancelled,
                      self.remoteConversationDiscoveryTokens[surfaceID] == token,
                      allowAuthoritativeOverride || self.agentResumeDescriptors[surfaceID]?.conversationID == nil,
                      !self.hasActiveTypedHookTurn(for: surfaceID),
                      let afterSurface = self.surfaceTree.first(where: { $0.id == surfaceID }),
                      let afterContext = self.paneSessionContexts[surfaceID],
                      self.isRemotePaneConnectedForDiscovery(surface: afterSurface, context: afterContext) else {
                    return
                }
                guard let outcome, let detectedAgent = outcome.agent ?? effectiveAgent else {
                    // When probing speculatively without OSC 7501 and no foreground Agent is running,
                    // stop immediately instead of polling an ordinary shell prompt.
                    if effectiveAgent == nil { return }
                    continue
                }
                activeAgent = detectedAgent
                self.applyRemoteDiscoveryResult(
                    .init(
                        agent: detectedAgent,
                        conversationID: outcome.conversationID,
                        workingDirectory: outcome.workingDirectory,
                        isAuthoritative: outcome.isAuthoritative
                    ),
                    for: surfaceID,
                    allowAuthoritativeOverride: allowAuthoritativeOverride
                )
                let updatedID = self.agentResumeDescriptors[surfaceID]?.conversationID
                if !allowAuthoritativeOverride {
                    if updatedID != nil { return }
                } else if updatedID != nil, updatedID != initialConversationID {
                    return
                }
            }
        }
    }

    private func makeRemoteDiscoveryRequest(
        for surface: Ghostty.SurfaceView,
        context: PaneSessionContext,
        connection: GitSSHConnection,
        preferredAgent: SupportedAgent?,
        launchedAfter: Date
    ) -> AgentRemoteConversationDiscovery.Request {
        let runtimeDescriptor = (surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor)
            .flatMap { $0.isLocal ? nil : $0 }
        let runtimePaneID: UUID? = if let inline = surface.runtimeInlineSession {
            inline.pane
        } else if runtimeDescriptor != nil {
            surface.id
        } else {
            nil
        }
        let remoteTTY: String? = switch context.state {
        case .local: nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _): ssh.remoteTTY
        }
        let excluded: Set<AgentConversationID> = if let preferredAgent {
            claimedConversationIDs(
                for: preferredAgent,
                scope: .remote,
                remoteTransferTarget: connection.destination,
                excludingSurfaceID: surface.id
            )
        } else {
            []
        }
        return AgentRemoteConversationDiscovery.Request(
            agent: preferredAgent,
            connection: connection,
            runtimeRevision: runtimeDescriptor?.revision,
            runtimePaneID: runtimePaneID,
            remoteTTY: remoteTTY,
            remoteWorkingDirectory: context.remoteWorkingDirectory,
            launchedAfter: launchedAfter,
            excludedConversationIDs: excluded
        )
    }

    func applyRemoteDiscoveryResult(
        _ result: AgentRemoteConversationDiscovery.Result,
        for surfaceID: UUID,
        allowAuthoritativeOverride: Bool = false
    ) {
        guard AgentStatusPlugin.isEnabled,
              let surface = surfaceTree.first(where: { $0.id == surfaceID }),
              var context = paneSessionContexts[surfaceID],
              context.isSSHSession else {
            return
        }
        if let discoveredCwd = result.workingDirectory,
           isRemotePaneConnectedForDiscovery(surface: surface, context: context) {
            if surface.runtimeDescriptor?.isLocal == false,
               (surface.pwd ?? "").isEmpty {
                surface.pwd = discoveredCwd
                context = paneSessionContexts[surfaceID] ?? context
            }
            if surface.runtimeInlineSession != nil,
               (surface.runtimeInlineSession?.workingDirectory ?? "").isEmpty {
                surface.runtimeInlineSession?.workingDirectory = discoveredCwd
            }
            let beforeState = context.state
            context.applyDiscoveredRemoteWorkingDirectory(discoveredCwd)
            if context.state != beforeState {
                updatePaneSessionContext(context, for: surfaceID)
                context = paneSessionContexts[surfaceID] ?? context
            }
        }

        guard let agent = result.agent ?? agentResumeDescriptors[surfaceID]?.agent else { return }
        let existing = agentResumeDescriptors[surfaceID]
        if let existingID = existing?.conversationID {
            guard allowAuthoritativeOverride,
                  result.isAuthoritative,
                  !hasActiveTypedHookTurn(for: surfaceID),
                  let incomingID = result.conversationID,
                  incomingID != existingID else {
                return
            }
        }

        if let candidateID = result.conversationID {
            let target = remoteTransferTarget(for: surfaceID)
            let claimed = claimedConversationIDs(
                for: agent,
                scope: .remote,
                remoteTransferTarget: target,
                excludingSurfaceID: surfaceID
            )
            if claimed.contains(candidateID) {
                return
            }
        }

        var descriptor = existing ?? AgentResumeDescriptor(
            agent: agent,
            conversationID: nil,
            scope: .remote,
            workingDirectory: nil,
            sshReplay: nil
        )
        guard descriptor.scope == .remote, descriptor.agent == agent else { return }
        if let conversationID = result.conversationID {
            if descriptor.conversationID != nil, descriptor.conversationID != conversationID {
                descriptor.restoredTitle = nil
            }
            descriptor.conversationID = conversationID
        }
        if let discoveredCwd = result.workingDirectory {
            descriptor.workingDirectory = discoveredCwd
        }
        backfillRemoteResumeDescriptorMetadata(&descriptor, for: surfaceID)
        guard descriptor.isValid else { return }

        if agentResumeContextIDs[surfaceID] == nil || descriptor.conversationID != existing?.conversationID {
            agentResumeContextIDs[surfaceID] = Self.remoteDiscoveryResumeContextID
        }
        let changed = agentResumeDescriptors[surfaceID] != descriptor
        if changed {
            agentResumeDescriptors[surfaceID] = descriptor
            surface.agentResumeDescriptor = descriptor
            enableRestorationForResumableSession()
            invalidateRestorableState()
            NotificationCenter.default.post(
                name: .terminalPaneSessionContextsDidChange,
                object: self
            )
        }
    }
}
