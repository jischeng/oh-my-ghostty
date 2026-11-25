import AppKit

/// The models of one provider as a compact list. For an API connection each row also
/// edits the model's context window and maximum output and can remove the model; for
/// an installed agent the list is read-only.
@MainActor
final class AIModelListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 24
    static let maxVisibleRows = 10
    /// Lists longer than this show the filter field.
    static let filterThreshold = 8
    fileprivate static let limitFieldWidth: CGFloat = 104
    fileprivate static let removeButtonWidth: CGFloat = 24

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
        let trailing = AIModelListCell.trailingInset + Self.removeButtonWidth + AIModelListCell.spacing
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
        cell.configure(visible[row], showsDivider: row > 0)
        cell.onCommit = { [weak self] in self?.commit($0) }
        cell.onRemove = { [weak self] in self?.onRemove?($0) }
        return cell
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
    fileprivate static let spacing: CGFloat = 8

    private let strings: SettingsStrings
    private let idField = NSTextField(labelWithString: "")
    let contextField = NSTextField()
    let outputField = NSTextField()
    let removeButton = NSButton()
    private var model = AIProviderModel(id: "")
    private var showsDivider = false
    var onCommit: ((AIProviderModel) -> Void)?
    var onRemove: ((String) -> Void)?

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
            let label = strings.t("Remove model", "移除模型")
            removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: label)
            removeButton.bezelStyle = .accessoryBar
            removeButton.isBordered = false
            removeButton.target = self
            removeButton.action = #selector(remove)
            removeButton.toolTip = label
            removeButton.setAccessibilityIdentifier("settings.ai.model.remove")
            removeButton.widthAnchor.constraint(equalToConstant: AIModelListController.removeButtonWidth).isActive = true
            views.append(removeButton)
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

    func configure(_ model: AIProviderModel, showsDivider: Bool) {
        self.model = model
        self.showsDivider = showsDivider
        idField.stringValue = model.id
        idField.toolTip = model.id
        contextField.stringValue = model.contextWindow.map(String.init) ?? ""
        outputField.stringValue = model.maxOutputTokens.map(String.init) ?? ""
        contextField.setAccessibilityLabel(strings.t("Context window", "上下文窗口") + ", " + model.id)
        outputField.setAccessibilityLabel(strings.t("Max output", "最大输出") + ", " + model.id)
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
