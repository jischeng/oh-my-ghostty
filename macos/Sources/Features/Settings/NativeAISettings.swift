import AppKit
import Combine

extension NativeSettingsController {
    /// The AI page: providers, the model for each task, then Agent integration.
    func aiOverview(_ form: NativeSettingsForm) {
        aiProviderList(form)
        aiTaskModels(form)
        agentOverview(form)
    }

    // MARK: Providers

    private func aiProviderList(_ form: NativeSettingsForm) {
        form.section(strings.aiProvidersSection, caption: strings.aiProvidersCaption)
        form.addCustomRow(aiGroupHeader(strings.aiInstalledGroup))
        let snapshot = agents.snapshot(for: AgentIntegrationManager.localID)
        for agent in GitCommitAgent.allCases {
            let link = form.link(agent.title, subtitle: aiAgentSummary(agent, snapshot: snapshot)) { [weak self] in
                self?.showAIAgent(agent)
            }
            link?.setAccessibilityIdentifier("settings.ai.agent." + agent.rawValue)
        }
        form.addCustomRow(aiGroupHeader(strings.aiConnectionsGroup))
        for provider in settings.aiProviders {
            let id = provider.id
            let link = form.link(provider.name, subtitle: strings.aiProviderSummary(provider)) { [weak self] in
                self?.showAIProvider(id)
            }
            link?.setAccessibilityIdentifier("settings.ai.provider." + id.uuidString)
        }
        let add = SettingsActionButton(text("Add…", "添加…")) { [weak self] in
            guard let self, let provider = self.settings.addAIProvider(name: self.strings.aiNewConnectionName) else {
                return
            }
            self.showAIProvider(provider.id)
        }
        add.isEnabled = settings.aiProviders.count < AIProvider.maxProviders
        add.setAccessibilityIdentifier("settings.ai.provider.add")
        form.row(text("Add an API connection", "添加 API 连接"),
                 subtitle: text("Any OpenAI-compatible or Anthropic endpoint, including a local server.",
                                "任意 OpenAI 兼容或 Anthropic 端点，包括本地服务。"),
                 control: add)
    }

