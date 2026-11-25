import AppKit
import Combine

extension NativeSettingsController {
    /// The AI page: 5 focused cards covering model services, automatic tab titles,
    /// Git commit/PR generation, terminal coding agents, and notifications/history.
    func aiOverview(_ form: NativeSettingsForm) {
        aiModelServicesSection(form)
        aiTitleSection(form)
        aiCommitSection(form)
        agentOverview(form)
    }

    // MARK: Card 1 — Model Services

    private func aiModelServicesSection(_ form: NativeSettingsForm) {
        form.section(strings.aiProvidersSection, caption: strings.aiProvidersFootnote)
        for provider in settings.aiProviders {
            let id = provider.id
            let link = form.link(provider.name, subtitle: strings.aiProviderSummary(provider)) { [weak self] in
                self?.showAIProvider(id)
            }
            link?.setAccessibilityIdentifier("settings.ai.provider." + id.uuidString)
        }

        let addServiceButton = SettingsActionButton(strings.aiAddConnection) { [weak self] in
            self?.addConnection()
        }
        addServiceButton.isEnabled = settings.aiProviders.count < AIProvider.maxProviders
        addServiceButton.setAccessibilityLabel(strings.aiAddConnectionHelp)
        addServiceButton.setAccessibilityIdentifier("settings.ai.provider.add")
        let addSubtitle = settings.aiProviders.isEmpty
            ? text("Add an OpenAI-compatible or Anthropic API endpoint for tab titles and Git messages.",
                   "添加 OpenAI 兼容或 Anthropic 接口，用于标签页自动命名与 Git 信息生成。")
            : text("Connect another OpenAI-compatible or Anthropic API endpoint.",
                   "连接新的 OpenAI 兼容或 Anthropic 接口。")
        form.row(strings.aiAddServiceLabel, subtitle: addSubtitle, control: addServiceButton)

        let localCLILink = form.link(
            strings.aiLocalCLIModelsLabel,
            subtitle: aiLocalCLIModelsSummary()
        ) { [weak self] in
            self?.showAILocalCLIModels()
        }
        localCLILink?.setAccessibilityIdentifier("settings.ai.local-cli-models")
    }

    /// Summary of local CLI model sources without starting any child process.
    private func aiLocalCLIModelsSummary() -> String {
        let snapshot = agents.snapshot(for: AgentIntegrationManager.localID)
        let installedNames = GitCommitAgent.allCases.filter { agent in
            SupportedAgent(rawValue: agent.rawValue).flatMap { snapshot?.cli[$0]?.path } != nil
        }.map(\.title)
        let discoveredModels = GitCommitAgent.allCases.reduce(0) { total, agent in
            total + (aiAgentCatalog.entry(agent).models?.count ?? 0)
        }
        var parts: [String] = []
        if installedNames.isEmpty {
            parts.append(GitCommitAgent.allCases.map(\.title).joined(separator: text(", ", "、")))
        } else {
            parts.append(installedNames.joined(separator: text(", ", "、")))
        }
        if discoveredModels > 0 {
            parts.append(strings.aiModelCount(discoveredModels))
        } else {
            parts.append(text("Reuse logged-in CLIs for Git messages without an API key",
                              "无需 API 密钥，直接复用已登录 CLI 生成 Git 信息"))
        }
        return parts.joined(separator: " · ")
    }

    func showAILocalCLIModels(push: Bool = true) {
        let title = strings.aiLocalCLIModelsLabel
        let route = "ai-local-cli-models"
        let build: (NativeSettingsForm) -> Void = { [weak self] form in
            guard let self else { return }
            form.section(
                title,
                caption: self.text(
                    "Use your logged-in local coding CLIs to generate Git commit, tag, and PR messages without entering an API key. Select a CLI to inspect its available models.",
                    "直接复用本机已登录的编码 CLI 生成 Git 提交、标签与 PR 信息，无需额外配置 API 密钥。点击可查看该 CLI 支持的模型。"
                )
            )
            let snapshot = self.agents.snapshot(for: AgentIntegrationManager.localID)
            for agent in GitCommitAgent.allCases {
                let link = form.link(agent.title, subtitle: self.aiAgentSummary(agent, snapshot: snapshot)) { [weak self] in
                    self?.showAIAgent(agent)
                }
                link?.setAccessibilityIdentifier("settings.ai.agent." + agent.rawValue)
            }
        }
        if push {
            self.push(title, route: route, previous: { [weak self] in self?.select(.agents) }, build: build)
        } else {
            setRoute(route)
            let form = NativeSettingsForm()
            build(form)
            present(form, title: title)
        }
    }

