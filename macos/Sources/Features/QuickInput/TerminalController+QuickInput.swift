import AppKit
import Foundation

extension TerminalController {
    func toggleQuickInput() {
        if quickInputModel.isPresented {
            dismissQuickInput()
            return
        }
        guard let surface = focusedSurface ?? surfaceTree.first else { return }
        // Presentation must never depend on the CLI's editor handshake. Only
        // an actual external-editor request may retain its TUI's last frame.
        presentQuickInput(for: surface, requestFocus: true)
        quickInputPendingDraftSurfaceID = surface.id
    }

    func quickInputComposerDidBecomeReady(for surfaceID: UUID?) {
        guard let surfaceID, quickInputPendingDraftSurfaceID == surfaceID,
              quickInputModel.isPresented, quickInputModel.targetSurfaceID == surfaceID,
              let surface = surfaceTree.first(where: { $0.id == surfaceID }) else { return }
        quickInputPendingDraftSurfaceID = nil
        guard quickInputDraftImportTask == nil, quickInputSubmissionTasks[surfaceID] == nil else { return }
        let currentContext = paneSessionContext(for: surface)
        let sshConnecting: Bool
        if case .sshConnecting? = currentContext?.state {
            sshConnecting = true
        } else {
            sshConnecting = false
        }
        guard QuickInputDraftBridge.canImportDraft(
            isReadOnly: surface.readonly,
            isRuntime: surface.runtimeDescriptor != nil,
            runtimeState: surface.runtimeConnectionState,
            isSSHConnecting: sshConnecting,
            hasPendingSSHRecovery: pendingSSHRecovery(for: surface) != nil
        ) else { return }
        let setting = OhMyGhosttySettings.shared.quickInputImportShortcut
        if let context = currentContext, context.isSSHSession {
            importRemoteQuickInputDraft(for: surface, context: context, setting: setting)
            return
        }
        let foregroundCommands = surface.surfaceModel?.foregroundPID.flatMap {
            Self.processGroupCommandLines($0)
        }
        // Also cover plain SSH before the asynchronous session poll catches up.
        if let foregroundCommands,
           ForegroundSSHProcessDetector.observe(in: foregroundCommands) != .none { return }
        // Draft import must work independently of Agent Status hooks and
        // conversation discovery, including a freshly started agent.
        let foregroundAgent = foregroundCommands.flatMap {
            LocalAgentProcessDetector.detect(in: $0)
        }
        let agent = foregroundAgent ?? detectedAgentInstances[surface.id]?.agent
            ?? agentActivities[surface.id].flatMap { SupportedAgent(rawValue: $0.source) }
            ?? agentResumeDescriptor(for: surface)?.agent
        guard !SecureInput.shared.enabled,
              let keys = QuickInputDraftBridge.importKeys(
                setting: setting, agent: agent, hasAgentActivity: agentActivities[surface.id] != nil
              ),
              let terminal = surface.surfaceModel,
              let request = try? QuickInputDraftBridge.shared.begin(surfaceID: surface.id) else {
            return
        }
        let importForegroundPID = terminal.foregroundPID
        let snapshot = QuickInputTerminalSnapshot(surface: surface, maximumDuration: .milliseconds(600))
        quickInputDraftImportTask = Task { @MainActor [weak self, weak surface] in
            defer {
                QuickInputDraftBridge.shared.finish(request)
                snapshot.removeAfterRedraw()
                self?.quickInputDraftImportTask = nil
            }
            do {
                let received = try await QuickInputDraftBridge.shared.awaitResponse(request) {
                    guard !Task.isCancelled,
                          let self, let surface,
                          self.quickInputModel.isPresented,
                          self.quickInputModel.targetSurfaceID == surface.id,
                          self.surfaceTree.first(where: { $0.id == surface.id }) != nil else {
                        throw CancellationError()
                    }
                }
                if let text = received {
                    guard let self, !SecureInput.shared.enabled,
                          terminal.foregroundPID == importForegroundPID else { return }
                    self.quickInputModel.importAgentDraft(
                        text,
                        shortcut: QuickInputDraftBridge.shortcut(setting: setting, agent: agent),
                        processID: importForegroundPID
                    )
                    let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                    self.quickInputModel.setStatusMessage(strings.quickInputDraftImported)
                    return
                }
            } catch is CancellationError {
                return
            } catch {}

            guard let self, let surface, self.quickInputModel.isPresented,
                  self.quickInputModel.targetSurfaceID == surface.id else { return }
            let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
            self.quickInputModel.setStatusMessage(strings.t(
                "No draft received. Check the external-editor shortcut and open a new terminal after configuring it.",
                "未收到草稿，请检查外部编辑器快捷键，并在配置后重新打开终端。"
            ))
        }
        QuickInputDraftBridge.sendKeys(keys, to: terminal)
    }

