import AppKit

final class GitHistoryCell: NSTableCellView {
    private let subject = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private let email = NSTextField(labelWithString: "")
    private let badges = GitRefBadgesView()
    private let graph = GitGraphCellView()
    private let disclosure = NSButton()
    private var graphWidth: CGFloat = 15
    private var toggle: () -> Void = {}

    static func height(commit: GitHistoryCommit, refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        let badges = GitRefBadgesView.height(for: refs, width: width)
        return (commit.authorEmail.isEmpty ? 41 : 56) + (badges > 0 ? badges + 5 : 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        subject.font = .systemFont(ofSize: 12, weight: .medium)
        metadata.font = .systemFont(ofSize: 10)
        metadata.textColor = .secondaryLabelColor
        email.font = .systemFont(ofSize: 10)
        email.textColor = .secondaryLabelColor
        for label in [subject, metadata, email] {
            label.lineBreakMode = label === subject ? .byTruncatingTail : .byTruncatingMiddle
            label.maximumNumberOfLines = 1
        }
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleNone
        disclosure.controlSize = .small
        disclosure.focusRingType = .none
        disclosure.setButtonType(.momentaryChange)
        disclosure.target = self
        disclosure.action = #selector(toggleCommit)
        [graph, disclosure, subject, metadata, email, badges].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    @objc private func toggleCommit() { toggle() }

    func configure(commit: GitHistoryCommit, graph: GitGraphRow, graphLayout: (width: CGFloat, lanes: Int),
                   summary: (date: String, refs: [GitRefDecoration]), state: (head: Bool, expanded: Bool), toggle: @escaping () -> Void) {
        graphWidth = graphLayout.width
        self.toggle = toggle
        self.graph.configure(row: graph, isHead: state.head, laneCount: graphLayout.lanes,
                             section: state.expanded ? .expandedCommit : .commit)
        subject.stringValue = commit.subject.isEmpty ? "(no subject)" : commit.subject
        metadata.stringValue = "\(commit.authorName) · \(summary.date) · \(commit.id.shortSHA)"
        email.stringValue = commit.authorEmail
        email.isHidden = commit.authorEmail.isEmpty
        badges.configure(summary.refs)
        disclosure.image = NSImage(systemSymbolName: state.expanded ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: state.expanded ? "Collapse commit" : "Expand commit")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toolTip = "\(commit.subject)\n\(commit.authorName) <\(commit.authorEmail)>\n\(commit.authoredAt)\n\(commit.id.rawValue)"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: graphWidth, height: bounds.height)
        disclosure.frame = NSRect(x: graphWidth, y: 4, width: 18, height: 18)
        let x = graphWidth + 21
        let width = max(1, bounds.width - x - 8)
        subject.frame = NSRect(x: x, y: 4, width: width, height: 17)
        metadata.frame = NSRect(x: x, y: 23, width: width, height: 14)
        email.frame = NSRect(x: x, y: 39, width: width, height: 13)
        let badgeY: CGFloat = email.isHidden ? 41 : 56
        badges.frame = NSRect(x: x, y: badgeY, width: width, height: max(0, bounds.height - badgeY - 5))
    }
}

/// Child rows share the commit's graph gutter; they have no card background or
/// repeated summary. Files precede the optional, independently folded body.
final class GitHistoryDetailCell: NSTableCellView {
    enum Content {
        case files(Int, GitDiffStatistics?, Bool)
        case file(GitDiffFile)
        case message(String, Bool)
        case notice(String, Bool)
    }
    private let graph = GitGraphCellView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private let openIcon = NSImageView()
    private var graphWidth: CGFloat = 15
    private var content = Content.notice("", false)
    private var action: () -> Void = {}

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = .systemFont(ofSize: 11)
        cell.wraps = true
        cell.isScrollable = false
        cell.usesSingleLineMode = false
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width),
                                                   height: .greatestFiniteMagnitude)).height)
    }
    static func height(for content: Content, width: CGFloat) -> CGFloat {
        switch content {
        case .files: return 28
        case .file: return 23
        case .notice(let text, _): return max(26, textHeight(text, width: width) + 12)
        case .message(let text, let expanded):
            let height = textHeight(text, width: width)
            return height <= 56 ? height + 12 : (expanded ? height + 36 : 28)
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [graph, label, button, openIcon].forEach(addSubview)
        label.font = .systemFont(ofSize: 11)
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleNone
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.target = self
        button.action = #selector(activate)
        button.cell?.lineBreakMode = .byTruncatingTail
        openIcon.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        openIcon.contentTintColor = .tertiaryLabelColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    @objc private func activate() { action() }

    func configure(graph: GitGraphRow, graphWidth: CGFloat, laneCount: Int, isLast: Bool,
                   content: Content, action: @escaping () -> Void) {
        self.graphWidth = graphWidth
        self.graph.configure(row: graph, laneCount: laneCount, section: isLast ? .expansionEnd : .continuation)
        self.content = content
        self.action = action
        toolTip = nil
        if case .file(let file) = content {
            toolTip = "Open diff · " + file.kind.label + " · " + file.displayPath
            setAccessibilityRole(.button)
        } else { setAccessibilityRole(.group) }
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }
    override func accessibilityPerformPress() -> Bool {
        guard case .file = content else { return false }
        action()
        return true
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if case .file = content { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: graphWidth, height: bounds.height)
        let x = graphWidth + 21
        let width = max(1, bounds.width - x - 8)
        label.frame = NSRect(x: x, y: 6, width: width, height: max(1, bounds.height - 12))
        label.isHidden = false
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        button.toolTip = nil
        button.isHidden = true
        openIcon.isHidden = true
        switch content {
        case .files(let count, let stats, let collapsed):
            label.isHidden = true
            button.isHidden = false
            button.attributedTitle = Self.filesTitle(count: count, statistics: stats)
            button.image = Self.chevron(collapsed ? "right" : "down")
            button.frame = NSRect(x: x, y: 4, width: width, height: 20)
            button.toolTip = button.attributedTitle.string
        case .file(let file):
            label.isSelectable = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            let text = NSMutableAttributedString(string: file.kind.rawValue + "  ", attributes: [
                .foregroundColor: file.kind.color, .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            ])
            text.append(NSAttributedString(string: file.displayPath, attributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11),
            ]))
            label.attributedStringValue = text
            label.frame = NSRect(x: x + 12, y: 4, width: max(1, width - 26), height: 15)
            openIcon.isHidden = false
            openIcon.frame = NSRect(x: x + width - 10, y: 7, width: 8, height: 8)
        case .notice(let text, let isError):
            label.stringValue = text
            label.textColor = isError ? .systemRed : .secondaryLabelColor
        case .message(let text, let expanded):
            let height = Self.textHeight(text, width: width)
            let isLong = height > 56
            label.stringValue = text
            label.isHidden = isLong && !expanded
            if isLong {
                button.isHidden = false
                button.title = expanded ? "Show less" : "Commit message"
                button.image = Self.chevron(expanded ? "up" : "right")
                button.frame = NSRect(x: x, y: expanded ? height + 10 : 4, width: width, height: 20)
                label.frame.size.height = height
            }
        }
    }
    private static func chevron(_ direction: String) -> NSImage? {
        NSImage(systemSymbolName: "chevron." + direction, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
    }
    private static func filesTitle(count: Int, statistics: GitDiffStatistics?) -> NSAttributedString {
        let value = NSMutableAttributedString(string: "\(count) \(count == 1 ? "file" : "files") changed", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        if let statistics {
            value.append(NSAttributedString(string: " · +\(statistics.additions)", attributes: [.foregroundColor: NSColor.systemGreen]))
            value.append(NSAttributedString(string: " −\(statistics.deletions)", attributes: [.foregroundColor: NSColor.systemRed]))
            if statistics.binaryFiles > 0 {
                value.append(NSAttributedString(string: " · \(statistics.binaryFiles) binary", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        value.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .medium), range: NSRange(location: 0, length: value.length))
        return value
    }
}