    /// A new connection starts as a draft with nothing in it. Leaving it
    /// untouched discards it, so the list never collects empty connections.
    func addConnection() {
        guard settings.aiProviders.count < AIProvider.maxProviders,
              let provider = settings.addAIProvider(name: strings.aiNewConnectionName) else { return }
        showAIProvider(provider.id)
        aiConnectionDraft = provider.id
    }

    /// Called when an edited connection page is left.
    private func discardPristineConnection(_ id: UUID) {
        guard aiConnectionDraft == id else { return }
        aiConnectionDraft = nil
        guard let provider = settings.aiProvider(id),
              provider.baseURL.isEmpty, provider.models.isEmpty,
              provider.name == strings.aiNewConnectionName,
              !aiCredentials.hasAPIKey(for: id) else { return }
        try? settings.removeAIProvider(id)
    }

    /// Anchors the model-source menu directly beneath the invoking button.
    private func showAddModelsMenu(from button: NSButton) {
        let menu = NSMenu()
        let api = NSMenuItem(title: text("From API Service…", "从 API 服务添加…"), action: nil, keyEquivalent: "")
        api.action = #selector(addProviderModelsFromPage)
        api.target = self
        let agent = NSMenuItem(title: text("From Local CLI…", "从本机 CLI 添加…"), action: nil, keyEquivalent: "")
        agent.action = #selector(addAgentModelsFromPage)
        agent.target = self
        menu.addItem(api)
        menu.addItem(agent)
        let origin = NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    @objc private func addAgentModelsFromPage() {
        GitCommitAISettingsPanel.presentAddModels(settings: settings, from: view.window)
    }

    @objc private func addProviderModelsFromPage() {
        GitCommitAISettingsPanel.presentAddProviderModels(
            settings: settings,
            from: view.window,
            onAddProvider: { [weak self] in self?.addConnection() }
        )
    }

    /// CLI state from the last Agent check, then the model count once known.
    private func aiAgentSummary(_ agent: GitCommitAgent, snapshot: AgentIntegrationSnapshot?) -> String {
        let cli = SupportedAgent(rawValue: agent.rawValue).flatMap { snapshot?.cli[$0] }
        let version = cli?.displayVersion?.replacingOccurrences(
            of: " (" + agent.title + ")", with: "", options: .anchored)
        var parts = [cli?.path == nil ? text("Not installed", "未安装")
                     : version ?? text("Installed", "已安装")]
        if let models = aiAgentCatalog.entry(agent).models {
            parts.append(strings.aiModelCount(models.count))
        }
        return parts.joined(separator: " · ")
    }

    func showAIAgent(_ agent: GitCommitAgent) {
        let fromCLIList = isShowing("ai-local-cli-models")
        push(agent.title, route: "ai-agent:" + agent.rawValue,
             previous: { [weak self] in
                 if fromCLIList {
                     self?.showAILocalCLIModels(push: false)
                 } else {
                     self?.select(.agents)
                 }
             },
             build: { [weak self] form in
                 guard let self else { return }
                 let page = AIAgentPage(controller: self, agent: agent)
                 page.build(in: form)
                 form.retained.append(page)
             })
    }

    func showAIProvider(_ id: UUID) {
        guard let provider = settings.aiProvider(id) else {
            select(.agents)
            return
        }
        let route = "ai-provider:" + id.uuidString
        push(provider.name, route: route,
             previous: { [weak self] in
                 self?.select(.agents)
                 self?.discardPristineConnection(id)
             },
             build: { [weak self] form in
                 guard let self else { return }
                 let page = AIProviderPage(controller: self, provider: id, route: route)
                 page.build(in: form)
                 form.retained.append(page)
             })
    }

    // MARK: Card 2 — Automatic Tab Titles

    private func aiTitleSection(_ form: NativeSettingsForm) {
        form.section(strings.aiTitleModelGroup)
        let titleModes = AgentSessionTitleMode.allCases
        let titlePopup = SettingsPopup(
            titles: titleModes.map { strings.agentSessionTitleModeTitle($0) },
            selected: titleModes.firstIndex(of: settings.agentSessionTitleMode) ?? 0
        ) { [weak settings] index in
            guard titleModes.indices.contains(index) else { return }
            settings?.agentSessionTitleMode = titleModes[index]
        }
        titlePopup.setAccessibilityIdentifier("settings.ai.title.mode")
        form.row(strings.agentSessionTitleLabel, subtitle: strings.agentSessionTitleCaption, control: titlePopup)

        let alwaysUseAISwitch = SettingsSwitch(value: settings.agentSessionTitleAlwaysUseAI) { [weak settings] value in
            settings?.agentSessionTitleAlwaysUseAI = value
        }
        alwaysUseAISwitch.setAccessibilityIdentifier("settings.ai.title.always-use-ai")
        form.row(
            strings.agentSessionTitleAlwaysUseAILabel,
            subtitle: strings.agentSessionTitleAlwaysUseAICaption,
            control: alwaysUseAISwitch
        )

        let choose = SettingsActionButton(text("Choose…", "选择…")) { [weak self] in
            guard let self else { return }
            GitCommitAISettingsPanel.presentTitleModel(
                settings: self.settings,
                from: self.view.window,
                onAddProvider: { [weak self] in self?.addConnection() }
            )
        }
        choose.setAccessibilityIdentifier("settings.ai.title.choose-model")
        let clear = SettingsActionButton(text("Clear", "清除")) { [weak settings] in settings?.aiTitleRoute = nil }
        clear.setAccessibilityIdentifier("settings.ai.title.clear-model")
        let titleButtons = NSStackView(views: [choose, clear])
        titleButtons.spacing = 8
        let titleModel = form.row(strings.aiTitleModelLabel, subtitle: aiTitleModelSummary(),
                                  control: titleButtons, help: strings.aiTitleModelCaption)
        let syncTitleModel = { [weak self, weak clear, weak titlePopup, weak alwaysUseAISwitch] in
            guard let self else { return }
            titleModel?.setSubtitle(self.aiTitleModelSummary())
            clear?.isEnabled = self.settings.aiTitleRoute != nil
            titlePopup?.selectItem(at: titleModes.firstIndex(of: self.settings.agentSessionTitleMode) ?? 0)
            alwaysUseAISwitch?.state = self.settings.agentSessionTitleAlwaysUseAI ? .on : .off
            alwaysUseAISwitch?.isEnabled = self.settings.agentSessionTitleMode == .generate
        }
        syncTitleModel()
        form.refreshers.append(syncTitleModel)
    }

    // MARK: Card 3 — Git Commit & PR Messages

    private func aiCommitSection(_ form: NativeSettingsForm) {
        form.section(strings.aiTaskModelsSection)
        let addModels = SettingsActionButton(strings.aiAddModels) {}
        addModels.invoke = { [weak self, weak addModels] in
            guard let self, let addModels else { return }
            self.showAddModelsMenu(from: addModels)
        }
        addModels.setAccessibilityIdentifier("settings.ai.commit.add-models")
        let models = form.row(text("Generation Models", "生成模型"), control: addModels)
        let coordinator = GitCommitAIRoutesTable.Coordinator(settings: settings)
        let routes = GitCommitAIRoutesTable.makeNativeView(coordinator: coordinator)
        routes.hasVerticalScroller = false
        form.retained.append(coordinator)
        let height = form.embed(routes, height: 0)
        let copy = strings
        let divider = form.embedSeparator
        let update: ([GitCommitAIRoute]) -> Void = { [weak coordinator, weak routes, weak divider] list in
            divider?.isHidden = list.isEmpty
            coordinator?.tableView?.reloadData()
            height?.constant = CGFloat(list.count) * GitCommitAIRoutesTable.rowHeight
            routes?.isHidden = list.isEmpty
            models?.setSubtitle(list.isEmpty
                ? copy.t("No models yet. Add one to generate commit, tag, and PR messages.",
                         "尚未添加模型。添加后即可一键生成提交、标签与 PR 信息。")
                : copy.t("Tried from top to bottom with automatic fallback. Drag or use arrows to reorder.",
                         "按从上到下的顺序尝试，失败时自动切换备用模型；可拖动或用箭头调整顺序。"))
        }
        update(settings.gitCommitAIRoutes)
        form.retained.append(settings.$gitCommitAIRoutes.receive(on: RunLoop.main).sink { [weak settings] _ in
            if let settings { update(settings.gitCommitAIRoutes) }
        })
        form.retained.append(settings.$aiProviders.receive(on: RunLoop.main).sink { [weak coordinator] _ in
            coordinator?.tableView?.reloadData()
        })

        let editPrompt = SettingsActionButton(text("Edit…", "编辑…")) { [weak self] in
            guard let self else { return }
            GitCommitAISettingsPanel.presentPrompt(settings: self.settings, from: self.view.window)
        }
        editPrompt.setAccessibilityIdentifier("settings.ai.commit.edit-prompt")
        let promptRow = form.row(
            strings.gitCustomPromptLabel,
            subtitle: commitPromptSummary(),
            control: editPrompt
        )
        let syncPrompt = { [weak self] in
            guard let self else { return }
            promptRow?.setSubtitle(self.commitPromptSummary())
        }
        form.refreshers.append(syncPrompt)
    }

    func commitPromptSummary() -> String {
        let trimmed = settings.gitCommitAIPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? text("Follows recent commits by default. Customize language, format, or commit style.",
                   "默认参考近期提交风格；可自定义生成的语言、格式与提交规范。")
            : text("Custom instructions configured (applies to all models).",
                   "已配置自定义提示词（对所有生成模型生效）。")
    }

    /// The chosen title model, or why no title will be generated.
    func aiTitleModelSummary() -> String {
        guard let route = settings.aiTitleRoute else { return strings.aiTitleModelUnset }
        guard let provider = settings.aiProvider(route.provider) else {
            return text("\(route.model): its API service was removed. Choose another model.",
                        "\(route.model)：所属的 API 服务已被移除，请重新选择模型。")
        }
        let name = provider.name + " · " + route.model
        return provider.enabled ? name
            : text("\(name): the service is turned off, so no titles are generated.",
                   "\(name)：该服务已停用，不会生成标题。")
    }
}

/// Detail page of a local coding CLI: how it is reached and the models it advertises.
@MainActor
final class AIAgentPage {
    private weak var controller: NativeSettingsController?
    private let agent: GitCommitAgent
    private let catalog: AIAgentModelCatalog
    private let strings: SettingsStrings
    private let list: AIModelListController
    private let refreshButton = SettingsActionButton("") {}
    private let adapterButton = SettingsActionButton("") {}
    private var modelsRow: NativeSettingsRow?
    private var filterRow: NativeSettingsRow?
    private var adapterRow: NativeSettingsRow?
    private var listHeight: NSLayoutConstraint?
    private var listSeparator: NSView?
    private var adapterUpdate: GitACPAdapterUpdateInfo?
    private var adapterTask: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(controller: NativeSettingsController, agent: GitCommitAgent) {
        self.controller = controller
        self.agent = agent
        catalog = controller.aiAgentCatalog
        strings = controller.strings
        list = AIModelListController(editable: false, strings: controller.strings)
    }

