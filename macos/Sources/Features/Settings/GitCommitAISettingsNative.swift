import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GitCommitAIRoutesTable: NSViewRepresentable {
    @ObservedObject var settings: OhMyGhosttySettings

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: settings)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeNativeView(coordinator: context.coordinator)
    }

    static let rowHeight: CGFloat = 48

    static func makeNativeView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = SettingsNestedScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.draggingDestinationFeedbackStyle = .gap
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityIdentifier("git.commit-ai.routes")

        let column = NSTableColumn(identifier: .init("route"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        scrollView.documentView = table
        coordinator.tableView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.tableView?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var settings: OhMyGhosttySettings
        weak var tableView: NSTableView?

        init(settings: OhMyGhosttySettings) {
            self.settings = settings
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            settings.gitCommitAIRoutes.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard settings.gitCommitAIRoutes.indices.contains(row) else { return nil }
            let route = settings.gitCommitAIRoutes[row]
            let cell = tableView.makeView(
                withIdentifier: .init("git.commit-ai.route-cell"),
                owner: self
            ) as? GitCommitAIRouteCell ?? GitCommitAIRouteCell()
            cell.identifier = .init("git.commit-ai.route-cell")
            cell.configure(route: route, index: row, settings: settings)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard settings.gitCommitAIRoutes.indices.contains(row) else { return nil }
            return settings.gitCommitAIRoutes[row].id.uuidString as NSString
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard operation == .above,
                  info.draggingSourceOperationMask.contains(.move),
                  info.draggingPasteboard.string(forType: .string).flatMap(UUID.init(uuidString:)) != nil else {
                return []
            }
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let rawID = info.draggingPasteboard.string(forType: .string),
                  let id = UUID(uuidString: rawID),
                  let source = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let routes = Self.moved(settings.gitCommitAIRoutes, routeID: id, toInsertionRow: row)
            guard routes != settings.gitCommitAIRoutes else { return true }
            settings.gitCommitAIRoutes = routes
            tableView.reloadData()
            return routes.indices.contains(source)
        }

        @discardableResult
        func move(_ id: UUID, by delta: Int) -> Bool {
            guard let source = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == id }),
                  settings.gitCommitAIRoutes.indices.contains(source + delta) else { return false }
            settings.gitCommitAIRoutes.swapAt(source, source + delta)
            tableView?.reloadData()
            return true
        }

        func remove(_ id: UUID) {
            settings.gitCommitAIRoutes.removeAll { $0.id == id }
            tableView?.reloadData()
        }

        static func moved(_ routes: [GitCommitAIRoute], routeID: UUID, toInsertionRow row: Int) -> [GitCommitAIRoute] {
            guard let source = routes.firstIndex(where: { $0.id == routeID }) else { return routes }
            let insertion = min(max(row, 0), routes.count)
            let destination = insertion > source ? insertion - 1 : insertion
            guard destination != source else { return routes }
            var result = routes
            let route = result.remove(at: source)
            result.insert(route, at: min(destination, result.count))
            return result
        }
    }
}

