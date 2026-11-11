import Foundation

extension TerminalController {
    private struct RemoteDraftTargetResolution {
        let target: QuickInputRemoteDraftBridge.Target
        let foregroundAgent: SupportedAgent?
    }

    private func resolveRemoteDraftTarget(
        connection: GitSSHConnection,
        ssh: PaneSessionContext.SSH,
        runtime: SessionRuntimeDescriptor?,
        pane: UUID,
        probeForegroundAgent: Bool
    ) async throws -> RemoteDraftTargetResolution {
        if let runtime {
            let target = try await QuickInputRemoteDraftBridge.runtimeTarget(
                connection: connection, revision: runtime.revision, pane: pane
            )
            let agent = probeForegroundAgent
                ? target.commands.flatMap { LocalAgentProcessDetector.detect(in: $0) }
                : nil
            return .init(target: target, foregroundAgent: agent)
        }
        guard ssh.connectionID.hasPrefix("omg-ssh-"),
              ssh.localProcessGroupID == nil,
              let tty = ssh.remoteTTY else {
            throw CocoaError(.featureUnsupported)
        }
        let target = QuickInputRemoteDraftBridge.Target(session: ssh.connectionID, tty: tty)
        let agent = probeForegroundAgent
            ? try await QuickInputRemoteDraftBridge.foregroundAgent(
                connection: connection, session: target.session, tty: target.tty
            )
            : nil
        return .init(target: target, foregroundAgent: agent)
    }

