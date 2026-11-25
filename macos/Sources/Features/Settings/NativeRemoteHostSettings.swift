import AppKit
import Combine
import UniformTypeIdentifiers

extension NativeSettingsController {
    func remoteHosts(_ form: NativeSettingsForm) {
        form.section(text("Your machines", "已添加的机器"))
        if registry.hosts.isEmpty { form.note(text("Add a machine to connect and configure its Agents.", "添加机器后，可连接并配置它的 Agent。")) }
        for host in registry.hosts {
            let state = registry.isConnected(host.id) ? text("Connected", "已连接") : text("Saved", "已保存")
            form.link(host.name, subtitle: "\(host.endpoint ?? host.connection.displayEndpoint) · \(state)") { [weak self] in
                self?.showHost(host.id)
            }
        }
        form.row(text("Add a machine", "添加机器"), control: SettingsActionButton(text("Add…", "添加…")) { [weak self] in self?.addHost() })
        form.section(text("SSH configuration", "SSH 配置"))
        form.row("~/.ssh/config", control: SettingsActionButton(text("Edit…", "编辑…")) {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"))
        })
        form.toggle(
            text("Add hosts when connected", "连接后自动添加主机"),
            value: registry.automaticallyRegister
        ) { [weak registry] in
            registry?.automaticallyRegister = $0
        }
    }

    func showHost(_ id: String, push: Bool = true) {
        guard let host = registry.host(id) else { select(.ssh); return }
        setRoute("host:" + id)
        let build: (NativeSettingsForm) -> Void = { [weak self] form in
            guard let self else { return }
            form.section(self.text("Connection", "连接"))
            form.row(self.text("Connection", "连接方式"), subtitle: host.endpoint ?? host.connection.displayEndpoint,
                     control: SettingsActionButton(self.text("Connect", "连接")) { [weak self] in
                guard let self else { return }
                do { try SessionRuntimeConnections.shared.open(connection: host.connection, policy: self.validatedRuntimePolicy()) } catch { self.showError(error) }
            })
            form.row(self.text("Display name", "显示名称"), control: SettingsTextField(host.name) { [weak self] in
                self?.registry.configure(id, name: $0)
            })
            let test = SettingsActionButton(self.text("Test", "测试")) {}
            test.invoke = { [weak self, weak test] in
                guard let self else { return }; test?.isEnabled = false
                Task { @MainActor [weak self, weak test] in
                    defer { test?.isEnabled = true }
                    do {
                        let result = try await SSHSessionTransport.run(connection: host.connection,
                            command: "printf OMG_CONNECTION_OK", limit: 4096, timeout: 15)
                        guard result.isSuccess, result.stdoutString.contains("OMG_CONNECTION_OK") else {
                            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
                        }
                        test?.title = self?.text("Connected", "连接成功") ?? ""
                    } catch {
                        test?.title = self?.text("Retry", "重试") ?? ""
                        if self?.isShowing("host:" + id) == true { self?.showError(error) }
                    }
                }
            }
            form.row(self.text("Test connection", "测试连接"), control: test)
            form.row(self.text("SSH configuration", "SSH 配置"), control: SettingsActionButton(self.text("Edit…", "编辑…")) {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"))
            })
            form.section(self.text("Automatic setup", "自动配置"),
                         caption: self.text("Applies on the next connection. Existing sessions keep running.", "下次连接生效。已有会话保持运行。"))
            form.toggle(self.text("Install omgd when needed", "需要时安装 omgd"), value: host.autoInstallRuntime ?? true,
                        help: self.text("Required for background sessions on this host.", "用于此主机的后台会话。")) { [weak self] in
                self?.registry.configure(id, runtime: $0)
            }
            form.toggle(
                self.text("Install Agent Hooks", "自动安装 Agent Hooks"),
                value: host.autoInstallHooks ?? self.agents.policy(for: id).updateHooksAutomatically
            ) { [weak self] value in
                guard let self else { return }
                self.registry.configure(id, hooks: value)
                var policy = self.agents.policy(for: id)
                if value { policy.checkAutomatically = true }
                policy.updateHooksAutomatically = value
                self.agents.setPolicy(policy, for: id)
            }
            let install = SettingsActionButton(self.text("Install…", "安装…")) {}
            install.invoke = { [weak self, weak install] in
                guard let self else { return }
                install?.isEnabled = false
                let policy: SessionRuntimePolicy
                do { policy = try self.validatedRuntimePolicy() } catch {
                    install?.isEnabled = true; self.showError(error); return
                }
                let registry = self.registry
                registry.reportError(nil, target: id)
                Task { @MainActor [weak self, weak install] in
                    defer { install?.isEnabled = true }
                    do {
                        try await SessionRuntimeConnections.shared.installRuntime(connection: host.connection, policy: policy)
                        install?.title = self?.text("Installed", "已安装") ?? ""
                    } catch {
                        if error is CancellationError { return }
                        registry.reportError(error.localizedDescription, target: id)
                        if self?.isShowing("host:" + id) == true { self?.showError(error) }
                    }
                }
            }
            form.row(self.text("Install omgd now", "立即安装 omgd"), control: install,
                     help: self.text("Install the bundled version without ending existing sessions.", "安装随应用提供的版本，保留已有会话。"))
            form.section("Agent")
            let count = host.snapshot.cli.values.filter { $0.path != nil }.count
            form.link(self.text("Agents on this machine", "此机器上的 Agent"),
                      subtitle: count == 0 ? self.text("Check and configure", "检查与配置") : self.text("\(count) detected", "已发现 \(count) 个")) { [weak self] in
                self?.showAgents(target: id)
            }
            form.section(self.text("Manage", "管理"))
            form.row(self.text("Remove from this list", "从列表移除"), control: SettingsActionButton(self.text("Remove…", "移除…")) { [weak self] in
                self?.confirm(self?.text("Remove \(host.name)? Running sessions are preserved.", "移除 \(host.name)？运行中的会话会保留。") ?? "") { [weak self] in
                    SessionRuntimeConnections.shared.cancelRuntimeInstallation(connection: host.connection)
                    self?.agents.forget(id); self?.select(.ssh)
                }
            })
            self.observeTarget(id, form: form)
        }
        if push { self.push(host.name, route: "host:" + id, previous: { [weak self] in self?.select(.ssh) }, build: build) } else { let form = NativeSettingsForm(); build(form); present(form, title: host.name) }
    }

