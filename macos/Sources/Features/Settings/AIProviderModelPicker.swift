import AppKit
import Combine

/// Unified modal sheet that picks models from BOTH API services AND Local CLIs
/// (`Codex`, `Claude Code`, `Pi`, `OpenCode`), sharing `AIAgentModelCatalog`.
/// Supports multi-select (`allowsMultiple: true`, preserving user click order) for Git
/// fallback lists and single-select (`allowsMultiple: false`) for conversation titles.
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

    /// API services a task can use right now: enabled ones that list at least one model.
    static func eligibleProviders(_ providers: [AIProvider]) -> [AIProvider] {
        providers.filter { $0.enabled && !$0.models.isEmpty }
    }

    let sources: [Source]
    let allowsMultiple: Bool
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
        allowsMultiple: Bool = true,
        initialTarget: GitCommitAIRoute.Target? = nil,
        initialSelection: [PickedModel] = [],
        strings: SettingsStrings,
        heading: String,
        onAddProvider: (() -> Void)? = nil,
        done: @escaping ([PickedModel]) -> Void
    ) {
        let eligible = Self.eligibleProviders(providers)
        let resolvedSources = eligible.map(Source.provider) + agents.map(Source.agent)
        self.sources = resolvedSources
        self.allowsMultiple = allowsMultiple
        self.catalog = catalog ?? .shared
        self.strings = strings
        self.heading = heading
        self.onAddProvider = onAddProvider
        self.done = done
        self.selected = allowsMultiple ? initialSelection : Array(initialSelection.prefix(1))
        if let initialTarget, let matched = resolvedSources.firstIndex(where: { $0.target == initialTarget }) {
            self.sourceIndex = matched
        }
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

    private func sourceLabel(_ source: Source) -> String {
        switch source {
        case .provider(let provider):
            strings.t("API · \(provider.name)", "API · \(provider.name)")
        case .agent(let agent):
            strings.t("Local CLI · \(agent.title)", "本机 CLI · \(agent.title)")
        }
    }

    private func pickedSummary(_ item: PickedModel) -> String {
        switch item.target {
        case .provider(let id):
            let name = sources.compactMap { source -> String? in
                if case .provider(let provider) = source, provider.id == id { return provider.name }
                return nil
            }.first ?? "API"
            return "\(name) · \(item.model)"
        case .agent(let agent):
            return "\(agent.title) · \(item.model)"
        }
    }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitleText = allowsMultiple
            ? strings.t(
                "Choose models from your API services or logged-in local CLIs. Selected models are added in the order you check them.",
                "可同时从 API 服务或本机已登录 CLI 选择模型；勾选顺序即为添加后的优先顺序。"
            )
            : strings.t(
                "Choose one model from your API services or logged-in local CLIs.",
                "从 API 服务或本机已登录 CLI 中选择一个模型。"
            )
        let subtitle = NSTextField(wrappingLabelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor

        let menu = NSMenu()
        for (index, source) in sources.enumerated() {
            let item = NSMenuItem(title: sourceLabel(source), action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        sourcePopup.menu = menu
        if sources.indices.contains(sourceIndex) {
            sourcePopup.selectItem(at: sourceIndex)
        }
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
        selectionField.lineBreakMode = .byTruncatingMiddle
        selectionField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancelButton = NSButton(title: strings.t("Cancel", "取消"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        confirmButton.title = allowsMultiple
            ? strings.t("Add", "添加")
            : strings.t("Use This Model", "使用此模型")
        confirmButton.bezelStyle = .rounded
        confirmButton.bezelColor = .controlAccentColor
        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.keyEquivalent = "\r"
        confirmButton.setAccessibilityIdentifier(
            allowsMultiple ? "git.commit-ai.models.add" : "settings.ai.unified-picker.confirm"
        )
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
        if selected.isEmpty {
            selectionField.stringValue = ""
        } else if allowsMultiple {
            selectionField.stringValue = strings.t("\(selected.count) selected", "已选 \(selected.count) 个")
        } else if let first = selected.first {
            selectionField.stringValue = pickedSummary(first)
        }
        confirmButton.isEnabled = !selected.isEmpty
        modelTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let currentSource, visibleModels.indices.contains(row) else { return nil }
        let model = visibleModels[row]
        let candidate = PickedModel(target: currentSource.target, model: model)
        let orderIndex = selected.firstIndex(of: candidate).map { $0 + 1 }
        let title = allowsMultiple ? (orderIndex.map { "\($0). \(model)" } ?? model) : model
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
        } else if allowsMultiple {
            selected.append(item)
        } else {
            selected = [item]
        }
        refresh()
    }

    @objc func addProvider() {
        guard let onAddProvider else { return }
        closePanel { onAddProvider() }
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
        let resolvedCatalog = catalog ?? controller.aiAgentCatalog
        let strings = SettingsStrings(language: settings.language)
        let heading = strings.t("Add Generation Models", "添加生成模型")
        let picker = AIUnifiedModelPickerController(
            providers: settings.aiProviders,
            catalog: resolvedCatalog,
            allowsMultiple: true,
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

    /// Unified single-select picker choosing the conversation title model from API services or Local CLIs.
    static func presentTitleModel(
        settings: OhMyGhosttySettings,
        catalog: AIAgentModelCatalog? = nil,
        from controller: NativeSettingsController
    ) {
        let resolvedCatalog = catalog ?? controller.aiAgentCatalog
        let strings = SettingsStrings(language: settings.language)
        let heading = strings.t("Choose Title Model", "选择命名模型")
        let existingSelection: [AIUnifiedModelPickerController.PickedModel] = settings.aiTitleRoute.map {
            [.init(target: $0.target, model: $0.model)]
        } ?? []
        let picker = AIUnifiedModelPickerController(
            providers: settings.aiProviders,
            catalog: resolvedCatalog,
            allowsMultiple: false,
            initialTarget: settings.aiTitleRoute?.target,
            initialSelection: existingSelection,
            strings: strings,
            heading: heading,
            onAddProvider: { [weak controller] in
                controller?.presentAIProviderSheet(id: nil)
            },
            done: { picked in
                guard let first = picked.first,
                      let model = AIModelID.normalized(first.model) else { return }
                settings.aiTitleRoute = AITitleRoute(target: first.target, model: model)
            }
        )
        controller.presentModalSheet(picker, title: heading, size: NSSize(width: 520, height: 520))
    }
}
