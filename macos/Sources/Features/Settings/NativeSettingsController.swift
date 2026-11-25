import AppKit
import Combine
import GhosttyKit

private final class NativeSettingsNavigationCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    var showsGroupDivider = false {
        didSet { needsDisplay = true }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors(); needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        needsDisplay = true
    }

    let badge = SettingsBadge()

    func updateColors() {
        badge.emphasized = backgroundStyle == .emphasized
        label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        icon.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsGroupDivider, backgroundStyle != .emphasized else { return }
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        let y = isFlipped ? 0.0 : bounds.maxY - 1.0
        NSRect(x: 10, y: y, width: max(0, bounds.width - 20), height: 1).fill()
    }
}

@MainActor
final class NativeSettingsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let settings: OhMyGhosttySettings
    let registry: SSHHostRegistry
    let agents: AgentIntegrationManager
    let mobileAccessController: MobileAccessController
    var mobileDeviceProvisioner: MobileDeviceProvisioner = .shared
    let doctor: OMGDoctorService
    /// Seams of the AI page: where API keys are kept, how API connections are called
    /// and how the models of installed agents are discovered.
    var aiCredentials: AICredentialStore = .shared
    var aiHTTPClient = AIHTTPClient()
    var aiAgentCatalog: AIAgentModelCatalog = .shared
    /// Active modal sheet controller (also accessible in headless unit tests).
    var activeModalSheet: GitCommitSettingsPanelController?
    var hostChoices: @Sendable () async -> [SSHRegistrationChoice] = { await SSHConfigurationCatalog.choices(live: []) }
    private(set) var selection: OhMyGhosttySettingsTab
    private let sidebar = NSTableView()
    private let sidebarSurface = NativeSettingsCanvas()
    private let sidebarDivider = NSBox()
    private var searchTopConstraint: NSLayoutConstraint?
    private var headerTopConstraint: NSLayoutConstraint?
    private var palette: OMGThemePalette?
    private let search = NSSearchField()
    var searchField: NSSearchField { search }
    private let titleLabel = NSTextField(labelWithString: "")
    private let content = NSView()
    private let back = SettingsActionButton("‹") {}
    private var page: NSViewController?
    private var subscriptions = Set<AnyCancellable>()
    private var history: [() -> Void] = []
    private var rows = OhMyGhosttySettingsTab.navigationOrder
    private var language: OhMyGhosttyLanguage
    private var selecting = false
    private var secondaryPages: [String: () -> Void] = [:]
    private var lastHosts: [String] = []
    private(set) var routeID = ""
    var strings: SettingsStrings { .init(language: settings.language) }
    func text(_ en: String, _ zh: String) -> String { strings.t(en, zh) }

    init(settings: OhMyGhosttySettings, initialSelection: OhMyGhosttySettingsTab,
         registry: SSHHostRegistry = .shared, agents: AgentIntegrationManager = .shared,
         mobileAccessController: MobileAccessController = .shared,
         doctor: OMGDoctorService = .shared) {
        self.settings = settings
        self.selection = initialSelection
        self.registry = registry
        self.agents = agents
        self.mobileAccessController = mobileAccessController
        self.doctor = doctor
        language = settings.language
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func isShowing(_ route: String) -> Bool { routeID == route }

    override func loadView() {
        let rootCanvas = NativeSettingsCanvas()
        rootCanvas.onWindowDidChange = { [weak self] in self?.updateChromeInsets() }
        view = rootCanvas
        let side = sidebarSurface
        search.placeholderString = strings.settingsSearch
        search.delegate = self
        search.sendsSearchStringImmediately = true
        sidebar.headerView = nil
        sidebar.rowHeight = 34
        sidebar.style = .sourceList
        sidebar.backgroundColor = .clear
        sidebar.addTableColumn(NSTableColumn(identifier: .init("category")))
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityIdentifier("settings.navigation")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = sidebar
        side.addSubview(search)
        side.addSubview(scroll)
        sidebarDivider.boxType = .custom
        sidebarDivider.borderType = .noBorder
        sidebarDivider.fillColor = NSColor.separatorColor.withAlphaComponent(0.55)
        view.addSubview(side)
        view.addSubview(sidebarDivider)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        back.bezelStyle = .inline
        back.title = ""
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: text("Back", "返回"))
        back.imagePosition = .imageOnly
        back.bezelStyle = .circular
        back.setAccessibilityIdentifier("settings.back")
        back.setAccessibilityLabel(text("Back", "返回"))
        back.widthAnchor.constraint(equalToConstant: 30).isActive = true
        back.heightAnchor.constraint(equalToConstant: 30).isActive = true
        back.invoke = { [weak self] in
            guard let self, let previous = self.history.popLast() else { return }
            previous()
        }
        let header = NSStackView(views: [back, titleLabel])
        header.orientation = .horizontal
        header.spacing = 12
        view.addSubview(header)
        view.addSubview(content)
        for child in [side, sidebarDivider, search, scroll, header, content] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let searchTop = search.topAnchor.constraint(equalTo: side.topAnchor, constant: 16)
        let headerTop = header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14)
        searchTopConstraint = searchTop
        headerTopConstraint = headerTop
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: view.leadingAnchor), side.topAnchor.constraint(equalTo: view.topAnchor),
            side.bottomAnchor.constraint(equalTo: view.bottomAnchor), side.widthAnchor.constraint(equalToConstant: 210),
            sidebarDivider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            sidebarDivider.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: 1),
            searchTop,
            search.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -12),
            header.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            headerTop, header.heightAnchor.constraint(equalToConstant: 36),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: side.trailingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        NotificationCenter.default.publisher(for: .omgSelectSettingsTab).sink { [weak self] note in
            guard let tab = note.object as? OhMyGhosttySettingsTab else { return }
            self?.select(tab)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .omgSelectAgentIntegrationTarget).sink { [weak self] _ in
            self?.consumeAgentTarget()
        }.store(in: &subscriptions)
        settings.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] language in
            guard let self, self.language != language else { return }
            self.language = language
            self.search.placeholderString = self.strings.settingsSearch
            self.sidebar.reloadData()
            self.select(self.selection)
        }.store(in: &subscriptions)
        registry.$hosts.combineLatest(registry.$connections).receive(on: RunLoop.main).sink { [weak self] _, _ in
            guard let self else { return }
            let hosts = self.registry.hosts
            let connections = self.registry.connections
            let signature = hosts.flatMap { [$0.id, $0.name, $0.endpoint ?? "", connections[$0.id] == nil ? "saved" : "connected"] }
            guard signature != self.lastHosts else { return }
            self.lastHosts = signature
            if self.isShowing("ssh") {
                let old = (self.page?.view as? NSScrollView)?.contentView.bounds.origin ?? .zero
                self.select(.ssh)
                self.page?.view.layoutSubtreeIfNeeded()
                if let scroll = self.page?.view as? NSScrollView {
                    scroll.contentView.scroll(to: old); scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else if self.routeID.hasPrefix("host:"),
                      self.registry.host(String(self.routeID.dropFirst(5))) == nil {
                self.select(.ssh)
            } else if self.routeID.hasPrefix("host:"),
                      let host = self.registry.host(String(self.routeID.dropFirst(5))) {
                self.titleLabel.stringValue = host.name
            } else if (self.routeID.hasPrefix("agents:ssh-host:") || self.routeID.hasPrefix("agent:ssh-host:")) &&
                        !hosts.contains(where: { self.routeID.hasPrefix("agents:" + $0.id) || self.routeID.hasPrefix("agent:" + $0.id + ":") }) {
                self.select(.ssh)
            }
        }.store(in: &subscriptions)
        select(selection)
    }

    private func consumeAgentTarget() {
        guard let target = SettingsNavigation.consumeAgentTarget() else { return }
        select(target == AgentIntegrationManager.localID ? .agents : .ssh)
        showAgents(target: target)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = rows[row]
        let cell = NativeSettingsNavigationCell()
        cell.showsGroupDivider = rows == OhMyGhosttySettingsTab.navigationOrder &&
            [.terminal, .agents, .advanced].contains(tab)
        let icon = cell.icon
        icon.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil)
        let label = cell.label
        label.stringValue = strings.tabTitle(tab)
        label.font = .systemFont(ofSize: 13)
        cell.updateColors()
        let stack = NSStackView(views: [icon, label])
        if tab == .plugins {
            cell.badge.text = "BETA"
            stack.addArrangedSubview(cell.badge)
            stack.setCustomSpacing(6, after: label)
        }
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, rows.indices.contains(sidebar.selectedRow) else { return }
        select(rows[sidebar.selectedRow])
    }
    func controlTextDidChange(_ obj: Notification) {
        showSearch()
    }
    func searchFor(_ query: String) {
        _ = view
        search.stringValue = query
        if !query.isEmpty { showSearch() }
    }
    private func showSearch() {
        selecting = true
        defer { selecting = false }
        routeID = "search"
        history.removeAll()
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = SettingsSearchCatalog.entries(strings: strings).filter { $0.matches(query) }
        rows = OhMyGhosttySettingsTab.navigationOrder
        if !query.isEmpty {
            rows = OhMyGhosttySettingsTab.navigationOrder.filter { tab in
                strings.tabTitle(tab).localizedCaseInsensitiveContains(query) || matches.contains { $0.tab == tab }
            }
        }
        sidebar.reloadData()
        let form = NativeSettingsForm()
        form.section(text("Results", "搜索结果"))
        for entry in matches {
            form.link(entry.title, subtitle: strings.tabTitle(entry.tab)) { [weak self] in self?.navigate(to: entry, query: query) }
        }
        if query.isEmpty { select(selection) } else { present(form, title: strings.settingsSearch) }
    }

    func present(_ controller: NSViewController, title: String) {
        _ = view
        page?.view.removeFromSuperview()
        page?.removeFromParent()
        page = controller
        if let form = controller as? NativeSettingsForm {
            if let palette { form.applyPalette(palette) }
            let token = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak form] _ in
                form?.refreshers.forEach { $0() }
            }
            form.retained.append(token)
            let config = NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
                .filter { $0.object == nil }.receive(on: RunLoop.main).sink { [weak form] _ in
                    form?.refreshers.forEach { $0() }
                }
            form.retained.append(config)
        }
        addChild(controller)
        content.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: content.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        titleLabel.stringValue = title
        back.isHidden = history.isEmpty
    }

    func updateChromeInsets() {
        let usesFullSizeTitlebar = view.window?.styleMask.contains(.fullSizeContentView) == true
        searchTopConstraint?.constant = usesFullSizeTitlebar ? 40 : 16
        headerTopConstraint?.constant = usesFullSizeTitlebar ? 18 : 14
    }

    func applyPalette(_ palette: OMGThemePalette) {
        self.palette = palette
        (view as? NativeSettingsCanvas)?.background = palette.background
        sidebarSurface.background = palette.background.blended(withFraction: 0.035, of: palette.foreground)
        sidebarDivider.fillColor = palette.foreground.withAlphaComponent(0.10)
        (page as? NativeSettingsForm)?.applyPalette(palette)
    }

    func presentModalSheet(_ sheet: GitCommitSettingsPanelController, title: String, size: NSSize) {
        if let existing = activeModalSheet, !existing.finished {
            existing.closePanel()
        }
        activeModalSheet = sheet
        _ = sheet.view
        sheet.onSheetDidEnd = { [weak self, weak sheet] in
            if self?.activeModalSheet === sheet {
                self?.activeModalSheet = nil
            }
        }
        if let parent = view.window {
            GitCommitAISettingsPanel.present(sheet, title: title, size: size, from: parent)
        }
    }

    func setRoute(_ id: String) { routeID = id }

    /// Renames the page being shown, e.g. after its subject was renamed.
    func retitle(_ title: String) { titleLabel.stringValue = title }

    func validatedRuntimePolicy() throws -> SessionRuntimePolicy {
        let policy = settings.runtimePolicy
        if !settings.runtimeExpiration.isEmpty, policy.expiresAt == nil {
            throw NSError(domain: "OMGSettings", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: text("Choose a valid expiration date in Persistent Terminal Sessions.",
                                                                   "请在“持久终端会话”中选择有效的截止时间。")])
        }
        return policy
    }

    func push(_ title: String, route: String? = nil, previous: @escaping () -> Void, build: (NativeSettingsForm) -> Void) {
        routeID = route ?? "detail:" + title
        history.append(previous)
        let form = NativeSettingsForm()
        build(form)
        present(form, title: title)
    }

    func select(_ tab: OhMyGhosttySettingsTab) {
        _ = view
        view.window?.makeFirstResponder(nil)
        selecting = true
        defer { selecting = false }
        if !search.stringValue.isEmpty {
            search.stringValue = ""
            rows = OhMyGhosttySettingsTab.navigationOrder
            sidebar.reloadData()
        }
        selection = tab
        secondaryPages.removeAll()
        history.removeAll()
        routeID = tab.rawValue
        let form = NativeSettingsForm()
        build(tab, into: form)
        present(form, title: strings.tabTitle(tab))
        if let index = rows.firstIndex(of: tab), sidebar.selectedRow != index {
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func toggle(_ form: NativeSettingsForm, _ title: String, _ key: ReferenceWritableKeyPath<OhMyGhosttySettings, Bool>,
                help: String? = nil) {
        let control = SettingsSwitch(value: settings[keyPath: key]) { [weak settings] in settings?[keyPath: key] = $0 }
        form.row(title, control: control, help: help)
        form.refreshers.append { [weak settings, weak control] in
            if let settings { control?.state = settings[keyPath: key] ? .on : .off }
        }
    }
    func picker<Value: Equatable>(_ form: NativeSettingsForm, _ title: String,
                                  _ key: ReferenceWritableKeyPath<OhMyGhosttySettings, Value>, _ options: [(Value, String)]) {
        let control = SettingsPopup(titles: options.map(\.1), selected: options.firstIndex { $0.0 == settings[keyPath: key] } ?? 0) { [weak settings] index in guard options.indices.contains(index) else { return }; settings?[keyPath: key] = options[index].0
        }
        form.row(title, control: control)
        form.refreshers.append { [weak settings, weak control] in
            guard let settings else { return }
            control?.selectItem(at: options.firstIndex { $0.0 == settings[keyPath: key] } ?? 0)
        }
    }
    func number(_ form: NativeSettingsForm, _ title: String, _ key: ReferenceWritableKeyPath<OhMyGhosttySettings, Double>,
                range: ClosedRange<Double>, step: Double = 1, help: String? = nil) {
        let control = SettingsNumberField(value: settings[keyPath: key], range: range, step: step) { [weak settings] in settings?[keyPath: key] = $0
        }
        form.row(title, control: control, help: help)
        form.refreshers.append { [weak settings, weak control] in
            guard let settings, let control, control.field.currentEditor() == nil else { return }
            control.field.doubleValue = settings[keyPath: key]
            control.stepper.doubleValue = settings[keyPath: key]
        }
    }
    func core(_ group: CoreSetting.Group, in form: NativeSettingsForm) {
        form.section(group.title(strings))
        for field in CoreSetting.all where field.group == group { core(field, in: form) }
    }
    func core(_ key: String, in form: NativeSettingsForm) {
        if let field = CoreSetting.find(key) { core(field, in: form) }
    }
    func coreRow(_ key: String, in form: NativeSettingsForm) {
        if let field = CoreSetting.find(key) { core(field, in: form) }
    }
    private func core(_ field: CoreSetting, in form: NativeSettingsForm) {
        let values = [""] + field.values
        form.row(field.title(strings), control: SettingsPopup(
            titles: [inheritedTitle(field)] + field.values.map { field.valueTitle($0, strings: strings) },
            selected: values.firstIndex(of: settings.coreOverrides[field.key] ?? "") ?? 0) { [weak settings] index in
                _ = settings?.setCoreOverride(field.key, value: values[index])
            }, help: field.help(strings))
    }
    /// "Default" alone hides what the terminal config currently resolves to.
    private func inheritedTitle(_ field: CoreSetting) -> String {
        let base = text("Default", "默认")
        guard field.values == ["true", "false"],
              let config = (NSApp.delegate as? AppDelegate)?.ghostty.inheritedConfig.config else { return base }
        var value = false
        guard ghostty_config_get(config, &value, field.key, UInt(field.key.utf8.count)) else { return base }
        return base + text(value ? " (On)" : " (Off)", value ? "（开启）" : "（关闭）")
    }

    func navigate(to entry: SettingsSearchEntry, query: String = "") {
        select(entry.tab)
        if let open = secondaryPages[entry.title] { open(); return }
        (page as? NativeSettingsForm)?.scrollTo(entry.anchor)
    }
}