    deinit { adapterTask?.cancel() }

    private func text(_ en: String, _ zh: String) -> String { strings.t(en, zh) }

    func build(in form: NativeSettingsForm) {
        guard let controller else { return }
        form.section(agent.title)
        let cli = SupportedAgent(rawValue: agent.rawValue).flatMap {
            controller.agents.snapshot(for: AgentIntegrationManager.localID)?.cli[$0]
        }
        form.row(text("Command line tool", "命令行工具"),
                 subtitle: cli?.path ?? text("Not detected by the last Agent check.", "上次检查未发现此命令行工具。"),
                 control: NSTextField(labelWithString: cli?.displayVersion ?? "—"))
        form.row(text("Local helper command", "本机调用命令"),
                 subtitle: text("OMG invokes this local command with the CLI's own login.",
                                "OMG 通过这条本机命令复用该 CLI 的登录状态。"),
                 control: NSTextField(labelWithString: agent.acpCommand.joined(separator: " ")))
        if agent == .codex {
            adapterButton.invoke = { [weak self] in self?.adapterAction() }
            adapterButton.setAccessibilityIdentifier("settings.ai.agent.codex.adapter-update")
            adapterRow = form.row(text("Codex helper package", "Codex 桥接组件"), control: adapterButton)
            refreshAdapter(failure: nil)
        }

        form.section(text("Available Models", "可用模型"),
                     caption: text("Discovered from this CLI's local login. Add them under Git Commit & PR Messages on the AI page.",
                                   "读取自该 CLI 当前本机登录账号。可在「Git 提交与 PR 信息生成」中添加使用。"))
        refreshButton.title = text("Refresh", "刷新")
        refreshButton.invoke = { [weak self] in
            guard let self else { return }
            self.catalog.refresh(self.agent)
        }
        refreshButton.setAccessibilityIdentifier("settings.ai.agent.refresh-models")
        modelsRow = form.row(text("Discovered models", "已发现的模型"), control: refreshButton)
        form.addChild(list)
        _ = list.view
        filterRow = form.row(text("Filter", "筛选"), control: list.filterField)
        listHeight = form.embed(list.view, height: 0)
        listSeparator = form.embedSeparator
        list.onHeightChange = { [weak self] in self?.applyListHeight($0) }

        sync()
        subscription = catalog.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }
        if catalog.entry(agent).models == nil, !catalog.entry(agent).isLoading { catalog.refresh(agent) }
    }