    /// The external editor replaces the CLI's whole input and acknowledges the
    /// exact bytes. Never infer that an old imported prefix is still present.
    func replaceQuickInputAgentDraft(_ text: String, for surface: Ghostty.SurfaceView, shortcut: String) async throws {
        guard let keys = QuickInputDraftBridge.keys(shortcut), let terminal = surface.surfaceModel else {
            throw CocoaError(.featureUnsupported)
        }
        let context = paneSessionContext(for: surface)
        let runtimeIdentity = (surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor)?.identity
        let foregroundPID = terminal.foregroundPID
        func checkTarget() throws {
            guard !Task.isCancelled, !SecureInput.shared.enabled, !surface.readonly, !surface.processExited,
                  surfaceTree.contains(where: { $0 === surface }),
                  paneSessionContext(for: surface)?.state == context?.state,
                  (surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor)?.identity == runtimeIdentity,
                  terminal.foregroundPID == foregroundPID else {
                throw CancellationError()
            }
        }
        if let context, context.isSSHSession {
            guard case .sshReady(let ssh, _) = context.state,
                  let connection = try? GitSSHConnection(session: context) else {
                throw CocoaError(.fileReadUnknown)
            }
            let descriptor = surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor
            let runtime = descriptor.flatMap { $0.isLocal ? nil : $0 }
            let target = try await resolveRemoteDraftTarget(
                connection: connection,
                ssh: ssh,
                runtime: runtime,
                pane: surface.runtimeInlineSession?.pane ?? surface.id,
                probeForegroundAgent: false
            ).target
            let request = UUID().uuidString
            var snapshot: QuickInputTerminalSnapshot?
            defer { snapshot?.removeAfterRedraw() }
            do {
                try await QuickInputRemoteDraftBridge.begin(
                    connection: connection, session: target.session, request: request, tty: target.tty,
                    root: target.root, generation: target.generation, replacement: text
                )
                try checkTarget()
                snapshot = QuickInputTerminalSnapshot(surface: surface, maximumDuration: .seconds(2))
                QuickInputDraftBridge.sendKeys(keys, to: terminal)
                let received = try await QuickInputRemoteDraftBridge.receive(
                    connection: connection, session: target.session, request: request, root: target.root
                )
                guard received == text else { throw CocoaError(.fileReadCorruptFile) }
                try checkTarget()
            } catch {
                await QuickInputRemoteDraftBridge.finish(
                    connection: connection, session: target.session, request: request, root: target.root
                )
                throw error
            }
            await QuickInputRemoteDraftBridge.finish(
                connection: connection, session: target.session, request: request, root: target.root
            )
        } else {
            let request = try QuickInputDraftBridge.shared.begin(surfaceID: surface.id, replacement: text)
            let snapshot = QuickInputTerminalSnapshot(surface: surface, maximumDuration: .milliseconds(600))
            defer {
                QuickInputDraftBridge.shared.finish(request)
                snapshot.removeAfterRedraw()
            }
            try checkTarget()
            QuickInputDraftBridge.sendKeys(keys, to: terminal)
            guard let received = try await QuickInputDraftBridge.shared.awaitResponse(
                request, validateTarget: checkTarget
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            guard received == text else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    func importRemoteQuickInputDraft(
        for surface: Ghostty.SurfaceView, context: PaneSessionContext, setting: String
    ) {
        guard !setting.isEmpty, !SecureInput.shared.enabled,
              case .sshReady(let ssh, _) = context.state,
              let connection = try? GitSSHConnection(session: context) else { return }
        let descriptor = surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor
        let runtime = descriptor.flatMap { $0.isLocal ? nil : $0 }
        let inlinePane = surface.runtimeInlineSession?.pane
        let runtimePane = inlinePane ?? surface.id
        let runtimeIdentity = descriptor?.identity
        let agent = agentActivity(for: surface).flatMap { SupportedAgent(rawValue: $0.source) }
            ?? agentResumeDescriptor(for: surface)?.agent
        let hasAgentActivity = agentActivity(for: surface) != nil
        let request = UUID().uuidString
        quickInputDraftImportTask = Task { @MainActor [weak self, weak surface] in
            var snapshot: QuickInputTerminalSnapshot?
            var target: QuickInputRemoteDraftBridge.Target?
            defer {
                snapshot?.removeAfterRedraw()
                self?.quickInputDraftImportTask = nil
            }
            @MainActor func isStillTargetingSurface() -> Bool {
                guard !Task.isCancelled, let self, let surface,
                      self.quickInputModel.isPresented,
                      self.quickInputModel.targetSurfaceID == surface.id,
                      self.paneSessionContext(for: surface)?.state == context.state,
                      surface.runtimeInlineSession?.pane == inlinePane,
                      (surface.runtimeInlineSession?.descriptor ?? surface.runtimeDescriptor)?.identity == runtimeIdentity,
                      !SecureInput.shared.enabled else { return false }
                return true
            }
            do {
                guard let self else { return }
                let resolution: RemoteDraftTargetResolution
                do {
                    resolution = try await self.resolveRemoteDraftTarget(
                        connection: connection,
                        ssh: ssh,
                        runtime: runtime,
                        pane: runtimePane,
                        probeForegroundAgent: true
                    )
                } catch CocoaError.featureUnsupported {
                    return
                }
                let resolved = resolution.target
                let foregroundAgent = resolution.foregroundAgent
                target = resolved
                guard !Task.isCancelled,
                      let keys = QuickInputDraftBridge.importKeys(
                        setting: setting, agent: foregroundAgent ?? agent, hasAgentActivity: hasAgentActivity
                      ) else { return }
                try await QuickInputRemoteDraftBridge.begin(
                    connection: connection, session: resolved.session, request: request, tty: resolved.tty,
                    root: resolved.root, generation: resolved.generation
                )
                guard isStillTargetingSurface(), let surface, let terminal = surface.surfaceModel else {
                    await QuickInputRemoteDraftBridge.finish(
                        connection: connection, session: resolved.session, request: request, root: resolved.root
                    )
                    return
                }
                snapshot = QuickInputTerminalSnapshot(surface: surface, maximumDuration: .seconds(2))
                let importForegroundPID = terminal.foregroundPID
                QuickInputDraftBridge.sendKeys(keys, to: terminal)
                let text = try await QuickInputRemoteDraftBridge.receive(
                    connection: connection, session: resolved.session, request: request, root: resolved.root
                )
                guard isStillTargetingSurface(), terminal.foregroundPID == importForegroundPID else {
                    await QuickInputRemoteDraftBridge.finish(
                        connection: connection, session: resolved.session, request: request, root: resolved.root
                    )
                    return
                }
                self.quickInputModel.importAgentDraft(
                    text,
                    shortcut: QuickInputDraftBridge.shortcut(setting: setting, agent: foregroundAgent ?? agent),
                    processID: importForegroundPID
                )
                let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                self.quickInputModel.setStatusMessage(strings.quickInputDraftImported)
            } catch {
                if !Task.isCancelled, let self, let surface, self.quickInputModel.isPresented,
                   self.quickInputModel.targetSurfaceID == surface.id {
                    let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                    let legacy = (error as NSError).domain == "OMGRemoteDraft" && (error as NSError).code == 1
                    self.quickInputModel.setStatusMessage(legacy
                        ? strings.t("This SSH session has no draft bridge. Ensure remote Python 3 is available, then resume the agent in a new SSH session.",
                                    "此 SSH 会话没有草稿桥接。请确认远端有 Python 3，再在新建 SSH 会话中恢复 Agent。")
                        : strings.t("Remote draft unavailable. Check the connection and the agent's external editor.",
                                    "远程草稿暂不可用，请检查连接和 Agent 的外部编辑器配置。"))
                }
            }
            if let target {
                await QuickInputRemoteDraftBridge.finish(
                    connection: connection, session: target.session, request: request, root: target.root
                )
            }
        }
    }
}