@MainActor
private final class GitCommitAIRouteCell: NSTableCellView {
    private let orderField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let agentField = NSTextField(labelWithString: "")
    private let modelField = NSTextField(labelWithString: "")
    private let upButton = NSButton()
    private let downButton = NSButton()
    private let removeButton = NSButton()
    private weak var settings: OhMyGhosttySettings?
    private var routeID: UUID?
    private var showsDivider = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // The position number doubles as the priority: models are tried in this order.
        orderField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        orderField.textColor = .tertiaryLabelColor
        orderField.alignment = .center
        orderField.setAccessibilityLabel(GitL10n.text("Reorder model"))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        agentField.font = .systemFont(ofSize: 13)
        agentField.lineBreakMode = .byTruncatingTail
        modelField.font = .systemFont(ofSize: 11)
        modelField.textColor = .secondaryLabelColor
        modelField.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [agentField, modelField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(upButton, symbol: "arrow.up", label: GitL10n.text("Move up"), action: #selector(moveRouteUp))
        configure(downButton, symbol: "arrow.down", label: GitL10n.text("Move down"), action: #selector(moveRouteDown))
        configure(removeButton, symbol: "minus.circle", label: GitL10n.text("Remove model"), action: #selector(removeRoute))
        // Pushes the actions to the trailing edge whatever the label widths.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [orderField, iconView, labels, spacer, upButton, downButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(12, after: iconView)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            orderField.widthAnchor.constraint(equalToConstant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            upButton.widthAnchor.constraint(equalToConstant: 24),
            downButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(route: GitCommitAIRoute, index: Int, settings: OhMyGhosttySettings) {
        self.routeID = route.id
        self.settings = settings
        orderField.stringValue = "\(index + 1)"
        var usable = true
        switch route.target {
        case .agent(let agent):
            iconView.image = SupportedAgent(rawValue: agent.rawValue).flatMap { NSImage(named: $0.assetName) }
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            agentField.stringValue = agent.title
        case .provider(let id):
            // An API connection that was switched off stays listed, marked, and is skipped at run time.
            let provider = settings.aiProvider(id)
            usable = provider?.enabled == true
            iconView.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            let name = route.sourceTitle(providers: settings.aiProviders)
            agentField.stringValue = usable ? name
                : name + SettingsStrings(language: settings.language).t(" (off)", "（已停用）")
        }
        iconView.contentTintColor = .secondaryLabelColor
        agentField.textColor = usable ? .labelColor : .secondaryLabelColor
        modelField.stringValue = route.model
        setAccessibilityLabel(route.title(providers: settings.aiProviders))
        showsDivider = index > 0
        needsDisplay = true
        let routes = settings.gitCommitAIRoutes
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        upButton.isEnabled = index > routes.startIndex
        downButton.isEnabled = routes.index(after: index) < routes.endIndex
    }

    /// Hairline between rows only, inset like the form's own rows, so nothing
    /// is drawn along the rounded bottom edge of the enclosing group.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsDivider else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 16, y: isFlipped ? 0 : bounds.maxY - 1, width: bounds.width - 16, height: 1).fill()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("git.commit-ai.\(symbol)")
    }

    @objc private func moveRouteUp() { applyMove(-1) }
    @objc private func moveRouteDown() { applyMove(1) }

    private func applyMove(_ delta: Int) {
        guard let routeID,
              let table = superview?.superview as? NSTableView,
              let coordinator = table.dataSource as? GitCommitAIRoutesTable.Coordinator else { return }
        coordinator.move(routeID, by: delta)
    }

    @objc private func removeRoute() {
        guard let routeID,
              let table = superview?.superview as? NSTableView,
              let coordinator = table.dataSource as? GitCommitAIRoutesTable.Coordinator else { return }
        coordinator.remove(routeID)
    }
}

@MainActor
enum GitCommitAISettingsPanel {
    static func presentPrompt(settings: OhMyGhosttySettings, from parent: NSWindow?) {
        guard let parent else { return }
        present(
            GitCommitAIPromptController(prompt: settings.gitCommitAIPrompt) { settings.gitCommitAIPrompt = $0 },
            title: GitL10n.text("Custom commit prompt"),
            size: NSSize(width: 560, height: 440),
            from: parent
        )
    }

    static func presentAddModels(settings: OhMyGhosttySettings, from parent: NSWindow?) {
        guard let parent else { return }
        present(
            GitCommitAIAddModelsController { agent, models in
                settings.gitCommitAIRoutes = GitCommitAIRoute.adding(
                    agent: agent, models: models, to: settings.gitCommitAIRoutes
                )
            },
            title: GitL10n.text("Add Local CLI Models"),
            size: NSSize(width: 540, height: 620),
            from: parent
        )
    }

    static func present(_ controller: GitCommitSettingsPanelController,
                        title: String, size: NSSize, from parent: NSWindow) {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.appearance = parent.appearance ?? NSApp.effectiveAppearance
        let palette = OMGThemeBackground.palette(for: parent)
        panel.backgroundColor = palette.background
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = true
        panel.contentViewController = controller
        // The content view otherwise shrinks the sheet to its narrowest fitting width.
        controller.view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        (controller.view as? OMGNativeSurfaceView)?.bindTheme(to: parent)
        parent.beginSheet(panel) { _ in controller.sheetEnded() }
    }
}

@MainActor
class GitCommitSettingsPanelController: NSViewController, NSWindowDelegate {
    private(set) var finished = false
    private weak var panelWindow: NSWindow?

    override func viewDidAppear() {
        super.viewDidAppear()
        panelWindow = view.window
        panelWindow?.delegate = self
    }

    func closePanel() {
        guard !finished else { return }
        finished = true
        guard let window = panelWindow ?? view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    func sheetEnded() {
        finished = true
        let panel = panelWindow ?? view.window
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panelWindow = nil
        didEndSheet()
    }

    func didEndSheet() {}

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }
}

@MainActor
final class GitCommitAIPromptController: GitCommitSettingsPanelController, NSTextViewDelegate {
    private var prompt: String
    private let save: (String) -> Void
    let promptView = NSTextView()
    let saveButton = NSButton()

    init(prompt: String, save: @escaping (String) -> Void) {
        self.prompt = prompt
        self.save = save
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: GitL10n.text("Custom commit prompt"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let scroll = NSScrollView()
        // A quiet inset field in the sheet's own colours, not a black bezel box.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let field = NSBox()
        field.boxType = .custom
        field.cornerRadius = 8
        field.borderWidth = 1
        field.borderColor = NSColor.labelColor.withAlphaComponent(0.14)
        field.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
        field.contentViewMargins = .zero
        field.contentView = scroll
        scroll.hasVerticalScroller = true
        promptView.drawsBackground = false
        promptView.textContainerInset = NSSize(width: 8, height: 10)
        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptView.string = prompt
        promptView.delegate = self
        promptView.setAccessibilityLabel(GitL10n.text("Custom commit prompt"))
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.widthTracksTextView = true
        promptView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        promptView.minSize = .zero
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        promptView.frame = NSRect(x: 0, y: 0, width: 520, height: 250)
        scroll.documentView = promptView
        field.translatesAutoresizingMaskIntoConstraints = false
        let help = NSTextField(wrappingLabelWithString: GitL10n.text(
            "Specify language, format and commit style. Applied to all models, including fallbacks. Leave empty to follow recent commits."
        ))
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancel = NSButton(title: GitL10n.text("Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        saveButton.title = GitL10n.text("Save")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePrompt)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.bezelColor = .controlAccentColor
        saveButton.setAccessibilityIdentifier("git.commit-ai.prompt.save")
        let actions = NSStackView(views: [NSView(), cancel, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, field, help, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 250),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(promptView)
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === promptView else { return }
        prompt = editor.string
    }

    @objc private func cancel() { closePanel() }

    @objc private func savePrompt() {
        save(promptView.string)
        closePanel()
    }
}

@MainActor
final class GitCommitAIAddModelsController: GitCommitSettingsPanelController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let add: (GitCommitAgent, [String]) -> Void
    private var agentTabs: [GitCommitAgentTab] = []
    private let searchField = NSSearchField()
    private let modelTable = NSTableView()
    private let tableScroll = NSScrollView()
    private let spinner = NativeProgressIndicator()
    private let reloadButton = NSButton()
    private let updateButton = NSButton()
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let errorField = NSTextField(wrappingLabelWithString: "")
    private let helpField = NSTextField(wrappingLabelWithString: "")
    private let placeholderIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle",
                                                             accessibilityDescription: nil) ?? NSImage())
    private let placeholderField = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()
    private let selectionField = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var agent = GitCommitAgent.claude
    private var query = ""
    private var models: [String] = []
    private var selected: Set<String> = []
    private var loading = false
    private var loadingID = UUID()
    private var updateInfo: GitACPAdapterUpdateInfo?
    private var checkingUpdate = false
    private var updating = false
    private var reloadTask: Task<Void, Never>?

    init(add: @escaping (GitCommitAgent, [String]) -> Void) {
        self.add = add
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: GitL10n.text("Add Local CLI Models"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        helpField.stringValue = GitL10n.text(
            "Reuses your logged-in local CLI to generate messages (including for SSH repositories). Staged diffs are sent to the selected model service."
        )
        helpField.textColor = .secondaryLabelColor
        helpField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpField.maximumNumberOfLines = 0

        // Every Agent stays visible and one click away; a pop-up hid three of four.
        agentTabs = GitCommitAgent.allCases.map { value in
            let tab = GitCommitAgentTab(agent: value) { [weak self] in self?.selectAgent(value) }
            tab.isSelected = value == agent
            return tab
        }
        let tabs = NSStackView(views: agentTabs)
        tabs.orientation = .horizontal
        tabs.distribution = .fillEqually
        tabs.spacing = 8
        tabs.setAccessibilityLabel(GitL10n.text("Agent"))
        tabs.setAccessibilityRole(.radioGroup)
        searchField.placeholderString = GitL10n.text("Search models…")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(GitL10n.text("Search models…"))
        searchField.setAccessibilityIdentifier("git.commit-ai.models.search")
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.bezelStyle = .rounded
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: GitL10n.text("Reload"))
        reloadButton.imagePosition = .imageOnly
        reloadButton.toolTip = GitL10n.text("Reload")
        reloadButton.setAccessibilityLabel(GitL10n.text("Reload"))
        reloadButton.setAccessibilityIdentifier("git.commit-ai.models.reload")
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
        modelTable.setAccessibilityLabel(GitL10n.text("Available models"))
        tableScroll.documentView = modelTable
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = false

        // Loading, failure and empty results are reported where the models
        // would be, instead of leaving a blank box above a detached message.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        placeholderIcon.contentTintColor = .systemOrange
        placeholderIcon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        placeholderField.alignment = .center
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.maximumNumberOfLines = 6
        retryButton.title = GitL10n.text("Retry")
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(reload)
        let placeholder = NSStackView(views: [spinner, placeholderIcon, placeholderField, retryButton])
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 10
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        let listBody = NSView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
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

        updateStatus.textColor = .secondaryLabelColor
        updateStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateStatus.maximumNumberOfLines = 2
        updateButton.target = self
        updateButton.action = #selector(confirmUpdate)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.isHidden = true
        let update = NSStackView(views: [updateStatus, updateButton])
        update.orientation = .horizontal
        update.spacing = 8
        errorField.textColor = .systemRed
        errorField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorField.maximumNumberOfLines = 3

        selectionField.textColor = .secondaryLabelColor
        selectionField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancelButton = NSButton(title: GitL10n.text("Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        addButton.title = GitL10n.text("Add")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addSelected)
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityIdentifier("git.commit-ai.models.add")
        let actions = NSStackView(views: [selectionField, NSView(), cancelButton, addButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, helpField, tabs, toolbar, list, update, errorField, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: helpField)
        stack.setCustomSpacing(14, after: errorField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            helpField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 34),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            list.heightAnchor.constraint(equalToConstant: 300),
            tableScroll.leadingAnchor.constraint(equalTo: listBody.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: listBody.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: listBody.topAnchor, constant: 4),
            tableScroll.bottomAnchor.constraint(equalTo: listBody.bottomAnchor, constant: -4),
            placeholder.centerXAnchor.constraint(equalTo: listBody.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: listBody.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: listBody.widthAnchor, constant: -48),
            update.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        updateButtons()
    }

    /// Chooses what the list area shows and hides rows that have nothing to say.
    private func refreshPlaceholder() {
        let failure = errorField.stringValue
        let noResults = !models.isEmpty && visibleModels.isEmpty
        let message: String
        if models.isEmpty, loading {
            message = GitL10n.text("Loading models…")
        } else if models.isEmpty {
            message = failure
        } else {
            message = noResults ? GitL10n.text("No matching models.") : ""
        }
        let failed = models.isEmpty && !loading && !failure.isEmpty
        placeholderField.stringValue = message
        placeholderField.isHidden = message.isEmpty
        placeholderIcon.isHidden = !failed
        retryButton.isHidden = !failed
        tableScroll.isHidden = models.isEmpty || noResults
        // With no list to keep, the failure is already shown in the list area.
        errorField.isHidden = failure.isEmpty || models.isEmpty
        updateStatus.isHidden = updateStatus.stringValue.isEmpty
        selectionField.stringValue = selected.isEmpty ? "" : GitL10n.format("{0} selected", String(selected.count))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        if reloadTask == nil { loadModels() }
    }

    deinit { reloadTask?.cancel() }

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        reloadTask?.cancel()
        return super.windowShouldClose(sender)
    }

    override func didEndSheet() {
        reloadTask?.cancel()
    }

    private var visibleModels: [String] {
        models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleModels.indices.contains(row) else { return nil }
        let model = visibleModels[row]
        let identifier = NSUserInterfaceItemIdentifier("git.commit-ai.model-cell")
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
        modelTable.reloadData()
        refreshPlaceholder()
    }

    @objc private func toggleModel(_ sender: NSButton) {
        guard visibleModels.indices.contains(sender.tag) else { return }
        let model = visibleModels[sender.tag]
        if !selected.insert(model).inserted { selected.remove(model) }
        modelTable.reloadData()
        updateButtons()
    }

    private func selectAgent(_ value: GitCommitAgent) {
        guard value != agent, !updating else { return }
        agent = value
        agentTabs.forEach { $0.isSelected = $0.agent == value }
        selected = []
        query = ""
        models = []
        searchField.stringValue = ""
        updateInfo = nil
        errorField.stringValue = ""
        updateStatus.stringValue = ""
        modelTable.reloadData()
        loadModels()
    }

    @objc private func reload() { loadModels() }

    private func loadModels() {
        reloadTask?.cancel()
        let requestedAgent = agent
        let id = UUID()
        loadingID = id
        loading = true
        checkingUpdate = false
        errorField.stringValue = ""
        spinner.setAnimating(true)
        updateButtons()
        reloadTask = Task { @MainActor in
            defer {
                if loadingID == id {
                    loading = false
                    spinner.setAnimating(false)
                    reloadTask = nil
                    updateButtons()
                }
            }
            do {
                let result = try await GitCommitAIService.models(agent: requestedAgent)
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                models = result
                selected.formIntersection(Set(result))
                modelTable.reloadData()
                if result.isEmpty {
                    errorField.stringValue = GitL10n.text("No models found. Check the local ACP adapter and login.")
                }
            } catch {
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                errorField.stringValue = error.localizedDescription
                return
            }

            guard requestedAgent == .codex, !finished, !Task.isCancelled,
                  loadingID == id, agent == requestedAgent else { return }
            checkingUpdate = true
            updateStatus.stringValue = GitL10n.text("Checking for Codex ACP updates…")
            updateButtons()
            do {
                let result = try await GitACPAdapterManager.checkCodexUpdate()
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                updateInfo = result
                updateStatus.stringValue = updateInfo.flatMap { info in
                    info.updateAvailable
                        ? GitL10n.format("Codex ACP update available: {0} (installed: {1}).",
                                         info.latestVersion, info.installedVersion ?? GitL10n.text("not detected"))
                        : GitL10n.format("Codex ACP is up to date ({0}).", info.latestVersion)
                } ?? ""
            } catch {
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                updateStatus.stringValue = GitL10n.text(
                    "Could not check the Codex ACP version. Model loading is unaffected."
                )
            }
            checkingUpdate = false
            updateButtons()
        }
    }

    @objc private func confirmUpdate() {
        guard let info = updateInfo, info.updateAvailable, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = GitL10n.text("Update Codex ACP for OMG?")
        alert.informativeText = GitL10n.text(
            "OMG will install this stable Codex ACP version in its own Application Support folder. Your global npm installation will not be changed."
        )
        alert.addButton(withTitle: GitL10n.text("Update and reload"))
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await self?.updateCodexAndReload(version: info.latestVersion) }
        }
    }

    private func updateCodexAndReload(version: String) async {
        guard agent == .codex, !updating else { return }
        updating = true
        loading = true
        errorField.stringValue = ""
        spinner.setAnimating(true)
        updateButtons()
        defer {
            updating = false
            loading = false
            spinner.setAnimating(false)
            updateButtons()
        }
        do {
            try await GitACPAdapterManager.installCodex(version: version)
            let refreshed = try await GitCommitAIService.models(agent: .codex)
            guard agent == .codex else { return }
            updateInfo = try? await GitACPAdapterManager.checkCodexUpdate()
            if refreshed.isEmpty {
                errorField.stringValue = GitL10n.text(
                    "Codex ACP was updated, but no models were returned. The previous model list was kept."
                )
            } else {
                models = refreshed
                selected.formIntersection(Set(refreshed))
                updateStatus.stringValue = GitL10n.format("Codex ACP {0} updated; models reloaded.", version)
                modelTable.reloadData()
            }
        } catch {
            errorField.stringValue = GitL10n.format(
                "Could not update or reload Codex ACP. The previous model list was kept: {0}",
                error.localizedDescription
            )
        }
    }

    private func updateButtons() {
        guard isViewLoaded else { return }
        refreshPlaceholder()
        agentTabs.forEach { $0.isEnabled = !updating }
        searchField.isEnabled = !updating
        modelTable.isEnabled = !updating
        reloadButton.isEnabled = !loading && !updating
        addButton.isEnabled = !loading && !updating &&
            !GitCommitAIRoute.adding(agent: agent, models: Array(selected), to: []).isEmpty
        if let updateInfo {
            updateButton.isHidden = agent != .codex || !updateInfo.updateAvailable
            updateButton.title = GitL10n.text(updateInfo.installedVersion == nil ? "Install for OMG…" : "Update for OMG…")
            updateButton.isEnabled = !loading && !updating && !checkingUpdate
        } else {
            updateButton.isHidden = true
            updateButton.isEnabled = false
        }
    }

    @objc private func cancel() {
        reloadTask?.cancel()
        closePanel()
    }

    @objc private func addSelected() {
        let routes = GitCommitAIRoute.adding(agent: agent, models: models.filter(selected.contains), to: [])
        guard !routes.isEmpty, !loading, !updating else { return }
        add(agent, routes.map(\.model))
        closePanel()
    }

}

/// One Agent in the sheet's selector row: icon and name on a rounded tile.
@MainActor
final class GitCommitAgentTab: NSView {
    let agent: GitCommitAgent
    private let select: () -> Void
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { refresh() } }
    var isEnabled = true { didSet { refresh() } }

    init(agent: GitCommitAgent, select: @escaping () -> Void) {
        self.agent = agent
        self.select = select
        super.init(frame: .zero)
        icon.image = SupportedAgent(rawValue: agent.rawValue).flatMap { NSImage(named: $0.assetName) }
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.stringValue = agent.title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSStackView(views: [icon, label])
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(agent.title)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        alphaValue = isEnabled ? 1 : 0.5
        setAccessibilityValue(isSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            tile.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        } else {
            NSColor.labelColor.withAlphaComponent(hovering && isEnabled ? 0.10 : 0.05).setFill()
            tile.fill()
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        }
        tile.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if isEnabled { select() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        select()
        return true
    }
}

@MainActor
final class GitCommitAIModelCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, checked: Bool, row: Int, target: AnyObject, action: Selector) {
        checkbox.title = title
        checkbox.state = checked ? .on : .off
        checkbox.target = target
        checkbox.action = action
        checkbox.tag = row
    }
}
