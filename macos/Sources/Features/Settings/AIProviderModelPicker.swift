import AppKit

/// Sheet that picks models of API services for a task: several for the fallback
/// list of Git messages, or one for tab titles. It reads the models already listed
/// on each service, so opening it never touches the network.
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
        // Report the models in the service's own order, not in click order.
        done(provider.id, provider.models.map(\.id).filter { selected.contains($0) })
        closePanel()
    }
}

extension GitCommitAISettingsPanel {
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
        from parent: NSWindow?,
        onAddProvider: (() -> Void)? = nil
    ) {
        guard let parent else { return }
        let strings = SettingsStrings(language: settings.language)
        let heading = strings.t("Choose Title Model", "选择命名模型")
        present(
            AIProviderModelPickerController(
                providers: AIProviderModelPickerController.eligible(settings.aiProviders),
                allowsMultiple: false, strings: strings, heading: heading,
                onAddProvider: onAddProvider,
                done: { provider, models in
                    guard let model = models.first else { return }
                    settings.aiTitleRoute = AITitleRoute(provider: provider, model: model)
                }
            ),
            title: heading, size: NSSize(width: 480, height: 480), from: parent
        )
    }
}
