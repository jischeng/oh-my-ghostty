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
        // The content view otherwise shrinks the sheet to its narrowest fitting width
        // or collapses NSScrollView-backed sheets to zero content height.
        controller.view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        let minHeight = controller.view.heightAnchor.constraint(greaterThanOrEqualToConstant: size.height)
        minHeight.priority = .defaultHigh
        minHeight.isActive = true
        panel.setContentSize(size)
        panel.contentMinSize = size
        (controller.view as? OMGNativeSurfaceView)?.bindTheme(to: parent)
        parent.beginSheet(panel) { _ in controller.sheetEnded() }
    }
}

@MainActor
class GitCommitSettingsPanelController: NSViewController, NSWindowDelegate {
    private(set) var finished = false
    private weak var panelWindow: NSWindow?
    private var closeCompletions: [() -> Void] = []
    var onSheetDidEnd: (() -> Void)?

    override func viewDidAppear() {
        super.viewDidAppear()
        panelWindow = view.window
        panelWindow?.delegate = self
    }

    func closePanel(completion: (() -> Void)? = nil) {
        if finished {
            if let completion {
                if (panelWindow ?? view.window)?.sheetParent != nil {
                    closeCompletions.append(completion)
                } else {
                    completion()
                }
            }
            return
        }
        finished = true
        guard let window = panelWindow ?? view.window else {
            didEndSheet()
            onSheetDidEnd?()
            completion?()
            return
        }
        if let parent = window.sheetParent {
            if let completion {
                closeCompletions.append(completion)
            }
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
            didEndSheet()
            onSheetDidEnd?()
            completion?()
        }
    }

    func sheetEnded() {
        finished = true
        let panel = panelWindow ?? view.window
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panelWindow = nil
        didEndSheet()
        onSheetDidEnd?()
        let completions = closeCompletions
        closeCompletions.removeAll()
        for completion in completions {
            completion()
        }
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