    private func applyListHeight(_ height: CGFloat) {
        listHeight?.constant = height
        list.view.isHidden = height == 0
        listSeparator?.isHidden = height == 0
    }

    private func sync() {
        let entry = catalog.entry(agent)
        let models = entry.models ?? []
        list.setModels(models.map { AIProviderModel(id: $0) })
        applyListHeight(list.preferredHeight)
        filterRow?.setVisible(models.count > AIModelListController.filterThreshold)
        refreshButton.isEnabled = !entry.isLoading
        let status: String
        if entry.isLoading {
            status = text("Loading models…", "正在加载模型…")
        } else if let error = entry.error {
            status = error
        } else if entry.models == nil {
            status = text("Not loaded yet.", "尚未加载。")
        } else if models.isEmpty {
            status = text("No models found. Make sure the CLI and its local helper command are installed and logged in.",
                          "未发现模型，请确认该 CLI 与本机调用命令已安装并完成登录。")
        } else {
            let checked = entry.checkedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            status = strings.aiModelCount(models.count) + checked
        }
        modelsRow?.setSubtitle(status)
    }

    // MARK: Codex helper package

    private func adapterAction() {
        guard adapterTask == nil else { return }
        guard let update = adapterUpdate, update.updateAvailable else {
            checkAdapter()
            return
        }
        controller?.confirm(
            GitL10n.text("Update Codex ACP for OMG?"),
            message: GitL10n.text(
                "OMG will install this stable Codex ACP version in its own Application Support folder. Your global npm installation will not be changed."
            ),
            actionTitle: GitL10n.text("Update and reload")
        ) { [weak self] in self?.installAdapter(update.latestVersion) }
    }