    func presentQuickInput(
        for surface: Ghostty.SurfaceView,
        requestFocus: Bool
    ) {
        quickInputLastTerminalSurfaceID = surface.id
        quickInputModel.present(for: surface.id, requestFocus: requestFocus)
        // The composer transfers first responder once its native view is ready.
        // Manually resigning here creates an intermediate unfocused pane frame.
    }

    func sendQuickInputDraft() {
        guard let surfaceID = quickInputModel.targetSurfaceID else { return }
        if quickInputModel.isEditingQueuedItem {
            guard quickInputModel.confirmQueuedItemEdit(moveToEnd: false) else {
                return
            }
            if !quickInputModel.isPinned { restoreTerminalFocus(surfaceID: surfaceID) }
            dispatchNextQuickInput(for: surfaceID)
            return
        }
        let text = quickInputModel.draft
        submitQuickInputText(text, to: surfaceID, restoreFocus: !quickInputModel.isPinned) { [weak self] in
            self?.quickInputModel.completeSubmittedDraft(text, for: surfaceID)
        }
    }

    func queueQuickInputDraft() {
        guard let surfaceID = quickInputModel.targetSurfaceID else { return }
        if quickInputModel.isEditingQueuedItem {
            guard quickInputModel.confirmQueuedItemEdit(moveToEnd: true) else {
                return
            }
            if !quickInputModel.isPinned { restoreTerminalFocus(surfaceID: surfaceID) }
            dispatchNextQuickInput(for: surfaceID)
            return
        }
        guard quickInputModel.enqueueDraft() != nil else { return }
        quickInputModel.completeSubmission(clearDraft: false)
        if agentActivities[surfaceID]?.state == .done {
            dispatchNextQuickInput(for: surfaceID)
        }
        if !quickInputModel.isPinned { restoreTerminalFocus(surfaceID: surfaceID) }
    }

    func toggleQuickInputHistory() {
        guard !quickInputModel.isEditingQueuedItem else { return }
        if !quickInputModel.isPresented {
            guard let surface = focusedSurface ?? surfaceTree.first else { return }
            presentQuickInput(for: surface, requestFocus: false)
        }
        quickInputModel.toggleHistory(scope: OhMyGhosttySettings.shared.quickInputHistoryScope)
    }

    func dismissQuickInput() {
        quickInputPendingDraftSurfaceID = nil
        quickInputDraftImportTask?.cancel()
        let surfaceID = quickInputModel.targetSurfaceID
        quickInputModel.dismiss()
        restoreTerminalFocus(surfaceID: surfaceID)
    }

    func sendQueuedQuickInput(_ itemID: UUID, from surfaceID: UUID) {
        guard quickInputModel.targetSurfaceID != surfaceID || quickInputModel.editingQueueItemID != itemID else { return }
        guard let item = quickInputModel.state(for: surfaceID)?.queue.first(where: { $0.id == itemID }) else { return }
        submitQuickInputText(item.text, to: surfaceID, restoreFocus: false, historyID: item.id) { [weak self] in
            guard self?.quickInputModel.state(for: surfaceID)?.queue.contains(item) == true else { return }
            self?.quickInputModel.removeQueuedItem(itemID, for: surfaceID)
        }
    }

