import AppKit

/// The models of one provider as a compact list. For an API connection each row also
/// edits the model's context window and maximum output, reorders models, and can remove
/// a model; for an installed agent the list is read-only.
@MainActor
final class AIModelListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 24
    static let maxVisibleRows = 10
    /// Lists longer than this show the filter field.
    static let filterThreshold = 8
    fileprivate static let limitFieldWidth: CGFloat = 96
    fileprivate static let actionButtonWidth: CGFloat = 22

    let editable: Bool
    let table: NSTableView = AIModelTableView()
    /// Narrows a long list. The owner places it; this controller reads it.
    let filterField = NSSearchField()
    private let strings: SettingsStrings
    private(set) var models: [AIProviderModel] = []
    private var query = ""
    /// A model's limits were edited.
    var onChange: ((AIProviderModel) -> Void)?
    var onRemove: ((String) -> Void)?
    /// The model list order changed via drag or up/down buttons.
    var onReorder: (([AIProviderModel]) -> Void)?
    /// The height that shows the current rows changed.
    var onHeightChange: ((CGFloat) -> Void)?

    init(editable: Bool, strings: SettingsStrings) {
        self.editable = editable
        self.strings = strings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var visibleModels: [AIProviderModel] {
        models.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
    }

    /// Height for the rows on show, capped so a long list scrolls inside the page.
    var preferredHeight: CGFloat {
        let rows = min(visibleModels.count, Self.maxVisibleRows)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * Self.rowHeight + (editable ? Self.headerHeight : 0)
    }

    override func loadView() {
        let scroll = SettingsNestedScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if editable {
            table.draggingDestinationFeedbackStyle = .gap
            table.registerForDraggedTypes([.string])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
        }
        let column = NSTableColumn(identifier: .init("model"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(strings.t("Models", "模型"))
        table.setAccessibilityIdentifier("settings.ai.models")
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = strings.t("Filter models…", "筛选模型…")
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityIdentifier("settings.ai.models.filter")
        filterField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let root = NSView()
        root.addSubview(scroll)
        var constraints = [
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        if editable {
            let header = columnHeader()
            root.addSubview(header)
            constraints += [
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                header.topAnchor.constraint(equalTo: root.topAnchor),
                header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
                scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            ]
        } else {
            constraints.append(scroll.topAnchor.constraint(equalTo: root.topAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        view = root
    }

    /// Names the two number columns, laid out with the same widths as the cells.
    private func columnHeader() -> NSView {
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        let name = label(strings.t("Model ID", "模型 ID"))
        let context = label(strings.t("Context window", "上下文窗口"))
        let output = label(strings.t("Max output", "最大输出"))
        let header = NSView()
        for view in [name, context, output] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        let actionCount: CGFloat = 3
        let trailing = AIModelListCell.trailingInset
            + actionCount * Self.actionButtonWidth
            + actionCount * AIModelListCell.spacing
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: AIModelListCell.leadingInset),
            name.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: context.leadingAnchor, constant: -AIModelListCell.spacing),
            output.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -trailing),
            output.widthAnchor.constraint(equalToConstant: Self.limitFieldWidth),
            output.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            context.trailingAnchor.constraint(equalTo: output.leadingAnchor, constant: -AIModelListCell.spacing),
            context.widthAnchor.constraint(equalToConstant: Self.limitFieldWidth),
            context.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    /// Shows `models`. An unchanged list is left alone so a field being edited keeps its text.
    func setModels(_ models: [AIProviderModel]) {
        guard models != self.models else { return }
        self.models = models
        reload()
    }

    @discardableResult
    func moveModel(_ id: String, by delta: Int) -> Bool {
        guard editable, query.isEmpty,
              let source = models.firstIndex(where: { $0.id == id }),
              models.indices.contains(source + delta) else { return false }
        models.swapAt(source, source + delta)
        table.reloadData()
        onReorder?(models)
        return true
    }

    private func reload() {
        _ = view
        table.reloadData()
        onHeightChange?(preferredHeight)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let visible = visibleModels
        guard visible.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("settings.ai.model-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? AIModelListCell
            ?? AIModelListCell(editable: editable, strings: strings)
        cell.identifier = identifier
        let canReorder = editable && query.isEmpty && visible.count > 1
        cell.configure(
            visible[row],
            showsDivider: row > 0,
            canMoveUp: canReorder && row > 0,
            canMoveDown: canReorder && row + 1 < visible.count
        )
        cell.onCommit = { [weak self] in self?.commit($0) }
        cell.onRemove = { [weak self] in self?.onRemove?($0) }
        cell.onMove = { [weak self] id, delta in _ = self?.moveModel(id, by: delta) }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard editable, query.isEmpty, models.indices.contains(row) else { return nil }
        return models[row].id as NSString
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard editable, query.isEmpty, operation == .above,
              info.draggingSourceOperationMask.contains(.move),
              let id = info.draggingPasteboard.string(forType: .string),
              models.contains(where: { $0.id == id }) else {
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
        guard editable, query.isEmpty,
              let id = info.draggingPasteboard.string(forType: .string),
              let source = models.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let insertion = min(max(row, 0), models.count)
        let destination = insertion > source ? insertion - 1 : insertion
        guard destination != source else { return true }
        let item = models.remove(at: source)
        models.insert(item, at: min(destination, models.count))
        table.reloadData()
        onReorder?(models)
        return true
    }

    private func commit(_ model: AIProviderModel) {
        guard let index = models.firstIndex(where: { $0.id == model.id }), models[index] != model else { return }
        models[index] = model
        onChange?(model)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === filterField else { return }
        query = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }
}

/// Lets a limit field take focus on the first click. A stock table view makes a text
/// field in an unselected row wait for a second click.
private final class AIModelTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class AIModelListCell: NSTableCellView, NSTextFieldDelegate {
    fileprivate static let leadingInset: CGFloat = 16
    fileprivate static let trailingInset: CGFloat = 12
    fileprivate static let spacing: CGFloat = 6

    private let strings: SettingsStrings
    private let idField = NSTextField(labelWithString: "")
    let contextField = NSTextField()
    let outputField = NSTextField()
    let upButton = NSButton()
    let downButton = NSButton()
    let removeButton = NSButton()
    private var model = AIProviderModel(id: "")
    private var showsDivider = false
    var onCommit: ((AIProviderModel) -> Void)?
    var onRemove: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?

    init(editable: Bool, strings: SettingsStrings) {
        self.strings = strings
        super.init(frame: .zero)
        idField.font = .systemFont(ofSize: 12)
        idField.lineBreakMode = .byTruncatingMiddle
        idField.isSelectable = true
        idField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        idField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [idField]
        if editable {
            for (field, identifier) in [(contextField, "settings.ai.model.context-window"),
                                        (outputField, "settings.ai.model.max-output")] {
                field.bezelStyle = .roundedBezel
                field.alignment = .right
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                field.placeholderString = strings.t("Default", "默认")
                field.delegate = self
                field.setAccessibilityIdentifier(identifier)
                field.widthAnchor.constraint(equalToConstant: AIModelListController.limitFieldWidth).isActive = true
                views.append(field)
            }
            configureAction(
                upButton,
                symbol: "arrow.up",
                label: strings.t("Move up", "上移"),
                identifier: "settings.ai.model.move-up",
                action: #selector(moveModelUp)
            )
            configureAction(
                downButton,
                symbol: "arrow.down",
                label: strings.t("Move down", "下移"),
                identifier: "settings.ai.model.move-down",
                action: #selector(moveModelDown)
            )
            configureAction(
                removeButton,
                symbol: "minus.circle",
                label: strings.t("Remove model", "移除模型"),
                identifier: "settings.ai.model.remove",
                action: #selector(remove)
            )
            views.append(contentsOf: [upButton, downButton, removeButton])
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = Self.spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureAction(
        _ button: NSButton,
        symbol: String,
        label: String,
        identifier: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityIdentifier(identifier)
        button.widthAnchor.constraint(equalToConstant: AIModelListController.actionButtonWidth).isActive = true
    }

    func configure(
        _ model: AIProviderModel,
        showsDivider: Bool,
        canMoveUp: Bool = false,
        canMoveDown: Bool = false
    ) {
        self.model = model
        self.showsDivider = showsDivider
        idField.stringValue = model.id
        idField.toolTip = model.id
        contextField.stringValue = model.contextWindow.map(String.init) ?? ""
        outputField.stringValue = model.maxOutputTokens.map(String.init) ?? ""
        contextField.setAccessibilityLabel(strings.t("Context window", "上下文窗口") + ", " + model.id)
        outputField.setAccessibilityLabel(strings.t("Max output", "最大输出") + ", " + model.id)
        upButton.isEnabled = canMoveUp
        downButton.isEnabled = canMoveDown
        upButton.setAccessibilityLabel(strings.t("Move up", "上移") + ", " + model.id)
        downButton.setAccessibilityLabel(strings.t("Move down", "下移") + ", " + model.id)
        removeButton.setAccessibilityLabel(strings.t("Remove model", "移除模型") + ", " + model.id)
        setAccessibilityLabel(model.id)
        needsDisplay = true
    }

    /// Reads both fields, shows them as stored, and reports the model when a limit changed.
    func controlTextDidEndEditing(_ notification: Notification) {
        var edited = model
        edited.contextWindow = AIProviderModel.limit(contextField.stringValue)
        edited.maxOutputTokens = AIProviderModel.limit(outputField.stringValue)
        contextField.stringValue = edited.contextWindow.map(String.init) ?? ""
        outputField.stringValue = edited.maxOutputTokens.map(String.init) ?? ""
        guard edited != model else { return }
        model = edited
        onCommit?(edited)
    }

    @objc private func moveModelUp() {
        onMove?(model.id, -1)
    }

    @objc private func moveModelDown() {
        onMove?(model.id, 1)
    }

    @objc private func remove() {
        onRemove?(model.id)
    }

    /// Hairline between rows only, inset like the form's own rows.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsDivider else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: Self.leadingInset, y: isFlipped ? 0 : bounds.maxY - 1,
               width: bounds.width - Self.leadingInset, height: 1).fill()
    }
}