    private func checkAdapter() {
        adapterButton.isEnabled = false
        adapterRow?.setSubtitle(GitL10n.text("Checking for Codex ACP updates…"))
        adapterTask = Task { @MainActor [weak self] in
            let info = try? await GitACPAdapterManager.checkCodexUpdate()
            guard let self, !Task.isCancelled else { return }
            self.adapterTask = nil
            self.adapterUpdate = info
            self.refreshAdapter(failure: info == nil
                ? GitL10n.text("Could not check the Codex ACP version. Model loading is unaffected.") : nil)
        }
    }

    private func installAdapter(_ version: String) {
        guard adapterTask == nil else { return }
        adapterButton.isEnabled = false
        adapterRow?.setSubtitle(text("Installing Codex helper \(version)…", "正在安装 Codex 桥接组件 \(version)…"))
        adapterTask = Task { @MainActor [weak self] in
            var failure: String?
            do {
                try await GitACPAdapterManager.installCodex(version: version)
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.adapterTask = nil
            if failure == nil {
                self.adapterUpdate = GitACPAdapterUpdateInfo(installedVersion: version, latestVersion: version)
                self.catalog.refresh(.codex)
            }
            self.refreshAdapter(failure: failure)
        }
    }

    private func refreshAdapter(failure: String?) {
        adapterButton.isEnabled = true
        guard let update = adapterUpdate else {
            adapterButton.title = text("Check for Updates", "检查更新")
            adapterRow?.setSubtitle(failure ?? text(
                "OMG can install a private copy in Application Support without modifying global npm packages.",
                "OMG 可安装一份独立组件副本，不会改动全局 npm 环境。"
            ))
            return
        }
        if update.updateAvailable {
            adapterButton.title = GitL10n.text(update.installedVersion == nil ? "Install for OMG…" : "Update for OMG…")
            adapterRow?.setSubtitle(failure ?? GitL10n.format(
                "Codex ACP update available: {0} (installed: {1}).",
                update.latestVersion, update.installedVersion ?? GitL10n.text("not detected")
            ))
        } else {
            adapterButton.title = text("Check for Updates", "检查更新")
            adapterRow?.setSubtitle(failure ?? GitL10n.format("Codex ACP is up to date ({0}).", update.latestVersion))
        }
    }
}

/// Detail page of an API connection: where it is, its key, and the models it offers.
@MainActor
final class AIProviderPage {
    private weak var controller: NativeSettingsController?
    private let settings: OhMyGhosttySettings
    private let credentials: AICredentialStore
    private let client: AIHTTPClient
    private let strings: SettingsStrings
    private let id: UUID
    private let route: String
    private let list: AIModelListController
    private let nameField = SettingsTextField("") { _ in }
    private let urlField = SettingsTextField("") { _ in }
    private let keyField = SettingsSecureField("") { _ in }
    private let clearKeyButton = SettingsActionButton("") {}
    private let fetchButton = SettingsActionButton("") {}
    private let addField = SettingsTextField("", placeholder: "model-id") { _ in }
    private let addButton = SettingsActionButton("") {}
    private var urlRow: NativeSettingsRow?
    private var keyRow: NativeSettingsRow?
    private var modelsRow: NativeSettingsRow?
    private var filterRow: NativeSettingsRow?
    private var listHeight: NSLayoutConstraint?
    private var listSeparator: NSView?
    /// Outcome of the last fetch or add, shown instead of the model count until the list changes.
    private var notice: String?
    private var fetchTask: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(controller: NativeSettingsController, provider id: UUID, route: String) {
        self.controller = controller
        self.id = id
        self.route = route
        settings = controller.settings
        credentials = controller.aiCredentials
        client = controller.aiHTTPClient
        strings = controller.strings
        list = AIModelListController(editable: true, strings: controller.strings)
    }