    func editQueuedQuickInput(_ itemID: UUID, from surfaceID: UUID) {
        guard quickInputSubmissionTasks[surfaceID] == nil else { return }
        quickInputModel.editQueuedItem(itemID, for: surfaceID)
    }

    func removeQueuedQuickInput(_ itemID: UUID, from surfaceID: UUID) {
        guard quickInputSubmissionTasks[surfaceID] == nil else { return }
        quickInputModel.removeQueuedItem(itemID, for: surfaceID)
    }

    func pruneQuickInputState(retaining activeIDs: Set<UUID>) {
        for surfaceID in Array(quickInputModel.paneStates.keys) where !activeIDs.contains(surfaceID) {
            quickInputModel.removeState(for: surfaceID)
        }
        for (surfaceID, task) in quickInputAutomaticTasks where !activeIDs.contains(surfaceID) {
            task.cancel()
        }
        quickInputAutomaticTasks = quickInputAutomaticTasks.filter { activeIDs.contains($0.key) }
    }

    /// A monitor's nil return consumes the key. Do not coalesce that nil with
    /// the original NSEvent: it would also deliver the shortcut to the PTY.
    static func routeMonitoredKeyEvent(
        _ event: NSEvent, handler: ((NSEvent) -> NSEvent?)?
    ) -> NSEvent? {
        guard let handler else { return event }
        return handler(event)
    }

    func handleQuickInputKeyEvent(_ event: NSEvent) -> NSEvent? {
        let eventController = event.window?.windowController as? TerminalController
        guard eventController === self ||
                (event.window == nil && NSApp.keyWindow?.windowController === self) else {
            return event
        }

        if workspaceCoordinator.handle(event, in: self) { return nil }
        let settings = OhMyGhosttySettings.shared
        if OMGKeyboardShortcut.quickInputHistory.matches(event) {
            toggleQuickInputHistory()
            return nil
        }
        for slot in 1...4 {
            let storage = settings.inspectorPanelShortcut(slot: slot)
            if let shortcut = OMGKeyboardShortcut(storageValue: storage), shortcut.matches(event) {
                toggleInspectorPane(atSlot: slot)
                return nil
            }
        }

        let shortcut = OMGKeyboardShortcut(
            storageValue: settings.quickInputShortcut
        ) ?? .defaultQuickInput
        if shortcut.matches(event) {
            toggleQuickInput()
            return nil
        }

        guard quickInputModel.isPresented,
              let direction = AgentQuickInputFocusDirection.resolve(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
              ) else {
            return event
        }

        if window?.firstResponder is ComposerTextView {
            switch direction {
            case .up:
                restoreTerminalFocus(
                    surfaceID: quickInputLastTerminalSurfaceID ??
                        quickInputModel.targetSurfaceID
                )
            case .left, .right:
                focusSplitFromQuickInput(direction: direction)
            case .down:
                break
            }
            return nil
        }

        guard direction == .down,
              let surface = focusedSurface ?? surfaceTree.first,
              !hasSplitFocusTarget(from: surface, direction: .down) else {
            return event
        }
        quickInputLastTerminalSurfaceID = surface.id
        quickInputModel.requestFocus()
        return nil
    }

    private func hasSplitFocusTarget(
        from surface: Ghostty.SurfaceView,
        direction: Ghostty.SplitFocusDirection
    ) -> Bool {
        guard let node = surfaceTree.root?.node(view: surface) else { return false }
        return surfaceTree.focusTarget(
            for: direction.toSplitTreeFocusDirection(),
            from: node
        ) != nil
    }