    private func addHost() {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.title = text("Add a machine", "添加机器")
        sheet.isReleasedWhenClosed = false
        let form = NativeSettingsForm()
        sheet.contentViewController = form
        form.section(text("SSH address", "SSH 地址"))
        let field = SettingsTextField("", placeholder: "user@host") { _ in }
        let add: (GitSSHConnection, String?, Bool) -> Void = { [weak self, weak window, weak sheet] connection, endpoint, fromConfig in
            guard let self, let window, let sheet else { return }
            let targetID = self.registry.targetID(for: connection)
            let wasRegistered = self.registry.host(targetID) != nil
            let id = self.registry.addConfigured(connection, endpoint: endpoint, fromConfiguration: fromConfig)
            if !wasRegistered {
                var policy = self.agents.policy(for: id)
                policy.checkAutomatically = false
                policy.updateHooksAutomatically = false
                self.agents.setPolicy(policy, for: id)
            }
            window.endSheet(sheet)
            self.showHost(id)
        }
        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true
        let addButton = SettingsActionButton(text("Add", "添加")) { [weak field, weak errorLabel] in
            guard let value = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            do { add(try GitSSHConnection(destination: value), nil, false) } catch {
                errorLabel?.stringValue = error.localizedDescription
                errorLabel?.isHidden = false
            }
        }
        addButton.keyEquivalent = "\r"
        let controls = NSStackView(views: [field, addButton])
        form.row(text("Alias or address", "别名或地址"), control: controls)
        form.stack.addArrangedSubview(errorLabel)
        let cancel = SettingsActionButton(text("Cancel", "取消")) { [weak window, weak sheet] in
            if let window, let sheet { window.endSheet(sheet) }
        }
        cancel.keyEquivalent = "\u{1b}"
        form.row("", control: cancel)
        form.section(text("From SSH config", "从 SSH config 添加"))
        let task = Task { @MainActor [weak self, weak form] in
            guard let load = self?.hostChoices else { return }
            let choices = await load()
            guard let self, let form, !Task.isCancelled else { return }
            for choice in choices {
                let exists = self.registry.host(self.registry.targetID(for: choice.connection)) != nil
                let button = SettingsActionButton(exists ? self.text("Added", "已添加") : self.text("Add", "添加")) {
                    add(choice.connection, choice.endpoint, true)
                }
                button.isEnabled = !exists
                form.row(choice.name, subtitle: choice.endpoint, control: button)
            }
            if choices.isEmpty { form.note(self.text("No named hosts in SSH config.", "SSH config 中没有可添加的主机。")) }
        }
        // NSScrollView has no intrinsic height; assigning the controller resets
        // the panel's original contentRect to zero unless sized after layout.
        sheet.setContentSize(.init(width: 560, height: 440))
        sheet.contentMinSize = .init(width: 560, height: 440)
        window.beginSheet(sheet) { _ in task.cancel(); sheet.orderOut(nil) }
    }