    deinit { fetchTask?.cancel() }

    private func text(_ en: String, _ zh: String) -> String { strings.t(en, zh) }

    func build(in form: NativeSettingsForm) {
        guard let provider = settings.aiProvider(id) else { return }
        buildConnection(provider, in: form)
        buildModels(provider, in: form)

        form.section(text("Manage", "管理"))
        let remove = SettingsActionButton(text("Remove…", "移除…")) { [weak self] in self?.confirmRemoval() }
        remove.setAccessibilityIdentifier("settings.ai.provider.remove")
        form.row(text("Remove this service", "移除此 API 服务"), control: remove,
                 help: text("Also deletes its stored API key and any model choices that use it.",
                            "同时删除已保存的 API 密钥，以及使用它的模型配置。"))

        subscription = settings.$aiProviders.receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }
    }

    private func buildConnection(_ provider: AIProvider, in form: NativeSettingsForm) {
        form.section(text("Service Endpoint", "服务连接"))
        nameField.stringValue = provider.name
        nameField.commit = { [weak self] in self?.rename($0) }
        nameField.setAccessibilityIdentifier("settings.ai.provider.name")
        form.row(text("Name", "名称"), control: nameField)

        let kinds = AIEndpointProtocol.allCases
        let kind = SettingsPopup(
            titles: kinds.map { strings.aiProviderKindTitle($0) },
            selected: kinds.firstIndex(of: provider.kind) ?? 0
        ) { [weak self] index in
            guard let self, kinds.indices.contains(index) else { return }
            self.settings.updateAIProvider(self.id) { $0.kind = kinds[index] }
            self.urlField.placeholderString = SettingsStrings.aiBaseURLPlaceholder(kinds[index])
        }
        kind.setAccessibilityIdentifier("settings.ai.provider.kind")
        form.row(text("Protocol", "接口协议"), control: kind)

        urlField.stringValue = provider.baseURL
        urlField.placeholderString = SettingsStrings.aiBaseURLPlaceholder(provider.kind)
        urlField.commit = { [weak self] in self?.commitURL($0) }
        urlField.setAccessibilityIdentifier("settings.ai.provider.base-url")
        urlRow = form.row(text("Base URL", "基础 URL"), control: urlField)

        keyField.commit = { [weak self] in self?.commitKey($0) }
        keyField.setAccessibilityLabel(text("API key", "API 密钥"))
        keyField.setAccessibilityIdentifier("settings.ai.provider.api-key")
        clearKeyButton.title = text("Clear", "清除")
        clearKeyButton.invoke = { [weak self] in self?.clearKey() }
        clearKeyButton.setAccessibilityIdentifier("settings.ai.provider.clear-api-key")
        let keyControls = NSStackView(views: [keyField, clearKeyButton])
        keyControls.spacing = 8
        keyRow = form.row(text("API key", "API 密钥"), control: keyControls)
        refreshKeyStatus(problem: nil)

        let enabled = SettingsSwitch(value: provider.enabled) { [weak self] value in
            guard let self else { return }
            self.settings.updateAIProvider(self.id) { $0.enabled = value }
        }
        enabled.setAccessibilityIdentifier("settings.ai.provider.enabled")
        form.row(text("Enabled", "启用"), control: enabled,
                 help: text("When off, tasks skip this service's models.", "停用后，各功能会跳过此服务的模型。"))
    }

