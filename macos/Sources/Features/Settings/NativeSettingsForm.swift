import AppKit

final class SettingsActionButton: NSButton {
    var invoke: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        self.action = #selector(performAction)
        invoke = action
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { invoke?() }
}

final class SettingsSwitch: NSSwitch {
    var change: ((Bool) -> Void)?
    init(value: Bool, change: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        state = value ? .on : .off
        self.change = change
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { change?(state == .on) }
}

final class SettingsPopup: NSPopUpButton {
    var change: ((Int) -> Void)?
    /// Choices shown but not selectable, e.g. ones another setting already uses.
    var disabledIndices: Set<Int> = []
    init(titles: [String], selected: Int, change: @escaping (Int) -> Void) {
        super.init(frame: .zero, pullsDown: false)
        let choices = NSMenu()
        for title in titles { choices.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        menu = choices
        selectItem(at: selected)
        self.change = change
        target = self
        action = #selector(changed)
        widthAnchor.constraint(equalToConstant: 200).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { change?(indexOfSelectedItem) }

    /// Open the choices below the control, as wide as it, instead of the stock
    /// pop-up that covers the control and its neighbouring rows.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        // A separate menu: items of the pop-up's own menu are re-targeted by
        // AppKit, which selects the title without reporting the change.
        let dropdown = NSMenu()
        dropdown.autoenablesItems = false
        dropdown.minimumWidth = bounds.width
        for (index, title) in itemTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.isEnabled = !disabledIndices.contains(index)
            item.state = index == indexOfSelectedItem ? .on : .off
            dropdown.addItem(item)
        }
        dropdown.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 5 : -5), in: self)
    }
    @objc private func pick(_ item: NSMenuItem) {
        guard item.tag != indexOfSelectedItem else { return }
        selectItem(at: item.tag)
        changed()
    }
}

final class SettingsTextField: NSTextField, NSTextFieldDelegate {
    var commit: ((String) -> Void)?
    init(_ value: String, placeholder: String = "", commit: @escaping (String) -> Void) {
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        self.commit = commit
        delegate = self
        bezelStyle = .roundedBezel
        lineBreakMode = .byTruncatingMiddle
        widthAnchor.constraint(equalToConstant: 220).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidEndEditing(_ obj: Notification) { commit?(stringValue) }
}

final class SettingsNumberField: NSStackView, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    private let range: ClosedRange<Double>
    private let change: (Double) -> Void
    init(value: Double, range: ClosedRange<Double>, step: Double, change: @escaping (Double) -> Void) {
        self.range = range
        self.change = change
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.maximumFractionDigits = step < 1 ? 2 : 0
        field.formatter = formatter
        field.doubleValue = value
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.doubleValue = value
        field.target = self
        field.delegate = self
        field.action = #selector(fieldChanged)
        stepper.target = self
        stepper.action = #selector(stepChanged)
        addArrangedSubview(field)
        addArrangedSubview(stepper)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fieldChanged() { set(field.doubleValue) }
    func controlTextDidEndEditing(_ obj: Notification) { set(field.doubleValue) }
    @objc private func stepChanged() { set(stepper.doubleValue) }
    private func set(_ value: Double) {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        field.doubleValue = clamped
        stepper.doubleValue = clamped
        change(clamped)
    }
}

final class SettingsSlider: NSStackView {
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "")
    private let change: (Double) -> Void
    init(value: Double, minimum: Double = 0.05, change: @escaping (Double) -> Void) {
        self.change = change
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        slider.minValue = minimum * 100
        slider.maxValue = 100
        slider.doubleValue = value * 100
        slider.target = self
        slider.action = #selector(changed)
        label.stringValue = "\(Int(value * 100))%"
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true
        label.alignment = .right
        addArrangedSubview(slider)
        addArrangedSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() {
        slider.doubleValue = (slider.doubleValue / 5).rounded() * 5
        label.stringValue = "\(Int(slider.doubleValue))%"
        change(slider.doubleValue / 100)
    }
    func setValue(_ value: Double) {
        slider.doubleValue = value * 100
        label.stringValue = "\(Int(value * 100))%"
    }
}

final class SettingsDatePicker: NSDatePicker {
    var change: ((Date) -> Void)?
    init(value: Date, change: @escaping (Date) -> Void) {
        super.init(frame: .zero)
        datePickerStyle = .textFieldAndStepper
        datePickerElements = [.yearMonthDay, .hourMinute]
        dateValue = value
        self.change = change
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { change?(dateValue) }
}

final class NativeSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A scroll area nested in a settings page. Once it reaches an edge, the wheel
/// moves the page instead of leaving the pointer stuck over the inner list.
final class SettingsNestedScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let visible = contentView.bounds
        let height = documentView?.frame.height ?? 0
        let flipped = documentView?.isFlipped ?? true
        let towardStart = flipped ? event.scrollingDeltaY > 0 : event.scrollingDeltaY < 0
        let atStart = visible.minY <= 0
        let atEnd = visible.maxY >= height - 0.5
        if event.scrollingDeltaY != 0, towardStart ? atStart : atEnd {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Hosts a navigation row and shows that the whole row is clickable.
final class SettingsLinkRowView: NSView {
    private var hovering = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        bounds.fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

struct NativeSettingsRow {
    let view: NSStackView
    let labels: NSStackView
    let separator: NSView?
    func setVisible(_ visible: Bool) { view.isHidden = !visible; separator?.isHidden = !visible }
    @MainActor func setSubtitle(_ text: String) {
        if let existing = labels.arrangedSubviews.dropFirst().first as? NSTextField {
            existing.stringValue = text
            existing.isHidden = text.isEmpty
        } else if !text.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: text)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.required, for: .vertical)
            labels.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
    }
    @MainActor var subtitleText: String? {
        (labels.arrangedSubviews.dropFirst().first as? NSTextField)?.stringValue
    }
}

@MainActor
final class NativeSettingsForm: NSViewController {
    let stack = NSStackView()
    private var group: NSStackView?
    private var rowCount = 0
    private(set) var rowTitles: [String] = []
    private(set) var controls: [NSView] = []
    var retained: [AnyObject] = []
    var refreshers: [() -> Void] = []
    private var anchors: [String: NSView] = [:]
    private var boxes: [NSBox] = []
    private var palette: OMGThemePalette?
    /// Divider above the most recent `embed`, for callers that hide an empty embed.
    private(set) var embedSeparator: NSView?

