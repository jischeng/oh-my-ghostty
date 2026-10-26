import Foundation

extension TerminalController {
    func importRemoteQuickInputDraft(
        for surface: Ghostty.SurfaceView, context: PaneSessionContext, setting: String
    ) {
        guard !setting.isEmpty, !SecureInput.shared.enabled,
              case .sshReady(let ssh, _) = context.state,
              ssh.connectionID.hasPrefix("omg-ssh-"), ssh.localProcessGroupID == nil,
              let tty = ssh.remoteTTY,
              let connection = try? GitSSHConnection(session: context) else { return }
        let agent = agentActivity(for: surface).flatMap { SupportedAgent(rawValue: $0.source) }
            ?? agentResumeDescriptor(for: surface)?.agent
        guard setting != "auto" || agent != nil || agentActivity(for: surface) != nil,
              let keys = QuickInputDraftBridge.keys(QuickInputDraftBridge.shortcut(setting: setting, agent: agent)) else {
            return
        }
        let request = UUID().uuidString
        quickInputDraftImportTask = Task { @MainActor [weak self, weak surface] in
            defer { self?.quickInputDraftImportTask = nil }
            do {
                try await QuickInputRemoteDraftBridge.begin(
                    connection: connection, session: ssh.connectionID, request: request, tty: tty
                )
                guard !Task.isCancelled, let self, let surface,
                      self.quickInputModel.isPresented,
                      self.quickInputModel.targetSurfaceID == surface.id,
                      self.paneSessionContext(for: surface)?.state == context.state,
                      !SecureInput.shared.enabled, let terminal = surface.surfaceModel else {
                    await QuickInputRemoteDraftBridge.finish(connection: connection, session: ssh.connectionID, request: request)
                    return
                }
                for key in keys {
                    terminal.sendKeyEvent(key)
                    terminal.sendKeyEvent(.init(key: key.key, action: .release, mods: key.mods,
                                                unshiftedCodepoint: key.unshiftedCodepoint))
                }
                let text = try await QuickInputRemoteDraftBridge.receive(
                    connection: connection, session: ssh.connectionID, request: request
                )
                guard !Task.isCancelled, self.quickInputModel.isPresented,
                      self.quickInputModel.targetSurfaceID == surface.id,
                      self.paneSessionContext(for: surface)?.state == context.state,
                      !SecureInput.shared.enabled else {
                    await QuickInputRemoteDraftBridge.finish(connection: connection, session: ssh.connectionID, request: request)
                    return
                }
                self.quickInputModel.importAgentDraft(text)
                self.quickInputModel.setStatusMessage("Draft copied. Original agent input is still present.")
            } catch {
                if !Task.isCancelled, let self, let surface, self.quickInputModel.isPresented,
                   self.quickInputModel.targetSurfaceID == surface.id {
                    self.quickInputModel.setStatusMessage(
                        "Remote draft unavailable. Reconnect with OMG SSH and restart or resume the agent to enable it."
                    )
                }
            }
            await QuickInputRemoteDraftBridge.finish(connection: connection, session: ssh.connectionID, request: request)
        }
    }
}