    private func focusSplitFromQuickInput(
        direction: AgentQuickInputFocusDirection
    ) {
        guard let anchorID = quickInputLastTerminalSurfaceID ??
                quickInputModel.targetSurfaceID,
              let anchor = surfaceTree.first(where: { $0.id == anchorID }),
              hasSplitFocusTarget(
                from: anchor,
                direction: direction.splitDirection
              ) else {
            return
        }
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: anchor,
            userInfo: [
                Ghostty.Notification.SplitDirectionKey: direction.splitDirection as Any,
            ]
        )
        quickInputLastTerminalSurfaceID = focusedSurface?.id ?? anchorID
    }

    @discardableResult
    private func submitQuickInputText(
        _ text: String,
        to surfaceID: UUID,
        restoreFocus: Bool,
        historyID: UUID? = nil,
        completion: @escaping () -> Void = {}
    ) -> Bool {
        let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quickInputModel.setStatusMessage(strings.t("Enter a message first.", "请先输入消息内容。"))
            return false
        }
        guard text.utf8.count <= PluginProtocolContract.maximumFrameLength, !text.contains("\0") else {
            quickInputModel.setStatusMessage(strings.t("Message exceeds the 1 MiB limit.", "消息大小超过 1 MiB 限制。"))
            return false
        }
        guard !SecureInput.shared.enabled else {
            quickInputModel.setStatusMessage(strings.t(
                "Paused while Secure Input is enabled.",
                "安全输入（Secure Input）开启期间已暂停发送。"
            ))
            return false
        }
        guard let surface = surfaceTree.first(where: { $0.id == surfaceID }),
              let terminal = surface.surfaceModel else {
            quickInputModel.setStatusMessage(strings.t(
                "The target terminal is no longer available.",
                "目标终端已不可用。"
            ))
            quickInputModel.removeState(for: surfaceID)
            return false
        }
        guard !surface.readonly, !surface.processExited,
              quickInputModel.state(for: surfaceID)?.agentDraftProcessID == nil || terminal.foregroundPID != nil,
              surface.runtimeDescriptor == nil || surface.runtimeConnectionState == .ready,
              surface.runtimeInlineSession == nil || surface.runtimeInlineSession?.isRunningInThisBoot == true else {
            quickInputModel.setStatusMessage(strings.t(
                "The target terminal is not ready. The message is retained.",
                "目标终端尚未就绪，消息已保留。"
            ))
            return false
        }

        guard quickInputDraftImportTask == nil else {
            quickInputModel.setStatusMessage(strings.t(
                "Wait for the agent draft to finish importing.",
                "请等待 Agent 草稿导入完成。"
            ))
            return false
        }
        guard quickInputSubmissionTasks[surfaceID] == nil else {
            quickInputModel.setStatusMessage(strings.t(
                "Wait for the previous message to finish sending.",
                "请等待上一条消息发送完成。"
            ))
            return false
        }
        // TUIs often defer bracketed-paste handling. An Enter in the same
        // input batch can be consumed as part of paste instead of submission.
        quickInputSubmissionTasks[surfaceID] = Task { @MainActor [weak self, weak surface] in
            defer { self?.quickInputSubmissionTasks.removeValue(forKey: surfaceID) }
            guard let self, let surface,
                  self.surfaceTree.contains(where: { $0 === surface }) else { return }
            do {
                if let shortcut = self.quickInputModel.agentDraftShortcut(
                    for: surfaceID, foregroundPID: terminal.foregroundPID) {
                    try await self.replaceQuickInputAgentDraft(text, for: surface, shortcut: shortcut)
                } else {
                    terminal.sendText(text)
                }
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                let currentStrings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                self.quickInputModel.setStatusMessage(currentStrings.t(
                    "Could not send the complete message. Your draft or queued message is retained; retry sending.",
                    "未能发送完整消息，草稿或排队消息已保留，请重试发送。"
                ))
                return
            }
            guard !Task.isCancelled, !SecureInput.shared.enabled,
                  self.surfaceTree.contains(where: { $0 === surface }), !surface.processExited,
                  !surface.readonly,
                  surface.runtimeDescriptor == nil || surface.runtimeConnectionState == .ready else { return }
            if let historyID,
               self.quickInputModel.state(for: surfaceID)?.queue.first(where: { $0.id == historyID })?.text != text {
                return
            }
            terminal.sendKeyEvent(.init(key: .enter))
            terminal.sendKeyEvent(.init(key: .enter, action: .release))
            self.acknowledgeTerminalAgentState(for: surface)
            self.quickInputModel.didSubmitAgentDraft(for: surfaceID)
            self.quickInputModel.recordSentText(text, for: surfaceID, historyID: historyID)
            self.quickInputModel.setStatusMessage(nil)
            completion()
            if restoreFocus, self.quickInputModel.targetSurfaceID == surfaceID, !self.quickInputModel.isPresented {
                self.restoreTerminalFocus(surfaceID: surfaceID)
            }
        }
        return true
    }

    private func restoreTerminalFocus(surfaceID: UUID?) {
        guard let surfaceID,
              let surface = surfaceTree.first(where: { $0.id == surfaceID }) else {
            return
        }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface, self.window?.isKeyWindow == true else { return }
            self.window?.makeFirstResponder(surface)
        }
    }

    func dispatchNextQuickInput(for surfaceID: UUID) {
        guard quickInputAutomaticTasks[surfaceID] == nil,
              agentActivities[surfaceID]?.state == .done,
              quickInputModel.state(for: surfaceID)?.queue.isEmpty == false else { return }
        quickInputAutomaticTasks[surfaceID] = Task { @MainActor [weak self] in
            defer { self?.quickInputAutomaticTasks.removeValue(forKey: surfaceID) }
            // Stop hooks report completion before the CLI has returned to its
            // input loop. Do not paste into that in-progress hook invocation.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.agentActivities[surfaceID]?.state == .done,
                  let surface = self.surfaceTree.first(where: { $0.id == surfaceID }),
                  !surface.processExited,
                  let item = self.quickInputModel.state(for: surfaceID)?.queue.first else { return }
            if self.paneSessionContext(for: surface)?.isSSHSession != true {
                let foreground = surface.surfaceModel?.foregroundPID
                let hookMatches = foreground.map {
                    self.agentReducers[surfaceID]?.validationIdentity?.matchesProcessGroup($0) == true
                } ?? false
                let detected = hookMatches ? nil : foreground.flatMap(Self.processGroupCommandLines)
                    .flatMap { LocalAgentProcessDetector.detect(in: $0) }
                guard hookMatches || detected?.rawValue == self.agentActivities[surfaceID]?.source else {
                    let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                    self.quickInputModel.setStatusMessage(strings.t(
                        "The Agent is no longer in the foreground. The queued message is retained.",
                        "Agent 已不在前台，排队消息已保留。"
                    ))
                    return
                }
            }
            self.sendQueuedQuickInput(item.id, from: surfaceID)
        }
    }

    func dispatchCompletedQuickInputQueues() {
        for (surfaceID, activity) in agentActivities where activity.state == .done {
            dispatchNextQuickInput(for: surfaceID)
        }
    }

    func resolveImagePastePath(
        for localFile: URL,
        surfaceID: UUID,
        reportFailure: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        let localPath = Ghostty.Shell.escape(localFile.path)
        guard let context = paneSessionContexts[surfaceID],
              case .sshReady(let ssh, _) = context.state else {
            completion(localPath)
            return
        }

        Task { @MainActor [weak self] in
            do {
                let remotePath = try await SSHImagePasteTransfer.upload(
                    localFile: localFile,
                    to: ssh
                )
                completion(remotePath)
            } catch {
                if reportFailure {
                    let strings = SettingsStrings(language: OhMyGhosttySettings.shared.language)
                    self?.quickInputModel.setStatusMessage(strings.t(
                        "Could not upload image to \(ssh.alias); pasted the local path.",
                        "无法上传图片到 \(ssh.alias)，已粘贴本地路径。"
                    ))
                }
                completion(localPath)
            }
        }
    }
}