    /// Small caption that splits one settings group into named parts.
    private func aiGroupHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ])
        return header
    }

    /// CLI state from the last Agent check and the number of models last discovered.
    private func aiAgentSummary(_ agent: GitCommitAgent, snapshot: AgentIntegrationSnapshot?) -> String {
        var parts: [String] = []
        if let cli = SupportedAgent(rawValue: agent.rawValue).flatMap({ snapshot?.cli[$0] }) {
            parts.append(cli.path == nil ? text("CLI not detected", "未发现 CLI")
                         : cli.displayVersion ?? text("Installed", "已安装"))
        }
        if let models = aiAgentCatalog.entry(agent).models {
            parts.append(strings.aiModelCount(models.count))
        } else {
            parts.append(text("Models not loaded yet", "尚未加载模型"))
        }
        return parts.joined(separator: " · ")
    }

    func showAIAgent(_ agent: GitCommitAgent) {
        push(agent.title, route: "ai-agent:" + agent.rawValue,
             previous: { [weak self] in self?.select(.agents) },
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
             previous: { [weak self] in self?.select(.agents) },
             build: { [weak self] form in
                 guard let self else { return }
                 let page = AIProviderPage(controller: self, provider: id, route: route)
                 page.build(in: form)
                 form.retained.append(page)
             })
    }

    // MARK: Models per task

    private func aiTaskModels(_ form: NativeSettingsForm) {
        form.section(strings.aiTaskModelsSection)
        form.addCustomRow(aiGroupHeader(strings.aiCommitModelsGroup))
        let addAgentModels = SettingsActionButton(text("Add Agent Models…", "添加 Agent 模型…")) { [weak self] in
            guard let self else { return }
            GitCommitAISettingsPanel.presentAddModels(settings: self.settings, from: self.view.window)
        }
        addAgentModels.setAccessibilityIdentifier("settings.ai.commit.add-agent-models")
        let addAPIModels = SettingsActionButton(text("Add API Models…", "添加 API 模型…")) { [weak self] in
            guard let self else { return }
            GitCommitAISettingsPanel.presentAddProviderModels(settings: self.settings, from: self.view.window)
        }
        addAPIModels.setAccessibilityIdentifier("settings.ai.commit.add-api-models")
        let addButtons = NSStackView(views: [addAgentModels, addAPIModels])
        addButtons.spacing = 8
        let models = form.row(text("Models", "模型"), control: addButtons)
        let coordinator = GitCommitAIRoutesTable.Coordinator(settings: settings)
        let routes = GitCommitAIRoutesTable.makeNativeView(coordinator: coordinator)
        routes.hasVerticalScroller = false
        form.retained.append(coordinator)
        // The list grows with its rows; the page is the only scroll area.
        let height = form.embed(routes, height: 0)
        let copy = strings
        let divider = form.embedSeparator
        let update: ([GitCommitAIRoute]) -> Void = { [weak coordinator, weak routes, weak divider] list in
            divider?.isHidden = list.isEmpty
            coordinator?.tableView?.reloadData()
            height?.constant = CGFloat(list.count) * GitCommitAIRoutesTable.rowHeight
            routes?.isHidden = list.isEmpty
            models?.setSubtitle(list.isEmpty
                ? copy.t("No models yet. Add one to generate commit, tag and PR messages.",
                         "尚未添加模型。添加后即可生成提交、标签与 PR 信息。")
                : copy.t("Tried from top to bottom. Drag or use the arrows to reorder.",
                         "按从上到下的顺序尝试，可拖动或用箭头调整。"))
        }
        update(settings.gitCommitAIRoutes)
        // Delivered after the change, so read the settings instead of a value that may be stale by now.
        form.retained.append(settings.$gitCommitAIRoutes.receive(on: RunLoop.main).sink { [weak settings] _ in
            if let settings { update(settings.gitCommitAIRoutes) }
        })
        // A route shows its connection's name and state, so follow the connections too.
        form.retained.append(settings.$aiProviders.receive(on: RunLoop.main).sink { [weak coordinator] _ in
            coordinator?.tableView?.reloadData()
        })

        form.addCustomRow(aiGroupHeader(strings.aiTitleModelGroup))
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

        let choose = SettingsActionButton(text("Choose…", "选择…")) { [weak self] in
            guard let self else { return }
            GitCommitAISettingsPanel.presentTitleModel(settings: self.settings, from: self.view.window)
        }
        choose.setAccessibilityIdentifier("settings.ai.title.choose-model")
        let clear = SettingsActionButton(text("Clear", "清除")) { [weak settings] in settings?.aiTitleRoute = nil }
        clear.setAccessibilityIdentifier("settings.ai.title.clear-model")
        let titleButtons = NSStackView(views: [choose, clear])
        titleButtons.spacing = 8
        let titleModel = form.row(strings.aiTitleModelLabel, subtitle: aiTitleModelSummary(), control: titleButtons)
        let syncTitleModel = { [weak self, weak clear, weak titlePopup] in
            guard let self else { return }
            titleModel?.setSubtitle(self.aiTitleModelSummary())
            clear?.isEnabled = self.settings.aiTitleRoute != nil
            titlePopup?.selectItem(at: titleModes.firstIndex(of: self.settings.agentSessionTitleMode) ?? 0)
        }
        syncTitleModel()
        form.refreshers.append(syncTitleModel)
    }

    /// The chosen title model, or why no title will be generated.
    func aiTitleModelSummary() -> String {
        guard let route = settings.aiTitleRoute else { return strings.aiTitleModelUnset }
        guard let provider = settings.aiProvider(route.provider) else {
            return text("\(route.model): its API connection was removed. Choose another model.",
                        "\(route.model)：所属的 API 连接已被移除，请重新选择模型。")
        }
        let name = provider.name + " · " + route.model
        return provider.enabled ? name
            : text("\(name): the connection is turned off, so no titles are generated.",
                   "\(name)：该连接已停用，不会生成标题。")
    }
}

