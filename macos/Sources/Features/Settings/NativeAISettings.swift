import AppKit
import Combine

extension NativeSettingsController {
    /// The AI page: general-purpose Model Services (API + Local CLIs), Terminal Coding Agents,
    /// and Agent History. Feature-specific model assignments live on their owning pages
    /// (`Automatic Tab Titles` in `Views & Tabs`, `AI Commit & PR Messages` in `Git`).
    func aiOverview(_ form: NativeSettingsForm) {
        aiModelServicesSection(form)
        agentOverview(form)
    }

    // MARK: Unified Model Services (API + Local CLIs)

    private func aiModelServicesSection(_ form: NativeSettingsForm) {
        form.section(strings.aiProvidersSection, caption: strings.aiProvidersFootnote)

        for provider in settings.aiProviders {
            let id = provider.id
            let enabled = SettingsSwitch(value: provider.enabled) { [weak self] isOn in
                self?.settings.updateAIProvider(id) { $0.enabled = isOn }
            }
            enabled.setAccessibilityLabel(provider.name + " · " + text("Enabled", "启用"))
            let editButton = SettingsActionButton(text("Edit…", "编辑…")) { [weak self] in
                self?.presentAIProviderSheet(id: id)
            }
            editButton.setAccessibilityIdentifier("settings.ai.provider." + id.uuidString)
            let controls = NSStackView(views: [enabled, editButton])
            controls.spacing = 10
            let row = form.row(provider.name, subtitle: strings.aiProviderSummary(provider), control: controls)
            form.refreshers.append { [weak self, weak enabled] in
                guard let self, let latest = self.settings.aiProvider(id) else { return }
                enabled?.state = latest.enabled ? .on : .off
                row?.setSubtitle(self.strings.aiProviderSummary(latest))
            }
        }

        let addServiceButton = SettingsActionButton(strings.aiAddConnection) { [weak self] in
            self?.presentAIProviderSheet(id: nil)
        }
        addServiceButton.isEnabled = settings.aiProviders.count < AIProvider.maxProviders
        addServiceButton.setAccessibilityLabel(strings.aiAddConnectionHelp)
        addServiceButton.setAccessibilityIdentifier("settings.ai.provider.add")
        let addSubtitle = settings.aiProviders.isEmpty
            ? text("Connect an OpenAI-compatible or Anthropic endpoint for tab titles and Git messages.",
                   "连接 OpenAI 兼容或 Anthropic 接口，供标签页命名与 Git 信息生成通用调用。")
            : text("Connect another OpenAI-compatible or Anthropic API endpoint.",
                   "添加另一个 OpenAI 兼容或 Anthropic 接口。")
        form.row(strings.aiAddServiceLabel, subtitle: addSubtitle, control: addServiceButton)

        form.section(
            strings.aiInstalledGroup,
            caption: text(
                "Reuse your logged-in local CLIs for tab titles and Git messages without configuring API keys.",
                "直接复用本机已登录 CLI 的模型与认证用于标签页命名与 Git 信息生成，无需配置 API 密钥。"
            )
        )
        let snapshot = agents.snapshot(for: AgentIntegrationManager.localID)
        for agent in GitCommitAgent.allCases {
            let inspectButton = SettingsActionButton(text("Models…", "模型…")) { [weak self] in
                self?.presentAICLIProviderSheet(agent)
            }
            inspectButton.setAccessibilityIdentifier("settings.ai.agent." + agent.rawValue)
            let row = form.row(
                agent.title,
                subtitle: aiAgentSummary(agent, snapshot: snapshot),
                control: inspectButton
            )
            let token = aiAgentCatalog.$entries.receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                let latestSnapshot = self.agents.snapshot(for: AgentIntegrationManager.localID)
                row?.setSubtitle(self.aiAgentSummary(agent, snapshot: latestSnapshot))
            }
            form.retained.append(token)
        }
    }

    /// CLI state from the last Agent check, then the model count once known.
    func aiAgentSummary(_ agent: GitCommitAgent, snapshot: AgentIntegrationSnapshot?) -> String {
        let cli = SupportedAgent(rawValue: agent.rawValue).flatMap { snapshot?.cli[$0] }
        let version = cli?.displayVersion?.replacingOccurrences(
            of: " (" + agent.title + ")", with: "", options: .anchored)
        var parts = [
            text("Local CLI", "本机 CLI"),
            cli?.path == nil ? text("Not installed", "未安装") : (version ?? text("Installed", "已安装")),
        ]
        if let models = aiAgentCatalog.entry(agent).models {
            parts.append(strings.aiModelCount(models.count))
        }
        return parts.joined(separator: " · ")
    }

    func presentAIProviderSheet(id: UUID?) {
        if let id, settings.aiProvider(id) == nil { return }
        let isEditing = id != nil
        let heading = isEditing
            ? text("Edit API Service", "编辑 API 服务")
            : text("Add API Service", "添加 API 服务")
        let sheet = AIProviderSheetController(
            controller: self,
            providerID: id
        ) { [weak self] in
            guard let self else { return }
            self.select(self.selection)
        }
        presentModalSheet(sheet, title: heading, size: NSSize(width: 600, height: isEditing ? 620 : 580))
    }

    func presentAICLIProviderSheet(_ agent: GitCommitAgent) {
        let sheet = AICLIProviderSheetController(controller: self, agent: agent)
        presentModalSheet(sheet, title: agent.title, size: NSSize(width: 560, height: 540))
    }

    func presentCommitPromptSheet() {
        let title = GitL10n.text("Custom commit prompt")
        let sheet = GitCommitAIPromptController(prompt: settings.gitCommitAIPrompt) { [weak settings] in
            settings?.gitCommitAIPrompt = $0
        }
        presentModalSheet(sheet, title: title, size: NSSize(width: 560, height: 440))
    }

    // MARK: Automatic Tab Titles (owned by Views & Tabs)

    func aiTitleSection(_ form: NativeSettingsForm) {
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
                catalog: self.aiAgentCatalog,
                from: self
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

    // MARK: Git Commit & PR Messages (owned by Git)

    func aiCommitSection(_ form: NativeSettingsForm) {
        form.section(strings.aiTaskModelsSection)
        let addModels = SettingsActionButton(strings.aiAddModels) { [weak self] in
            guard let self else { return }
            GitCommitAISettingsPanel.presentUnifiedAddModels(
                settings: self.settings,
                catalog: self.aiAgentCatalog,
                from: self
            )
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
                ? copy.t("No models yet. Add models from your API services or local CLIs.",
                         "尚未添加模型。可从 API 服务或本机 CLI 添加生成模型。")
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
            self?.presentCommitPromptSheet()
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
        switch route.target {
        case .agent(let agent):
            return "\(agent.title) · \(route.model)"
        case .provider(let providerID):
            guard let provider = settings.aiProvider(providerID) else {
                return text("\(route.model): its API service was removed. Choose another model.",
                            "\(route.model)：所属的 API 服务已被移除，请重新选择模型。")
            }
            let name = provider.name + " · " + route.model
            return provider.enabled ? name
                : text("\(name): the service is turned off, so no titles are generated.",
                       "\(name)：该服务已停用，不会生成标题。")
        }
    }
}

/// Modal sheet for inspecting a local CLI's discovered models and Codex ACP helper state.
@MainActor
final class AICLIProviderSheetController: GitCommitSettingsPanelController {
    private weak var settingsController: NativeSettingsController?
    let agent: GitCommitAgent
    private let catalog: AIAgentModelCatalog
    private let strings: SettingsStrings
    let list: AIModelListController
    let refreshButton = SettingsActionButton("") {}
    let adapterButton = SettingsActionButton("") {}
    private var modelsRow: NativeSettingsRow?
    private var filterRow: NativeSettingsRow?
    private var adapterRow: NativeSettingsRow?
    private var listHeight: NSLayoutConstraint?
    private var listSeparator: NSView?
    private var adapterUpdate: GitACPAdapterUpdateInfo?
    private var adapterTask: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(controller: NativeSettingsController, agent: GitCommitAgent) {
        self.settingsController = controller
        self.agent = agent
        self.catalog = controller.aiAgentCatalog
        self.strings = controller.strings
        self.list = AIModelListController(editable: false, strings: controller.strings)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { adapterTask?.cancel() }

    private func text(_ en: String, _ zh: String) -> String { strings.t(en, zh) }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: agent.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let form = NativeSettingsForm(contentInsets: NSEdgeInsets(top: 6, left: 4, bottom: 8, right: 4))
        if let palette = settingsController?.currentPalette {
            form.applyPalette(palette)
        }
        addChild(form)
        form.section(text("Local CLI", "本机 CLI"))
        let cli = SupportedAgent(rawValue: agent.rawValue).flatMap {
            settingsController?.agents.snapshot(for: AgentIntegrationManager.localID)?.cli[$0]
        }
        form.row(
            text("Command line tool", "命令行工具"),
            subtitle: cli?.path ?? text("Not detected by the last Agent check.", "上次检查未发现此命令行工具。"),
            control: NSTextField(labelWithString: cli?.displayVersion ?? "—")
        )
        form.row(
            text("Local helper command", "本机调用命令"),
            subtitle: text("Reuses this CLI's local login without an API key.", "直接复用该 CLI 的本机登录状态，无需配置 API 密钥。"),
            control: NSTextField(labelWithString: agent.acpCommand.joined(separator: " "))
        )
        if agent == .codex {
            adapterButton.invoke = { [weak self] in self?.adapterAction() }
            adapterButton.setAccessibilityIdentifier("settings.ai.agent.codex.adapter-update")
            adapterRow = form.row(text("Codex helper package", "Codex 桥接组件"), control: adapterButton)
            refreshAdapter(failure: nil)
        }

        form.section(text("Available Models", "可用模型"))
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

        let doneButton = NSButton(title: text("Done", "完成"), target: self, action: #selector(closeSheet))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityIdentifier("settings.ai.agent.done")
        let actions = NSStackView(views: [NSView(), doneButton])
        actions.orientation = .horizontal

        let formView = form.view
        let stack = NSStackView(views: [title, formView, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            formView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root

        sync()
        subscription = catalog.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }
        if catalog.entry(agent).models == nil, !catalog.entry(agent).isLoading {
            catalog.refresh(agent)
        }
    }

    @objc private func closeSheet() {
        adapterTask?.cancel()
        closePanel()
    }

    override func didEndSheet() {
        adapterTask?.cancel()
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
            status = text("No models found. Make sure the CLI and helper command are installed and logged in.",
                          "未发现模型，请确认该 CLI 与本机调用命令已安装并完成登录。")
        } else {
            let checked = entry.checkedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            status = strings.aiModelCount(models.count) + checked
        }
        modelsRow?.setSubtitle(status)
    }

    private func adapterAction() {
        guard adapterTask == nil else { return }
        guard let update = adapterUpdate, update.updateAvailable else {
            checkAdapter()
            return
        }
        installAdapter(update.latestVersion)
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

/// Modal sheet for creating or editing an API service without polluting `settings.aiProviders`
/// until the user confirms with Save / Add.
@MainActor
final class AIProviderSheetController: GitCommitSettingsPanelController {
    private weak var settingsController: NativeSettingsController?
    private let settings: OhMyGhosttySettings
    private let credentials: AICredentialStore
    private let client: AIHTTPClient
    private let strings: SettingsStrings
    let existingID: UUID?
    private let onSavedOrRemoved: () -> Void

    private(set) var draft: AIProvider
    private var pendingKey: String?
    private var clearedExistingKey = false

    let list: AIModelListController
    let nameField = SettingsTextField("") { _ in }
    let kindPopup: SettingsPopup
    let urlField = SettingsTextField("") { _ in }
    let keyField = SettingsSecureField("") { _ in }
    let clearKeyButton = SettingsActionButton("") {}
    let enabledSwitch: SettingsSwitch
    let fetchButton = SettingsActionButton("") {}
    let addField = SettingsTextField("", placeholder: "model-id") { _ in }
    let addButton = SettingsActionButton("") {}
    let removeButton = SettingsActionButton("") {}
    let cancelButton = NSButton()
    let saveButton = NSButton()

    private var urlRow: NativeSettingsRow?
    private var keyRow: NativeSettingsRow?
    private var modelsRow: NativeSettingsRow?
    private var filterRow: NativeSettingsRow?
    private var listHeight: NSLayoutConstraint?
    private var listSeparator: NSView?
    private var notice: String?
    private var fetchTask: Task<Void, Never>?

    init(
        controller: NativeSettingsController,
        providerID: UUID?,
        onSavedOrRemoved: @escaping () -> Void = {}
    ) {
        self.settingsController = controller
        self.settings = controller.settings
        self.credentials = controller.aiCredentials
        self.client = controller.aiHTTPClient
        self.strings = controller.strings
        self.existingID = providerID
        self.onSavedOrRemoved = onSavedOrRemoved
        let current = providerID.flatMap { controller.settings.aiProvider($0) }
            ?? AIProvider(name: "")
        self.draft = current
        self.list = AIModelListController(editable: true, strings: controller.strings)
        let kinds = AIEndpointProtocol.allCases
        self.kindPopup = SettingsPopup(
            titles: kinds.map { controller.strings.aiProviderKindTitle($0) },
            selected: kinds.firstIndex(of: current.kind) ?? 0
        ) { _ in }
        self.enabledSwitch = SettingsSwitch(value: current.enabled) { _ in }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { fetchTask?.cancel() }

    private func text(_ en: String, _ zh: String) -> String { strings.t(en, zh) }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let heading = existingID == nil
            ? text("Add API Service", "添加 API 服务")
            : text("Edit API Service", "编辑 API 服务")
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let form = NativeSettingsForm(contentInsets: NSEdgeInsets(top: 6, left: 4, bottom: 8, right: 4))
        if let palette = settingsController?.currentPalette {
            form.applyPalette(palette)
        }
        addChild(form)
        buildConnectionSection(in: form)
        buildModelsSection(in: form)

        removeButton.title = text("Remove Service…", "移除服务…")
        removeButton.invoke = { [weak self] in self?.requestRemoval() }
        removeButton.isHidden = existingID == nil
        removeButton.setAccessibilityIdentifier("settings.ai.provider.remove")

        cancelButton.title = text("Cancel", "取消")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.setAccessibilityIdentifier("settings.ai.provider.cancel")

        saveButton.title = existingID == nil ? text("Add", "添加") : text("Save", "保存")
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("settings.ai.provider.save")

        let actions = NSStackView(views: [removeButton, NSView(), cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let formView = form.view
        let stack = NSStackView(views: [title, formView, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            formView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    private func buildConnectionSection(in form: NativeSettingsForm) {
        form.section(text("Service Endpoint", "服务连接"))
        nameField.stringValue = draft.name
        nameField.placeholderString = text("e.g. OpenAI / Anthropic / Proxy", "例如 OpenAI / Anthropic / 公司代理")
        nameField.commit = { [weak self] in self?.updateDraftName($0) }
        nameField.setAccessibilityIdentifier("settings.ai.provider.name")
        form.row(text("Name", "名称"), control: nameField)

        let kinds = AIEndpointProtocol.allCases
        kindPopup.change = { [weak self] index in
            guard let self, kinds.indices.contains(index) else { return }
            self.draft.kind = kinds[index]
            self.urlField.placeholderString = SettingsStrings.aiBaseURLPlaceholder(kinds[index])
        }
        kindPopup.setAccessibilityIdentifier("settings.ai.provider.kind")
        form.row(text("Protocol", "接口协议"), control: kindPopup)

        urlField.stringValue = draft.baseURL
        urlField.placeholderString = SettingsStrings.aiBaseURLPlaceholder(draft.kind)
        urlField.commit = { [weak self] in _ = self?.validateAndStageURL($0) }
        urlField.setAccessibilityIdentifier("settings.ai.provider.base-url")
        urlRow = form.row(text("Base URL", "基础 URL"), control: urlField)

        keyField.commit = { [weak self] in self?.stageKey($0) }
        keyField.setAccessibilityLabel(text("API key", "API 密钥"))
        keyField.setAccessibilityIdentifier("settings.ai.provider.api-key")
        clearKeyButton.title = text("Clear", "清除")
        clearKeyButton.invoke = { [weak self] in self?.clearStagedOrStoredKey() }
        clearKeyButton.setAccessibilityIdentifier("settings.ai.provider.clear-api-key")
        let keyControls = NSStackView(views: [keyField, clearKeyButton])
        keyControls.spacing = 8
        keyRow = form.row(text("API key", "API 密钥"), control: keyControls)
        refreshKeyStatus(problem: nil)

        enabledSwitch.change = { [weak self] value in self?.draft.enabled = value }
        enabledSwitch.setAccessibilityIdentifier("settings.ai.provider.enabled")
        form.row(
            text("Enabled", "启用"),
            control: enabledSwitch,
            help: text("When off, tasks skip this service's models.", "停用后，各功能会跳过此服务的模型。")
        )
    }

    private func buildModelsSection(in form: NativeSettingsForm) {
        form.section(
            text("Models", "模型"),
            caption: text(
                "Token limits accept values like 128k. Drag or use arrows to adjust display order.",
                "Token 上限支持填写如 128k；可拖动或用箭头调整模型排列顺序。"
            )
        )
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
            self.view.window?.makeFirstResponder(nil)
            self.addModel(self.addField.stringValue)
        }
        addButton.setAccessibilityIdentifier("settings.ai.provider.add-model")
        let addControls = NSStackView(views: [addField, addButton])
        addControls.spacing = 8
        form.row(
            text("Add a model ID", "手动添加模型 ID"),
            control: addControls,
            help: text("For services that do not expose a /models endpoint.", "适用于不提供模型列表查询接口的服务。")
        )

        form.addChild(list)
        _ = list.view
        filterRow = form.row(text("Filter", "筛选"), control: list.filterField)
        listHeight = form.embed(list.view, height: 0)
        listSeparator = form.embedSeparator
        list.onHeightChange = { [weak self] in self?.applyListHeight($0) }
        list.onChange = { [weak self] updated in
            guard let self, let index = self.draft.models.firstIndex(where: { $0.id == updated.id }) else { return }
            self.draft.models[index] = updated
        }
        list.onReorder = { [weak self] reordered in
            self?.draft.models = reordered
        }
        list.onRemove = { [weak self] modelID in
            guard let self else { return }
            self.notice = nil
            self.draft.models.removeAll { $0.id == modelID }
            self.showDraftModels()
        }
        showDraftModels()
    }

    private var hasEffectiveKey: Bool {
        if let pendingKey, !pendingKey.isEmpty { return true }
        if clearedExistingKey { return false }
        return existingID.map { credentials.hasAPIKey(for: $0) } ?? false
    }

    private var effectiveKeyValue: String? {
        if let pendingKey, !pendingKey.isEmpty { return pendingKey }
        if clearedExistingKey { return nil }
        return existingID.flatMap { credentials.apiKey(for: $0) }
    }

    private func updateDraftName(_ raw: String) {
        let normalized = AIProvider.normalizedName(raw)
        draft.name = normalized
        nameField.stringValue = normalized
    }

    @discardableResult
    private func validateAndStageURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draft.baseURL = ""
            urlRow?.setSubtitle("")
            return true
        }
        do {
            let normalized = try AIEndpoint.validatedBaseURL(trimmed).absoluteString
            draft.baseURL = normalized
            urlField.stringValue = normalized
            urlRow?.setSubtitle("")
            return true
        } catch {
            urlRow?.setSubtitle(strings.aiBaseURLProblem(error as? AIEndpointError ?? .invalidURL))
            return false
        }
    }

    private func stageKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingKey = trimmed
        clearedExistingKey = false
        keyField.stringValue = ""
        refreshKeyStatus(problem: nil)
    }

    private func clearStagedOrStoredKey() {
        keyField.stringValue = ""
        pendingKey = nil
        clearedExistingKey = true
        refreshKeyStatus(problem: nil)
    }

    private func refreshKeyStatus(problem: String?) {
        let stored = hasEffectiveKey
        keyField.placeholderString = stored ? text("Stored. Type to replace.", "已保存，输入可替换") : "sk-…"
        clearKeyButton.isEnabled = stored
        keyRow?.setSubtitle(problem ?? (stored
            ? text("Stored in a private file on this Mac, outside settings.json.",
                   "保存在本机独立私有文件中，不写入 settings.json。")
            : text("Not set. Requests are sent without authentication.", "未设置，请求将不带认证信息。")))
    }

    private func applyListHeight(_ height: CGFloat) {
        listHeight?.constant = height
        list.view.isHidden = height == 0
        listSeparator?.isHidden = height == 0
    }

    private func showDraftModels() {
        list.setModels(draft.models)
        applyListHeight(list.preferredHeight)
        filterRow?.setVisible(draft.models.count > AIModelListController.filterThreshold)
        modelsRow?.setSubtitle(notice ?? (draft.models.isEmpty
            ? text("No models yet. Fetch the list, or add model IDs by hand.", "尚无模型。可点击获取模型，或手动添加模型 ID。")
            : strings.aiModelCount(draft.models.count)))
    }

    private func addModel(_ raw: String) {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addField.stringValue = ""
        let added = draft.mergeModels([raw])
        notice = added == 0
            ? text("That model ID is already listed, or is not valid.", "该模型 ID 已在列表中，或格式无效。")
            : nil
        showDraftModels()
    }

    func fetchModels() {
        view.window?.makeFirstResponder(nil)
        if !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stageKey(keyField.stringValue)
        }
        guard validateAndStageURL(urlField.stringValue), fetchTask == nil else { return }
        let key = effectiveKeyValue
        let endpoint: AIEndpoint
        do {
            endpoint = try draft.listEndpoint(apiKey: key)
        } catch {
            notice = strings.aiBaseURLProblem(error as? AIEndpointError ?? .invalidURL)
            showDraftModels()
            return
        }
        fetchButton.isEnabled = false
        notice = text("Fetching models…", "正在获取模型…")
        showDraftModels()
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
        case .success(let ids):
            let added = draft.mergeModels(ids)
            notice = ids.isEmpty
                ? text("The service returned an empty model list.", "该服务返回了空的模型列表。")
                : (added == 0
                    ? text("All \(ids.count) returned models are already listed.",
                           "接口返回的 \(ids.count) 个模型均已在列表中。")
                    : nil)
        case .failure(let error as AIHTTPError):
            notice = describe(error, hiding: key)
        case .failure(let error):
            notice = AISecretRedactor.redact(error.localizedDescription, hiding: key)
        }
        showDraftModels()
    }

    private func describe(_ error: AIHTTPError, hiding key: String?) -> String {
        switch error {
        case .httpStatus(let code, let detail?):
            return "HTTP \(code): " + AISecretRedactor.redact(detail, hiding: key)
        case .httpStatus(let code, nil):
            return "HTTP \(code)"
        case .invalidEndpoint(let endpointError):
            return strings.aiBaseURLProblem(endpointError)
        case .redirected, .responseTooLarge, .malformedResponse, .truncatedOutput, .emptyOutput:
            return AISecretRedactor.redact(error.localizedDescription, hiding: key)
        }
    }

    @objc func cancel() {
        fetchTask?.cancel()
        closePanel()
    }

    override func didEndSheet() {
        fetchTask?.cancel()
    }

    @objc func save() {
        view.window?.makeFirstResponder(nil)
        if !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stageKey(keyField.stringValue)
        }
        guard validateAndStageURL(urlField.stringValue) else { return }
        if existingID == nil, settings.aiProviders.count >= AIProvider.maxProviders { return }
        let typedName = AIProvider.normalizedName(nameField.stringValue)
        draft.name = typedName.isEmpty ? AIProvider.suggestedName(baseURL: draft.baseURL) : typedName

        let targetID = existingID ?? draft.id
        do {
            if let pendingKey, !pendingKey.isEmpty {
                try credentials.setAPIKey(pendingKey, for: targetID)
            } else if clearedExistingKey {
                try credentials.removeAPIKey(for: targetID)
            }
        } catch {
            refreshKeyStatus(problem: text("The API key could not be saved.", "无法保存 API 密钥。"))
            return
        }

        if let existingID {
            let previousIDs = Set(settings.aiProvider(existingID)?.models.map(\.id) ?? [])
            let remainingIDs = Set(draft.models.map(\.id))
            for removedModel in previousIDs.subtracting(remainingIDs) {
                settings.removeAIProviderModel(removedModel, from: existingID)
            }
            if let route = settings.aiTitleRoute,
               route.provider == existingID,
               !remainingIDs.contains(route.model) {
                settings.aiTitleRoute = nil
            }
            settings.gitCommitAIRoutes.removeAll { route in
                route.target == .provider(existingID) && !remainingIDs.contains(route.model)
            }
            settings.updateAIProvider(existingID) { provider in
                provider.name = draft.name
                provider.kind = draft.kind
                provider.baseURL = draft.baseURL
                provider.enabled = draft.enabled
                provider.models = draft.models
            }
        } else {
            settings.aiProviders.append(draft)
        }

        fetchTask?.cancel()
        closePanel()
        onSavedOrRemoved()
    }

    private func requestRemoval() {
        guard existingID != nil else { return }
        guard let window = view.window else {
            deleteProviderConfirmed()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text("Remove \(draft.name)?", "移除 \(draft.name)？")
        alert.informativeText = text(
            "Its stored API key is deleted, and its models are removed from Git messages and tab titles.",
            "已保存的 API 密钥会被删除，其模型也会从 Git 信息和标签标题的选择中移除。"
        )
        alert.addButton(withTitle: text("Remove", "移除"))
        alert.addButton(withTitle: text("Cancel", "取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.deleteProviderConfirmed()
            }
        }
    }

    func deleteProviderConfirmed() {
        guard let existingID else { return }
        fetchTask?.cancel()
        var failure: Error?
        do {
            try settings.removeAIProvider(existingID, credentials: credentials)
        } catch {
            failure = error
        }
        closePanel()
        onSavedOrRemoved()
        if let failure { settingsController?.showError(failure) }
    }
}
