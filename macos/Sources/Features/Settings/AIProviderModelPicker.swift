import AppKit
import Combine

/// Sheet that picks models of API services for a task: several for a fallback list
/// (preserving user selection order), or one for tab titles.
@MainActor
final class AIProviderModelPickerController: GitCommitSettingsPanelController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let providers: [AIProvider]
    private let allowsMultiple: Bool
    private let strings: SettingsStrings
    private let heading: String
    private let onAddProvider: (() -> Void)?
    private let done: (UUID, [String]) -> Void
    let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let searchField = NSSearchField()
    let modelTable = NSTableView()
    let addProviderButton = NSButton()
    let confirmButton = NSButton()
    private let tableScroll = NSScrollView()
    private let placeholderField = NSTextField(wrappingLabelWithString: "")
    private var providerIndex = 0
    private var query = ""
    private(set) var selected: [String] = []

    /// `providers` are the services offered: enabled ones that list at least one model.
    init(providers: [AIProvider], allowsMultiple: Bool, strings: SettingsStrings, heading: String,
         onAddProvider: (() -> Void)? = nil,
         done: @escaping (UUID, [String]) -> Void) {
        self.providers = providers
        self.allowsMultiple = allowsMultiple
        self.strings = strings
        self.heading = heading
        self.onAddProvider = onAddProvider
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Services a task can use right now.
    static func eligible(_ providers: [AIProvider]) -> [AIProvider] {
        providers.filter { $0.enabled && !$0.models.isEmpty }
    }

    private var provider: AIProvider? {
        providers.indices.contains(providerIndex) ? providers[providerIndex] : nil
    }

    private var visibleModels: [String] {
        (provider?.models.map(\.id) ?? []).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        // Built as menu items: `addItem(withTitle:)` would drop a service whose name repeats.
        let choices = NSMenu()
        for (index, provider) in providers.enumerated() {
            let item = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            item.tag = index
            choices.addItem(item)
        }
        providerPopup.menu = choices
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.isEnabled = providers.count > 1
        providerPopup.setAccessibilityLabel(strings.aiConnectionsGroup)
        providerPopup.setAccessibilityIdentifier("settings.ai.model-picker.provider")

        searchField.placeholderString = strings.t("Search models…", "搜索模型…")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(strings.t("Search models…", "搜索模型…"))
        searchField.setAccessibilityIdentifier("settings.ai.model-picker.search")

        let column = NSTableColumn(identifier: .init("model"))
        column.resizingMask = .autoresizingMask
        modelTable.addTableColumn(column)
        modelTable.headerView = nil
        modelTable.rowHeight = 30
        modelTable.intercellSpacing = .zero
        modelTable.style = .plain
        modelTable.backgroundColor = .clear
        modelTable.selectionHighlightStyle = .none
        modelTable.dataSource = self
        modelTable.delegate = self
        modelTable.setAccessibilityLabel(strings.t("Available models", "可用模型"))
        modelTable.setAccessibilityIdentifier("settings.ai.model-picker.models")
        tableScroll.documentView = modelTable
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        placeholderField.alignment = .center
        placeholderField.textColor = .secondaryLabelColor
        addProviderButton.title = strings.t("Add API Service…", "添加 API 服务…")
        addProviderButton.bezelStyle = .rounded
        addProviderButton.target = self
        addProviderButton.action = #selector(addProvider)
        addProviderButton.setAccessibilityIdentifier("settings.ai.model-picker.add-provider")
        let emptyStack = NSStackView(views: [placeholderField, addProviderButton])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 12
        emptyStack.translatesAutoresizingMaskIntoConstraints = false

        let listBody = NSView()
        listBody.addSubview(tableScroll)
        listBody.addSubview(emptyStack)
        let list = NSBox()
        list.boxType = .custom
        list.cornerRadius = 8
        list.borderWidth = 1
        list.borderColor = NSColor.labelColor.withAlphaComponent(0.14)
        list.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
        list.contentViewMargins = .zero
        list.contentView = listBody
        list.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: strings.t("Cancel", "取消"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.setAccessibilityIdentifier("settings.ai.model-picker.cancel")
        confirmButton.title = allowsMultiple ? strings.t("Add", "添加") : strings.t("Use This Model", "使用此模型")
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.keyEquivalent = "\r"
        confirmButton.setAccessibilityIdentifier("settings.ai.model-picker.confirm")
        let actions = NSStackView(views: [NSView(), cancelButton, confirmButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, providerPopup, searchField, list, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            providerPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.heightAnchor.constraint(equalToConstant: 300),
            tableScroll.leadingAnchor.constraint(equalTo: listBody.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: listBody.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: listBody.topAnchor, constant: 4),
            tableScroll.bottomAnchor.constraint(equalTo: listBody.bottomAnchor, constant: -4),
            emptyStack.centerXAnchor.constraint(equalTo: listBody.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: listBody.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: listBody.widthAnchor, constant: -48),
            placeholderField.widthAnchor.constraint(lessThanOrEqualTo: listBody.widthAnchor, constant: -48),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    private func refresh() {
        let message: String
        if providers.isEmpty {
            message = strings.t(
                "No API service has models yet. Add an API service and fetch or add its models.",
                "还没有可用模型的 API 服务。请先添加 API 服务，并获取或添加模型。"
            )
        } else {
            message = visibleModels.isEmpty ? strings.t("No matching models.", "没有匹配的模型。") : ""
        }
        placeholderField.stringValue = message
        placeholderField.isHidden = message.isEmpty
        addProviderButton.isHidden = !providers.isEmpty || onAddProvider == nil
        tableScroll.isHidden = !message.isEmpty
        searchField.isEnabled = !providers.isEmpty
        confirmButton.isEnabled = !selected.isEmpty
        modelTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleModels.indices.contains(row) else { return nil }
        let model = visibleModels[row]
        let identifier = NSUserInterfaceItemIdentifier("settings.ai.model-picker.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GitCommitAIModelCell
            ?? GitCommitAIModelCell()
        cell.identifier = identifier
        cell.configure(title: model, checked: selected.contains(model), row: row, target: self,
                       action: #selector(toggleModel(_:)))
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        query = searchField.stringValue
        refresh()
    }

    @objc private func providerChanged() {
        select(providerAt: providerPopup.selectedItem?.tag ?? 0)
    }

    /// Shows another service's models. A choice never spans two services.
    func select(providerAt index: Int) {
        guard providers.indices.contains(index), index != providerIndex else { return }
        providerIndex = index
        providerPopup.selectItem(at: index)
        selected = []
        refresh()
    }

    @objc private func toggleModel(_ sender: NSButton) {
        guard visibleModels.indices.contains(sender.tag) else { return }
        toggle(visibleModels[sender.tag])
    }

    /// Checks or unchecks a model. In single-choice mode the new choice replaces the old one.
    func toggle(_ model: String) {
        if let index = selected.firstIndex(of: model) {
            selected.remove(at: index)
        } else if allowsMultiple {
            selected.append(model)
        } else {
            selected = [model]
        }
        refresh()
    }

    @objc func addProvider() {
        guard let onAddProvider else { return }
        closePanel()
        onAddProvider()
    }

    @objc private func cancel() { closePanel() }

    @objc func confirm() {
        guard let provider, !selected.isEmpty else { return }
        let validIDs = Set(provider.models.map(\.id))
        done(provider.id, selected.filter { validIDs.contains($0) })
        closePanel()
    }
}

/// Unified modal sheet that picks models from BOTH API services AND Local CLIs
/// (`Codex`, `Claude Code`, `Pi`, `OpenCode`), sharing `AIAgentModelCatalog` and
/// preserving the exact order in which the user selects models.
@MainActor
final class AIUnifiedModelPickerController: GitCommitSettingsPanelController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Source: Equatable {
        case provider(AIProvider)
        case agent(GitCommitAgent)

        var target: GitCommitAIRoute.Target {
            switch self {
            case .provider(let provider): .provider(provider.id)
            case .agent(let agent): .agent(agent)
            }
        }
    }

    struct PickedModel: Equatable {
        let target: GitCommitAIRoute.Target
        let model: String
    }

    let sources: [Source]
    private let catalog: AIAgentModelCatalog
    private let strings: SettingsStrings
    private let heading: String
    private let onAddProvider: (() -> Void)?
    private let done: ([PickedModel]) -> Void
    let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let searchField = NSSearchField()
    let reloadButton = NSButton()
    let addProviderButton = NSButton()
    let modelTable = NSTableView()
    let confirmButton = NSButton()
    private let tableScroll = NSScrollView()
    private let spinner = NativeProgressIndicator()
    private let placeholderField = NSTextField(wrappingLabelWithString: "")
    private let selectionField = NSTextField(labelWithString: "")
    private var sourceIndex = 0
    private var query = ""
    private(set) var selected: [PickedModel] = []
    private var catalogSubscription: AnyCancellable?

    init(
        providers: [AIProvider],
        agents: [GitCommitAgent] = GitCommitAgent.allCases,
        catalog: AIAgentModelCatalog? = nil,
        strings: SettingsStrings,
        heading: String,
        onAddProvider: (() -> Void)? = nil,
        done: @escaping ([PickedModel]) -> Void
    ) {
        let eligibleProviders = AIProviderModelPickerController.eligible(providers)
        self.sources = eligibleProviders.map(Source.provider) + agents.map(Source.agent)
        self.catalog = catalog ?? .shared
        self.strings = strings
        self.heading = heading
        self.onAddProvider = onAddProvider
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var currentSource: Source? {
        sources.indices.contains(sourceIndex) ? sources[sourceIndex] : nil
    }

    private var currentModels: [String] {
        guard let currentSource else { return [] }
        switch currentSource {
        case .provider(let provider):
            return provider.models.map(\.id)
        case .agent(let agent):
            return catalog.entry(agent).models ?? []
        }
    }

    private var visibleModels: [String] {
        currentModels.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: strings.t(
            "Choose models from your API services or logged-in local CLIs. Selected models are added in the order you check them.",
            "可同时从 API 服务或本机已登录 CLI 选择模型；勾选顺序即为添加后的优先顺序。"
        ))
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor

        let menu = NSMenu()
        for (index, source) in sources.enumerated() {
            let label: String
            switch source {
            case .provider(let provider):
                label = strings.t("API · \(provider.name)", "API · \(provider.name)")
            case .agent(let agent):
                label = strings.t("Local CLI · \(agent.title)", "本机 CLI · \(agent.title)")
            }
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        sourcePopup.menu = menu
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.isEnabled = sources.count > 1
        sourcePopup.setAccessibilityLabel(strings.t("Model source", "模型来源"))
        sourcePopup.setAccessibilityIdentifier("settings.ai.unified-picker.source")

        addProviderButton.title = strings.t("New API Service…", "新建 API 服务…")
        addProviderButton.bezelStyle = .rounded
        addProviderButton.target = self
        addProviderButton.action = #selector(addProvider)
        addProviderButton.isHidden = onAddProvider == nil
        addProviderButton.setAccessibilityIdentifier("settings.ai.unified-picker.add-provider")

        let sourceRow = NSStackView(views: [sourcePopup, addProviderButton])
        sourceRow.orientation = .horizontal
        sourceRow.spacing = 8
        sourcePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addProviderButton.setContentHuggingPriority(.required, for: .horizontal)

        searchField.placeholderString = strings.t("Search models…", "搜索模型…")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(strings.t("Search models…", "搜索模型…"))
        searchField.setAccessibilityIdentifier("git.commit-ai.models.search")

        reloadButton.target = self
        reloadButton.action = #selector(reloadCurrentAgent)
        reloadButton.bezelStyle = .rounded
        reloadButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: strings.t("Reload", "刷新")
        )
        reloadButton.imagePosition = .imageOnly
        reloadButton.toolTip = strings.t("Reload CLI models", "刷新 CLI 模型列表")
        reloadButton.setAccessibilityIdentifier("git.commit-ai.models.reload")
        reloadButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let toolbar = NSStackView(views: [searchField, reloadButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8

        let column = NSTableColumn(identifier: .init("model"))
        column.resizingMask = .autoresizingMask
        modelTable.addTableColumn(column)
        modelTable.headerView = nil
        modelTable.rowHeight = 30
        modelTable.intercellSpacing = .zero
        modelTable.style = .plain
        modelTable.backgroundColor = .clear
        modelTable.selectionHighlightStyle = .none
        modelTable.dataSource = self
        modelTable.delegate = self
        modelTable.setAccessibilityIdentifier("settings.ai.unified-picker.models")
        tableScroll.documentView = modelTable
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        placeholderField.alignment = .center
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.maximumNumberOfLines = 5
        let placeholder = NSStackView(views: [spinner, placeholderField])
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 8
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let listBody = NSView()
        listBody.addSubview(tableScroll)
        listBody.addSubview(placeholder)
        let list = NSBox()
        list.boxType = .custom
        list.cornerRadius = 8
        list.borderWidth = 1
        list.borderColor = NSColor.labelColor.withAlphaComponent(0.14)
        list.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
        list.contentViewMargins = .zero
        list.contentView = listBody
        list.translatesAutoresizingMaskIntoConstraints = false

        selectionField.textColor = .secondaryLabelColor
        selectionField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancelButton = NSButton(title: strings.t("Cancel", "取消"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        confirmButton.title = strings.t("Add", "添加")
        confirmButton.bezelStyle = .rounded
        confirmButton.bezelColor = .controlAccentColor
        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.keyEquivalent = "\r"
        confirmButton.setAccessibilityIdentifier("git.commit-ai.models.add")
        let actions = NSStackView(views: [selectionField, NSView(), cancelButton, confirmButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, subtitle, sourceRow, toolbar, list, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(12, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.heightAnchor.constraint(equalToConstant: 300),
            tableScroll.leadingAnchor.constraint(equalTo: listBody.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: listBody.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: listBody.topAnchor, constant: 4),
            tableScroll.bottomAnchor.constraint(equalTo: listBody.bottomAnchor, constant: -4),
            placeholder.centerXAnchor.constraint(equalTo: listBody.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: listBody.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: listBody.widthAnchor, constant: -48),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        catalogSubscription = catalog.$entries.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        loadCurrentAgentIfNeeded()
    }

    private func loadCurrentAgentIfNeeded() {
        guard case .agent(let agent) = currentSource else { return }
        let entry = catalog.entry(agent)
        if entry.models == nil, !entry.isLoading {
            catalog.refresh(agent)
        }
    }

    private func refresh() {
        let isAgent: Bool
        let isLoading: Bool
        let agentError: String?
        switch currentSource {
        case .agent(let agent):
            isAgent = true
            let entry = catalog.entry(agent)
            isLoading = entry.isLoading
            agentError = entry.error
        case .provider, nil:
            isAgent = false
            isLoading = false
            agentError = nil
        }
        reloadButton.isHidden = !isAgent
        reloadButton.isEnabled = isAgent && !isLoading
        spinner.setAnimating(isLoading && currentModels.isEmpty)

        let message: String
        if sources.isEmpty {
            message = strings.t("No model sources available.", "暂无可用模型来源。")
        } else if currentModels.isEmpty, isLoading {
            message = strings.t("Loading models…", "正在加载模型…")
        } else if currentModels.isEmpty, let agentError {
            message = agentError
        } else if currentModels.isEmpty, isAgent {
            message = strings.t(
                "No models loaded yet. Click Reload to query this local CLI.",
                "尚未加载模型，点击右侧刷新按钮读取该 CLI 的模型。"
            )
        } else if visibleModels.isEmpty {
            message = strings.t("No matching models.", "没有匹配的模型。")
        } else {
            message = ""
        }

        placeholderField.stringValue = message
        placeholderField.isHidden = message.isEmpty
        tableScroll.isHidden = !message.isEmpty
        selectionField.stringValue = selected.isEmpty
            ? ""
            : strings.t("\(selected.count) selected", "已选 \(selected.count) 个")
        confirmButton.isEnabled = !selected.isEmpty
        modelTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let currentSource, visibleModels.indices.contains(row) else { return nil }
        let model = visibleModels[row]
        let candidate = PickedModel(target: currentSource.target, model: model)
        let orderIndex = selected.firstIndex(of: candidate).map { $0 + 1 }
        let title = orderIndex.map { "\($0). \(model)" } ?? model
        let identifier = NSUserInterfaceItemIdentifier("settings.ai.unified-picker.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GitCommitAIModelCell
            ?? GitCommitAIModelCell()
        cell.identifier = identifier
        cell.configure(title: title, checked: orderIndex != nil, row: row, target: self,
                       action: #selector(toggleRow(_:)))
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        query = searchField.stringValue
        refresh()
    }

    @objc private func sourceChanged() {
        selectSource(at: sourcePopup.selectedItem?.tag ?? 0)
    }

    func selectSource(at index: Int) {
        guard sources.indices.contains(index), index != sourceIndex else { return }
        sourceIndex = index
        sourcePopup.selectItem(at: index)
        query = ""
        searchField.stringValue = ""
        refresh()
        loadCurrentAgentIfNeeded()
    }

    @objc private func reloadCurrentAgent() {
        guard case .agent(let agent) = currentSource else { return }
        catalog.refresh(agent)
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard visibleModels.indices.contains(sender.tag) else { return }
        toggle(visibleModels[sender.tag])
    }

    func toggle(_ model: String) {
        guard let currentSource else { return }
        let item = PickedModel(target: currentSource.target, model: model)
        if let index = selected.firstIndex(of: item) {
            selected.remove(at: index)
        } else {
            selected.append(item)
        }
        refresh()
    }

    @objc func addProvider() {
        guard let onAddProvider else { return }
        closePanel()
        onAddProvider()
    }

    @objc private func cancel() { closePanel() }

    @objc func confirm() {
        guard !selected.isEmpty else { return }
        done(selected)
        closePanel()
    }
}

extension GitCommitAISettingsPanel {
    /// Unified picker adding models from either API services or Local CLIs to Git routes.
    static func presentUnifiedAddModels(
        settings: OhMyGhosttySettings,
        catalog: AIAgentModelCatalog? = nil,
        from controller: NativeSettingsController
    ) {
        let resolvedCatalog = catalog ?? .shared
        let strings = SettingsStrings(language: settings.language)
        let heading = strings.t("Add Generation Models", "添加生成模型")
        let picker = AIUnifiedModelPickerController(
            providers: settings.aiProviders,
            catalog: resolvedCatalog,
            strings: strings,
            heading: heading,
            onAddProvider: { [weak controller] in
                controller?.presentAIProviderSheet(id: nil)
            },
            done: { picked in
                var routes = settings.gitCommitAIRoutes
                for item in picked {
                    routes = GitCommitAIRoute.adding(target: item.target, models: [item.model], to: routes)
                }
                settings.gitCommitAIRoutes = routes
            }
        )
        controller.presentModalSheet(picker, title: heading, size: NSSize(width: 520, height: 520))
    }

    /// Adds models of API services to the fallback list for Git messages.
    static func presentAddProviderModels(
        settings: OhMyGhosttySettings,
        from parent: NSWindow?,
        onAddProvider: (() -> Void)? = nil
    ) {
        guard let parent else { return }
        let strings = SettingsStrings(language: settings.language)
        let heading = strings.t("Add API Models", "从 API 服务添加模型")
        present(
            AIProviderModelPickerController(
                providers: AIProviderModelPickerController.eligible(settings.aiProviders),
                allowsMultiple: true, strings: strings, heading: heading,
                onAddProvider: onAddProvider,
                done: { provider, models in
                    settings.gitCommitAIRoutes = GitCommitAIRoute.adding(
                        provider: provider, models: models, to: settings.gitCommitAIRoutes
                    )
                }
            ),
            title: heading, size: NSSize(width: 480, height: 480), from: parent
        )
    }

    /// Chooses the one model that names agent conversations.
    static func presentTitleModel(
        settings: OhMyGhosttySettings,
        from controller: NativeSettingsController
    ) {
        let strings = SettingsStrings(language: settings.language)
        let heading = strings.t("Choose Title Model", "选择命名模型")
        let picker = AIProviderModelPickerController(
            providers: AIProviderModelPickerController.eligible(settings.aiProviders),
            allowsMultiple: false,
            strings: strings,
            heading: heading,
            onAddProvider: { [weak controller] in
                controller?.presentAIProviderSheet(id: nil)
            },
            done: { provider, models in
                guard let model = models.first else { return }
                settings.aiTitleRoute = AITitleRoute(provider: provider, model: model)
            }
        )
        controller.presentModalSheet(picker, title: heading, size: NSSize(width: 480, height: 480))
    }
}