/// Detail page of an installed agent: how it is reached and the models it advertises.
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
                 subtitle: cli?.path ?? text("Not detected by the last Agent check.", "上次 Agent 检查未发现。"),
                 control: NSTextField(labelWithString: cli?.displayVersion ?? "—"))
        form.row(text("ACP adapter", "ACP 适配器"),
                 subtitle: text("Models run through this local command, with the agent's own login.",
                                "模型通过这条本机命令运行，使用该 Agent 自己的登录状态。"),
                 control: NSTextField(labelWithString: agent.acpCommand.joined(separator: " ")))
        if agent == .codex {
            adapterButton.invoke = { [weak self] in self?.adapterAction() }
            adapterButton.setAccessibilityIdentifier("settings.ai.agent.codex.adapter-update")
            adapterRow = form.row(text("Codex ACP version", "Codex ACP 版本"), control: adapterButton)
            refreshAdapter(failure: nil)
        }

        form.section(text("Models", "模型"),
                     caption: text("Discovered through a short ACP session on this Mac. Choose which ones a task uses under Models per Task.",
                                   "通过本机的一次短暂 ACP 会话发现。在“任务模型”中选择任务要使用的模型。"))
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
        // Delivered after the change, so `sync` reads the catalog as it is by then.
        subscription = catalog.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }
        // Opening the page is the request to look: the first visit loads the models.
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
            status = text("No models found. Check the local ACP adapter and the agent's login.",
                          "未发现模型，请检查本机 ACP 适配器和该 Agent 的登录状态。")
        } else {
            let checked = entry.checkedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            status = strings.aiModelCount(models.count) + checked
        }
        modelsRow?.setSubtitle(status)
    }

    // MARK: Codex ACP adapter

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
        adapterRow?.setSubtitle(text("Installing Codex ACP \(version)…", "正在安装 Codex ACP \(version)…"))
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
                "OMG can install a private copy of the adapter; a global npm install is left alone.",
                "OMG 可安装一份私有的适配器副本，不会改动全局 npm 安装。"
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

    private var urlHint: String {
        text("The root of the API, such as https://api.openai.com or http://localhost:11434/v1.",
             "API 的根地址，例如 https://api.openai.com 或 http://localhost:11434/v1。")
    }

    func build(in form: NativeSettingsForm) {
        guard let provider = settings.aiProvider(id) else { return }
        buildConnection(provider, in: form)
        buildModels(provider, in: form)

        form.section(text("Manage", "管理"))
        let remove = SettingsActionButton(text("Remove…", "移除…")) { [weak self] in self?.confirmRemoval() }
        remove.setAccessibilityIdentifier("settings.ai.provider.remove")
        form.row(text("Remove this connection", "移除此连接"),
                 subtitle: text("Also deletes its stored API key and the model choices that use it.",
                                "同时删除已保存的 API 密钥，以及使用它的模型选择。"),
                 control: remove)

        // Delivered after the change, so `sync` reads the settings as they are by then.
        subscription = settings.$aiProviders.receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }
    }

    private func buildConnection(_ provider: AIProvider, in form: NativeSettingsForm) {
        form.section(text("Connection", "连接"))
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
        form.row(text("Kind", "类型"), control: kind)

        urlField.stringValue = provider.baseURL
        urlField.placeholderString = SettingsStrings.aiBaseURLPlaceholder(provider.kind)
        urlField.commit = { [weak self] in self?.commitURL($0) }
        urlField.setAccessibilityIdentifier("settings.ai.provider.base-url")
        urlRow = form.row(text("Base URL", "基础 URL"), subtitle: urlHint, control: urlField)

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
        form.row(text("Enabled", "启用"),
                 subtitle: text("When off, tasks skip this connection's models.", "停用后，各任务会跳过此连接的模型。"),
                 control: enabled)
    }

    private func buildModels(_ provider: AIProvider, in form: NativeSettingsForm) {
        form.section(text("Models", "模型"),
                     caption: text("Limits are in tokens; 128k and 200,000 are accepted. Leave a limit blank for the default: OMG asks for up to 1,024 output tokens for a tab title and 4,096 for a Git message, and checks the prompt size only when a context window is set.",
                                   "限制以 token 为单位，可输入 128k 或 200,000。留空则使用默认值：OMG 为标签标题最多请求 1,024 个输出 token，为 Git 信息最多请求 4,096 个；仅在设置了上下文窗口时才检查提示词大小。"))
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
            // Ending the edit commits the field, which adds the model.
            self.controller?.view.window?.makeFirstResponder(nil)
            self.addModel(self.addField.stringValue)
        }
        addButton.setAccessibilityIdentifier("settings.ai.provider.add-model")
        let addControls = NSStackView(views: [addField, addButton])
        addControls.spacing = 8
        form.row(text("Add a model ID", "手动添加模型 ID"),
                 subtitle: text("For services that do not list their models.", "适用于不提供模型列表的服务。"),
                 control: addControls)

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
            urlRow?.setSubtitle(urlHint)
            return
        }
        do {
            let normalized = try AIEndpoint.validatedBaseURL(trimmed).absoluteString
            settings.updateAIProvider(id) { $0.baseURL = normalized }
            urlField.stringValue = normalized
            urlRow?.setSubtitle(urlHint)
        } catch {
            // The stored URL stays as it was; the row says what to fix.
            urlRow?.setSubtitle(strings.aiBaseURLProblem(error as? AIEndpointError ?? .invalidURL))
        }
    }

    private func commitKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field means "no change": the stored key is never shown here.
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
            ? text("No models yet. Fetch the list, or add model IDs by hand.", "尚无模型。可获取列表，或手动添加模型 ID。")
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
        notice = added == 0 ? text("That model ID is already listed, or is not valid.", "该模型 ID 已在列表中，或无效。") : nil
        if let provider = settings.aiProvider(id) { showModels(of: provider) }
    }

    private func fetchModels() {
        // A key or URL still being typed must be saved before it is used.
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
                            "HTTP \(status)。此服务可能不提供模型列表：请检查基础 URL，或手动添加模型 ID。")
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