    func applyPalette(_ palette: OMGThemePalette) {
        self.palette = palette
        for box in boxes {
            box.fillColor = palette.background.blended(withFraction: 0.045, of: palette.foreground) ?? palette.background
            box.borderColor = palette.foreground.withAlphaComponent(0.12)
        }
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Overlay scrollers keep every page's column width identical.
        scroll.scrollerStyle = .overlay
        let document = NativeSettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        view = scroll
        // Fill the window up to a readable width instead of stretching rows on wide windows.
        let fill = stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            fill,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
    }

    func section(_ title: String, caption: String? = nil) {
        _ = view
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!) }
        stack.addArrangedSubview(label)
        anchors[title] = label
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
        boxes.append(box)
        if let palette { applyPalette(palette) }
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = rows
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            rows.topAnchor.constraint(equalTo: box.topAnchor),
            rows.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        group = rows
        rowCount = 0
        if let caption { note(caption) }
    }

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @discardableResult
    func row(_ title: String, subtitle: String? = nil, control: NSView, help: String? = nil) -> NativeSettingsRow? {
        guard let group else { return nil }
        // Explanations stay visible in the row; a tooltip alone is undiscoverable.
        let subtitle = subtitle ?? help
        rowTitles.append(title)
        controls.append(control)
        var divider: NSView?
        if rowCount > 0 {
            let separator = NSBox()
            separator.boxType = .separator
            group.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            divider = separator
        }
        rowCount += 1
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 20
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setClippingResistancePriority(.required, for: .vertical)
        labels.setHuggingPriority(.required, for: .vertical)
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        labels.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        if let subtitle, !subtitle.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: subtitle)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.required, for: .vertical)
            labels.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let stack = control as? NSStackView {
            stack.setHuggingPriority(.required, for: .horizontal)
            stack.widthAnchor.constraint(equalToConstant: stack.fittingSize.width).isActive = true
        }
        control.setAccessibilityLabel(title)
        control.toolTip = help
        row.addArrangedSubview(labels)
        row.addArrangedSubview(control)
        group.addArrangedSubview(row)
        anchors[title] = row
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: group.widthAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: labels.heightAnchor, constant: 24),
            row.heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor, constant: 24)
        ])
        return NativeSettingsRow(view: row, labels: labels, separator: divider)
    }

    func link(_ title: String, subtitle: String? = nil, action: @escaping () -> Void) {
        let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.widthAnchor.constraint(equalToConstant: 14).isActive = true
        arrow.setAccessibilityElement(false)
        guard let row = row(title, subtitle: subtitle, control: arrow) else { return }
        let button = SettingsActionButton("", action: action)
        button.isTransparent = true
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        guard let group else { return }
        // Keep the hit target outside NSStackView's arranged layout.
        group.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
        let container = SettingsLinkRowView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row.view)
        container.addSubview(button)
        group.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: group.widthAnchor),
            row.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.view.topAnchor.constraint(equalTo: container.topAnchor),
            row.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func toggle(_ title: String, value: Bool, help: String? = nil, change: @escaping (Bool) -> Void) {
        row(title, control: SettingsSwitch(value: value, change: change), help: help)
    }

    func scrollTo(_ title: String) {
        view.layoutSubtreeIfNeeded()
        guard let anchor = anchors[title] else { return }
        anchor.scrollToVisible(anchor.bounds)
    }

    @discardableResult
    func embed(_ child: NSView, height: CGFloat) -> NSLayoutConstraint? {
        guard let group else { return nil }
        embedSeparator = nil
        if rowCount > 0 {
            let separator = NSBox()
            separator.boxType = .separator
            group.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            embedSeparator = separator
        }
        rowCount += 1
        group.addArrangedSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        let constraint = child.heightAnchor.constraint(equalToConstant: height)
        constraint.isActive = true
        return constraint
    }

    func addCustomRow(_ child: NSView) {
        guard let group else { return }
        if rowCount > 0 {
            let separator = NSBox()
            separator.boxType = .separator
            group.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        rowCount += 1
        child.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
    }
}
