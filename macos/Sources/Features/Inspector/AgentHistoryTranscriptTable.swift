import AppKit
import SwiftUI

/// AppKit-backed transcript renderer. NSTableView reuses only visible rows and
/// caches dynamic row heights, avoiding SwiftUI's repeated whole-list text
/// measurement during high-velocity scrolling.
struct AgentHistoryTranscriptTable: NSViewRepresentable {
    let messages: [AgentHistoryMessage]
    let agentName: String
    let strings: AgentHistoryStrings
    let highlightText: String
    /// nil when the session's Agent has no native fork; hides the action.
    let onFork: (() -> Void)?
    var onFind: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AgentHistoryTranscriptScrollView()
        scrollView.onFind = onFind
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 48

        let column = NSTableColumn(identifier: .init("agent-history-message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        context.coordinator.update(
            messages: messages,
            agentName: agentName,
            strings: strings,
            highlightText: highlightText,
            onFork: onFork
        )
        context.coordinator.updateWidth(scrollView.contentSize.width)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? AgentHistoryTranscriptScrollView)?.onFind = onFind
        context.coordinator.update(
            messages: messages,
            agentName: agentName,
            strings: strings,
            highlightText: highlightText,
            onFork: onFork
        )
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        tableView.sizeLastColumnToFit()
        context.coordinator.updateWidth(scrollView.contentSize.width)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var messages: [AgentHistoryMessage] = []
        private var agentName = "Agent"
        private var strings = AgentHistoryStrings()
        private var highlightText = ""
        private var onFork: (() -> Void)?
        private var lastWidth: CGFloat = 0

        func update(
            messages: [AgentHistoryMessage],
            agentName: String,
            strings: AgentHistoryStrings,
            highlightText: String,
            onFork: (() -> Void)?
        ) {
            let contentChanged = self.messages != messages ||
                self.agentName != agentName ||
                self.strings != strings ||
                self.highlightText != highlightText ||
                (self.onFork == nil) != (onFork == nil)
            self.messages = messages
            self.agentName = agentName
            self.strings = strings
            self.highlightText = highlightText
            self.onFork = onFork
            guard contentChanged, let tableView else { return }
            tableView.reloadData()
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<messages.count)
            )
        }

        func updateWidth(_ width: CGFloat) {
            guard abs(lastWidth - width) > 1, let tableView else { return }
            lastWidth = width
            guard !messages.isEmpty else { return }
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<messages.count)
            )
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            messages.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard messages.indices.contains(row) else { return nil }
            let identifier = AgentHistoryTranscriptCell.reuseIdentifier
            let cell = tableView.makeView(
                withIdentifier: identifier,
                owner: nil
            ) as? AgentHistoryTranscriptCell ?? AgentHistoryTranscriptCell()
            cell.identifier = identifier
            cell.configure(
                message: messages[row],
                agentName: agentName,
                strings: strings,
                highlightText: highlightText,
                onFork: onFork
            )
            return cell
        }
    }
}

final class AgentHistoryTranscriptScrollView: NSScrollView {
    var onFind: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AgentHistoryFindShortcut.accepts(event, in: self) {
            onFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class AgentHistoryTranscriptCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "agent-history-transcript-cell"
    )

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private let roleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let copyButton = CopyFeedbackIconButton()
    private let forkButton = NSButton()
    private let actionStack = NSStackView()
    private let bodyStack = NSStackView()
    private let contentStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var onFork: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        roleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        roleLabel.setContentHuggingPriority(.required, for: .vertical)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor

        configureButton(
            forkButton,
            symbol: "arrow.triangle.branch",
            action: #selector(forkMessage)
        )
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.addArrangedSubview(copyButton)
        actionStack.addArrangedSubview(forkButton)
        actionStack.alphaValue = 0

        let headerStack = NSStackView(views: [roleLabel, timeLabel, NSView(), actionStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 6

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 5
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(headerStack)
        contentStack.addArrangedSubview(bodyStack)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            headerStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        actionStack.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        actionStack.alphaValue = 0
    }

    func configure(
        message: AgentHistoryMessage,
        agentName: String,
        strings: AgentHistoryStrings,
        highlightText: String,
        onFork: (() -> Void)?
    ) {
        self.onFork = onFork
        let isUser = message.role == .user
        roleLabel.stringValue = isUser ? strings.you : agentName
        roleLabel.textColor = isUser ? .controlAccentColor : .secondaryLabelColor
        timeLabel.stringValue = message.timestamp.map(Self.timeFormatter.string(from:)) ?? ""
        timeLabel.isHidden = message.timestamp == nil
        // The user's turns are the landmarks of a transcript; replies read as
        // plain text between them.
        layer?.backgroundColor = isUser
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        copyButton.configure(symbol: "doc.on.doc", value: message.text, tooltip: strings.copyMessage)
        forkButton.toolTip = strings.forkSession
        forkButton.isHidden = isUser || onFork == nil

        bodyStack.arrangedSubviews.forEach { view in
            bodyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for block in AgentHistoryMarkdown.blocks(message.text) {
            let view: NSView
            switch block {
            case .prose(let text):
                view = Self.proseField(AgentHistoryMarkdown.highlighting(text, term: highlightText))
            case .code(let code):
                view = AgentHistoryCodeBlockView(code: code, highlight: highlightText)
            }
            bodyStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }
    }

    private static func proseField(_ text: NSAttributedString) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        // Without this, selecting text resets a label to its plain font.
        field.allowsEditingTextAttributes = true
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.attributedStringValue = text
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        action: Selector
    ) {
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
    }

    @objc private func forkMessage() {
        onFork?()
    }
}

/// Code and tables keep their line structure in a fixed-width font on a quiet
/// background, wrapping by character so a narrow Inspector never clips them.
private final class AgentHistoryCodeBlockView: NSView {
    init(code: String, highlight: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 1.5
        let text = NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: AgentHistoryMarkdown.codeSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.attributedStringValue = AgentHistoryMarkdown.highlighting(text, term: highlight)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