    private func buildModels(_ provider: AIProvider, in form: NativeSettingsForm) {
        form.section(text("Models", "模型"),
                     caption: text("Token limits accept values like 128k. Left blank, OMG requests 1,024 output tokens for tab titles and 4,096 for Git messages.",
                                   "Token 上限支持填写如 128k。留空时，标签标题默认请求 1,024 输出 token，Git 信息默认请求 4,096。"))
        fetchButton.title = text("Fetch Models", "获取模型")
        fetchButton.invoke = { [weak self] in self?.fetchModels() }
        fetchButton.setAccessibilityIdentifier("settings.ai.provider.fetch-models")
        modelsRow = form.row(text("Model list", "模型列表"), control: fetchButton)

        addField.commit = { [weak self] in self?.addModel($0) }
        addField.setAccessibilityLabel(text("Model ID", "模型 ID"))
        addField.setAccessibilityIdentifier("settings.ai.provider.add-model-id")
        addButton.title = text("Add", "添加")
        addButton.invoke = { [weak self] in
            guard let self else { return }
            self.controller?.view.window?.makeFirstResponder(nil)
            self.addModel(self.addField.stringValue)
        }
        addButton.setAccessibilityIdentifier("settings.ai.provider.add-model")
        let addControls = NSStackView(views: [addField, addButton])
        addControls.spacing = 8
        form.row(text("Add a model ID", "手动添加模型 ID"), control: addControls,
                 help: text("For services that do not expose a /models endpoint.", "适用于不提供模型列表查询接口的服务。"))

        form.addChild(list)
        _ = list.view
        filterRow = form.row(text("Filter", "筛选"), control: list.filterField)
        listHeight = form.embed(list.view, height: 0)
        listSeparator = form.embedSeparator
        list.onHeightChange = { [weak self] in self?.applyListHeight($0) }
        list.onChange = { [weak self] model in
            guard let self else { return }
            self.settings.updateAIProvider(self.id) { provider in
                guard let index = provider.models.firstIndex(where: { $0.id == model.id }) else { return }
                provider.models[index] = model
            }
        }
        list.onRemove = { [weak self] model in
            guard let self else { return }
            self.notice = nil
            self.settings.removeAIProviderModel(model, from: self.id)
        }
        showModels(of: provider)
    }

    // MARK: Connection

    private func rename(_ value: String) {
        let name = AIProvider.normalizedName(value)
        guard !name.isEmpty else {
            nameField.stringValue = settings.aiProvider(id)?.name ?? ""
            return
        }
        nameField.stringValue = name
        settings.updateAIProvider(id) { $0.name = name }
        if controller?.isShowing(route) == true { controller?.retitle(name) }
    }