    func showError(_ error: Error) {
        guard let window = view.window, window.isVisible else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func showDetails(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = text("Operation details", "操作详情")
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 520, height: 240))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let detail = NSTextView(frame: scroll.bounds)
        detail.isEditable = false
        detail.drawsBackground = false
        detail.autoresizingMask = [.width]
        detail.textContainerInset = .init(width: 2, height: 4)
        detail.textStorage?.setAttributedString(AgentIntegrationErrorHint.formatted(message))
        scroll.documentView = detail
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window)
    }

    private func observeTarget(_ target: String, form: NativeSettingsForm) {
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let details = SettingsActionButton(text("Details…", "详情…")) { [weak self] in
            guard let self, let message = self.agents.snapshot(for: target)?.maintenanceError ?? self.registry.errors[target] else { return }
            self.showDetails(message)
        }
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let row = NSStackView(views: [progress, status, details])
        form.stack.addArrangedSubview(row)
        let update = { [weak self, weak status, weak details, weak progress] in
            guard let self else { return }
            let busy = self.agents.busy.contains(target)
            let failed = (self.agents.snapshot(for: target)?.maintenanceError ?? self.registry.errors[target]) != nil
            status?.stringValue = busy ? self.text("Working…", "正在处理…") :
                (failed ? self.text("Could not finish. View details or try again.", "操作未完成，可查看详情或重试。") : "")
            details?.isHidden = !failed
            if busy { progress?.startAnimation(nil) } else { progress?.stopAnimation(nil) }
        }
        update()
        let token = agents.objectWillChange.merge(with: registry.objectWillChange).receive(on: RunLoop.main).sink { _ in update() }
        form.retained.append(token)
    }

    /// Cards 2 & 3 of the AI page: Terminal Coding Agents, then Agent History.
    func agentOverview(_ form: NativeSettingsForm) {
        form.section(strings.terminalCodingAgentsSection)
        toggle(form, strings.agentStatusHooksLabel, \.agentStatusHooksEnabled, help: strings.agentStatusHooksHelp)
        let localLink = form.link(
            text("Coding Agents on This Mac", "本机 Agent 状态扩展与 CLI"),
            subtitle: localCodingAgentsSummary()
        ) { [weak self] in
            self?.showAgents(target: AgentIntegrationManager.localID)
        }
        localLink?.setAccessibilityIdentifier("settings.ai.coding-agents.local")

        form.section(strings.agentHistorySection)
        number(form, strings.agentHistoryLimitLabel, \.agentHistoryLimit, range: 100...50000, step: 100,
               help: strings.agentHistoryLimitCaption)
        toggle(form, strings.agentHistoryBackgroundIndexingLabel, \.agentHistoryBackgroundIndexing,
               help: strings.agentHistoryBackgroundIndexingHelp)
    }

    private func localCodingAgentsSummary() -> String {
        let snapshot = agents.snapshot(for: AgentIntegrationManager.localID)
        let detected = SupportedAgent.allCases.filter { snapshot?.cli[$0]?.path != nil }.count
        let enabledHooks = SupportedAgent.allCases.filter { snapshot?.hooks[$0]?.isInstalled == true }.count
        if detected == 0 && enabledHooks == 0 {
            return text(
                "Set up status extensions and CLI updates for Claude Code, Codex, Cursor, Pi, and more.",
                "管理 Claude Code、Codex、Cursor、Pi 等终端 Agent 的状态扩展与 CLI 更新。"
            )
        }
        return text(
            "\(detected) detected · \(enabledHooks) status extensions active",
            "已发现 \(detected) 个 Agent · \(enabledHooks) 个已启用状态扩展"
        )
    }

    func showAgents(target: String) {
        let local = target == AgentIntegrationManager.localID
        if !local { agents.loadCached(target: target) }
        let name = local ? text("This Mac", "此 Mac") : registry.host(target)?.name ?? target
        setRoute("agents:" + target)
        push(name + " · Agent", route: "agents:" + target, previous: { [weak self] in
            if local { self?.select(.agents) } else { self?.showHost(target, push: false) }
        }, build: { [weak self] form in
            guard let self else { return }
            self.buildAgents(target, in: form)
        })
    }

    private func buildAgents(_ target: String, in form: NativeSettingsForm) {
        let local = target == AgentIntegrationManager.localID
        let policy = agents.policy(for: target)
        form.section(text("Setup", "状态扩展配置"))
        form.row(text("Agent discovery", "检查已安装的 Agent"), control: SettingsActionButton(text("Check", "检查")) { [weak self] in
            guard let self else { return }
            let manager = self.agents
            Task { await manager.refresh(target: target, checkLatest: false) }
        })
        if local {
            form.toggle(text("Maintain status extensions automatically", "自动维护已安装的状态扩展"),
                        value: policy.updateHooksAutomatically) { [weak self] value in
                guard let self else { return }
                var policy = self.agents.policy(for: target)
                if value { policy.checkAutomatically = true }
                policy.updateHooksAutomatically = value
                self.agents.setPolicy(policy, for: target)
            }
        }
        form.row(text("Enable all detected Agents", "一键启用已发现的 Agent"),
                 control: SettingsActionButton(text("Install", "启用")) { [weak self] in
            self?.agents.beginSetup(target: target, installAll: true)
        })
        form.section(text("Supported Agents", "支持的 Agent"))
        let list = NativeAgentSettingsList(target: target, manager: agents, strings: strings, includeUnavailable: true)
        list.onSelect = { [weak self] in self?.showAgent($0, target: target) }
        form.addChild(list)
        _ = list.view
        // Show every supported Agent inline on one scrollable page instead of a 4th-level subpage.
        let height = form.embed(list.view, height: CGFloat(max(1, list.displayedCount)) * 48)
        list.onCountChange = { [weak height] count in height?.constant = CGFloat(max(1, count)) * 48 }
        form.section(text("Maintenance", "维护与工具"))
        form.toggle(text("Update Agent CLIs automatically", "自动更新 Agent CLI"), value: policy.updatesCLIs) { [weak self] in
            guard let self else { return }; var policy = self.agents.policy(for: target)
            policy.updateAllCLIsAutomatically = $0
            policy.automaticallyUpdatedAgents = []
            if $0 { policy.checkAutomatically = true }
            self.agents.setPolicy(policy, for: target)
        }
        form.toggle(strings.agentMaintenance, value: policy.checkAutomatically) { [weak self] in
            guard let self else { return }; var policy = self.agents.policy(for: target)
            policy.checkAutomatically = $0; self.agents.setPolicy(policy, for: target)
        }
        form.toggle(strings.agentCheckOnConnection, value: policy.checkOnConnection == true) { [weak self] in
            guard let self else { return }; var policy = self.agents.policy(for: target)
            policy.checkOnConnection = $0; self.agents.setPolicy(policy, for: target)
        }
        form.row(text("Check interval (hours)", "检查间隔（小时）"), control: SettingsNumberField(
            value: Double(policy.intervalHours), range: 1...168, step: 1) { [weak self] in
                guard let self else { return }; var policy = self.agents.policy(for: target)
                policy.intervalHours = Int($0); self.agents.setPolicy(policy, for: target)
            })
        if let checked = policy.lastSuccess { form.note(strings.agentLastChecked + " " + checked.formatted()) }
        if let message = policy.lastMaintenanceError {
            form.row(text("Last check did not finish", "上次检查未完成"), control: SettingsActionButton(text("Details…", "详情…")) { [weak self] in
                self?.showDetails(message)
            })
        }
        if local {
            form.row(
                strings.exportSSHInstallerButton,
                subtitle: text("Export a standalone script for manual setup on restricted SSH hosts.",
                               "导出独立安装脚本，供在受限 SSH 主机上审阅并手动执行。"),
                control: SettingsActionButton(text("Export…", "导出…")) { [weak self] in
                    self?.exportHooks()
                }
            )
        }
        observeTarget(target, form: form)
    }

    private func refreshAgents(_ target: String) {
        setRoute("agents:" + target)
        let form = NativeSettingsForm()
        buildAgents(target, in: form)
        present(form, title: (registry.host(target)?.name ?? text("This Mac", "此 Mac")) + " · Agent")
    }

    private func showAgent(_ agent: SupportedAgent, target: String) {
        setRoute("agent:" + target + ":" + agent.rawValue)
        let snapshot = agents.snapshot(for: target) ?? .init()
        push(agent.displayName, route: "agent:" + target + ":" + agent.rawValue,
             previous: { [weak self] in
                 self?.refreshAgents(target)
             }, build: { [weak self] form in
            guard let self else { return }
            form.section(agent.displayName)
            form.row(self.text("Command", "命令路径"), subtitle: snapshot.cli[agent]?.path ?? self.text("Not detected", "未发现"),
                     control: NSTextField(labelWithString: snapshot.cli[agent]?.displayVersion ?? ""))
            var hookToggle: SettingsSwitch?
            if target == AgentIntegrationManager.localID || agent.definition.hook.kind != .none {
                let toggle = SettingsSwitch(value: snapshot.hooks[agent]?.isInstalled == true) { _ in }
                hookToggle = toggle
                toggle.change = { [weak self, weak toggle] enabled in
                    guard let self else { return }
                    toggle?.isEnabled = false
                    let manager = self.agents
                    manager.acknowledgeOnboarding(target: target)
                    Task { @MainActor [weak toggle] in
                        await manager.update(agent, target: target, remove: !enabled)
                        toggle?.state = manager.snapshot(for: target)?.hooks[agent]?.isInstalled == true ? .on : .off
                        toggle?.isEnabled = true
                    }
                }
                form.row("Hooks", control: toggle)
                toggle.isEnabled = !self.agents.busy.contains(target) &&
                    (snapshot.cli[agent]?.path != nil || snapshot.hooks[agent]?.isInstalled == true)
                form.row(self.text("Repair Hooks", "重新安装 Hooks"), control: SettingsActionButton(self.text("Install", "安装")) { [weak self] in
                    self?.agents.acknowledgeOnboarding(target: target)
                    Task { await self?.agents.update(agent, target: target) }
                })
            }
            let update = SettingsActionButton(snapshot.cli[agent]?.path == nil ? self.text("Install", "安装") : self.text("Update", "更新")) { [weak self] in
                Task { await self?.agents.update(agent, target: target, cli: true) }
            }
            update.isEnabled = snapshot.cli[agent]?.canAutomaticallyUpdate == true
            form.row(self.text("Agent CLI", "Agent CLI"), control: update)
            let refresh = self.agents.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak hookToggle, weak update] _ in
                guard let self else { return }
                let current = self.agents.snapshot(for: target)
                let idle = !self.agents.busy.contains(target)
                hookToggle?.state = current?.hooks[agent]?.isInstalled == true ? .on : .off
                hookToggle?.isEnabled = idle && (current?.cli[agent]?.path != nil || current?.hooks[agent]?.isInstalled == true)
                update?.isEnabled = idle && current?.cli[agent]?.canAutomaticallyUpdate == true
            }
            form.retained.append(refresh)
            if snapshot.cli[agent]?.canAutomaticallyUpdate == true {
                form.toggle(self.text("Update this Agent automatically", "自动更新此 Agent"),
                            value: self.agents.policy(for: target).updatesCLI(agent)) { [weak self] enabled in
                    guard let self else { return }
                    var policy = self.agents.policy(for: target)
                    if policy.updateAllCLIsAutomatically == true {
                        policy.automaticallyUpdatedAgents = Set(SupportedAgent.allCases)
                        policy.updateAllCLIsAutomatically = false
                    }
                    if enabled { policy.automaticallyUpdatedAgents.insert(agent); policy.checkAutomatically = true } else { policy.automaticallyUpdatedAgents.remove(agent) }
                    self.agents.setPolicy(policy, for: target)
                }
            } else { form.note(self.strings.agentExternalUpdater) }
            self.observeTarget(target, form: form)
        })
    }

    private func exportHooks() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "omg-agent-hooks.py"
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let script = try AgentHookInstaller.remoteInstallerScript()
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } catch { self?.showError(error) }
        }
    }
}