    private func commitURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            settings.updateAIProvider(id) { $0.baseURL = "" }
            urlRow?.setSubtitle("")
            return
        }
        do {
            let normalized = try AIEndpoint.validatedBaseURL(trimmed).absoluteString
            settings.updateAIProvider(id) { $0.baseURL = normalized }
            urlField.stringValue = normalized
            urlRow?.setSubtitle("")
        } catch {
            urlRow?.setSubtitle(strings.aiBaseURLProblem(error as? AIEndpointError ?? .invalidURL))
        }
    }

    private func commitKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try credentials.setAPIKey(key, for: id)
            keyField.stringValue = ""
            refreshKeyStatus(problem: nil)
        } catch {
            refreshKeyStatus(problem: text("The API key could not be saved.", "无法保存 API 密钥。"))
        }
    }

    private func clearKey() {
        keyField.stringValue = ""
        do {
            try credentials.removeAPIKey(for: id)
            refreshKeyStatus(problem: nil)
        } catch {
            refreshKeyStatus(problem: text("The API key could not be removed.", "无法移除 API 密钥。"))
        }
    }

    /// Says whether a key is stored without ever reading it into a control.
    private func refreshKeyStatus(problem: String?) {
        let stored = credentials.hasAPIKey(for: id)
        keyField.placeholderString = stored ? text("Stored. Type to replace.", "已保存，输入可替换") : "sk-…"
        clearKeyButton.isEnabled = stored
        keyRow?.setSubtitle(problem ?? (stored
            ? text("Stored in a private file on this Mac, outside settings.json.",
                   "已保存在本机的私有文件中，不在 settings.json 内。")
            : text("Not set. Requests are sent without authentication.", "未设置，请求将不带认证信息。")))
    }

    private func confirmRemoval() {
        let name = settings.aiProvider(id)?.name ?? ""
        controller?.confirm(
            text("Remove \(name)?", "移除 \(name)？"),
            message: text("Its stored API key is deleted, and its models are removed from Git messages and tab titles.",
                          "已保存的 API 密钥会被删除，其模型也会从 Git 信息和标签标题的选择中移除。"),
            actionTitle: text("Remove", "移除")
        ) { [weak self] in
            guard let self else { return }
            self.fetchTask?.cancel()
            let controller = self.controller
            var failure: Error?
            do {
                try self.settings.removeAIProvider(self.id, credentials: self.credentials)
            } catch {
                failure = error
            }
            controller?.select(.agents)
            if let failure { controller?.showError(failure) }
        }
    }

    // MARK: Models

    private func applyListHeight(_ height: CGFloat) {
        listHeight?.constant = height
        list.view.isHidden = height == 0
        listSeparator?.isHidden = height == 0
    }

    private func showModels(of provider: AIProvider) {
        list.setModels(provider.models)
        applyListHeight(list.preferredHeight)
        filterRow?.setVisible(provider.models.count > AIModelListController.filterThreshold)
        modelsRow?.setSubtitle(notice ?? (provider.models.isEmpty
            ? text("No models yet. Fetch the list, or add model IDs by hand.", "尚无模型。可点击获取模型，或手动添加模型 ID。")
            : strings.aiModelCount(provider.models.count)))
    }

    /// Follows changes made elsewhere, and leaves when the connection is gone.
    private func sync() {
        guard let provider = settings.aiProvider(id) else {
            if controller?.isShowing(route) == true { controller?.select(.agents) }
            return
        }
        showModels(of: provider)
    }

    private func addModel(_ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addField.stringValue = ""
        var added = 0
        settings.updateAIProvider(id) { added = $0.mergeModels([value]) }
        notice = added == 0 ? text("That model ID is already listed, or is not valid.", "该模型 ID 已在列表中，或格式无效。") : nil
        if let provider = settings.aiProvider(id) { showModels(of: provider) }
    }

    private func fetchModels() {
        controller?.view.window?.makeFirstResponder(nil)
        guard fetchTask == nil, let provider = settings.aiProvider(id) else { return }
        let key = credentials.apiKey(for: id)
        let endpoint: AIEndpoint
        do {
            endpoint = try provider.listEndpoint(apiKey: key)
        } catch {
            notice = strings.aiBaseURLProblem(error as? AIEndpointError ?? .invalidURL)
            showModels(of: provider)
            return
        }
        fetchButton.isEnabled = false
        notice = text("Fetching models…", "正在获取模型…")
        showModels(of: provider)
        let client = client
        fetchTask = Task { @MainActor [weak self] in
            let result: Result<[String], Error>
            do {
                result = .success(try await client.models(endpoint: endpoint))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.fetchTask = nil
            self.fetchButton.isEnabled = true
            self.finishFetch(result, key: key)
        }
    }

    private func finishFetch(_ result: Result<[String], Error>, key: String?) {
        switch result {
        case .success(let models):
            var added = 0
            settings.updateAIProvider(id) { added = $0.mergeModels(models) }
            if models.isEmpty {
                notice = text("The service returned no models. Add model IDs by hand.", "服务未返回任何模型，请手动添加模型 ID。")
            } else if added == 0 {
                notice = text("Up to date: all \(models.count) models are already listed.",
                              "已是最新：返回的 \(models.count) 个模型均已在列表中。")
            } else {
                notice = text("Added \(added) of \(models.count) models.", "已添加 \(models.count) 个模型中的 \(added) 个。")
            }
        case .failure(let error):
            notice = fetchProblem(error, key: key)
        }
        if let provider = settings.aiProvider(id) { showModels(of: provider) }
    }

    /// Why the model list could not be loaded. The service's own words pass through
    /// the redactor with the key that was sent, so the key cannot come back in an error.
    private func fetchProblem(_ error: Error, key: String?) -> String {
        switch error {
        case AIHTTPError.invalidEndpoint(let reason):
            return strings.aiBaseURLProblem(reason)
        case AIHTTPError.httpStatus(let status, let detail):
            switch status {
            case 401, 403:
                return text("HTTP \(status). Check the API key.", "HTTP \(status)，请检查 API 密钥。")
            case 404, 405:
                return text("HTTP \(status). This service may not list its models: check the base URL, or add model IDs by hand.",
                            "HTTP \(status)。此服务可能不提供模型列表接口：请检查基础 URL，或手动添加模型 ID。")
            default:
                let words = detail.map { ": " + AISecretRedactor.redact($0, hiding: key) } ?? ""
                return "HTTP \(status)" + words
            }
        case AIHTTPError.redirected:
            return text("The service answered with a redirect, which OMG does not follow. Check the base URL.",
                        "服务返回了重定向，OMG 不会跟随。请检查基础 URL。")
        case AIHTTPError.responseTooLarge:
            return text("The model list is too large to read. Add model IDs by hand.", "模型列表过大，无法读取，请手动添加模型 ID。")
        case is AIHTTPError:
            return text("The service did not return a model list. Add model IDs by hand.", "服务未返回模型列表，请手动添加模型 ID。")
        case let error as URLError:
            return error.localizedDescription
        default:
            return text("The model list could not be loaded.", "无法加载模型列表。")
        }
    }
}
