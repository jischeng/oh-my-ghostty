import AppKit

/// One fixed-height row. Every badge opens the complete, copyable ref list.
final class GitRefBadgesView: NSView {
    static let maximumBadgeWidth: CGFloat = 104
    static let badgeHeight: CGFloat = 17

    struct Badge: Equatable {
        let decoration: GitRefDecoration
        let refs: [GitRefDecoration]
        let isCount: Bool
    }
    private var refs: [GitRefDecoration] = []
    private var rendered: [Badge] = []
    private var buttons: [NSButton] = []
    private(set) var popover: NSPopover?
    override var isFlipped: Bool { true }

    static func attributed(_ decoration: GitRefDecoration) -> NSAttributedString {
        let color = tint(for: decoration.kind)
        let symbol: String?
        switch decoration.kind {
        case .currentBranch: symbol = "arrow.triangle.branch"
        case .localBranch: symbol = "arrow.triangle.branch"
        case .remoteBranch: symbol = "network"
        case .tag: symbol = "tag.fill"
        case .head: symbol = nil
        }
        let text = NSMutableAttributedString(string: " ")
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: decoration.kind.rawValue)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [color])) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 11, height: 11)
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: " " + decoration.name + " ", attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ]))
        return text
    }

    private static func tint(for kind: GitRefDecorationKind) -> NSColor {
        switch kind {
        case .head, .currentBranch: .systemBlue
        case .localBranch: .systemGreen
        case .remoteBranch: .systemPurple
        case .tag: .systemOrange
        }
    }

    static func badges(for refs: [GitRefDecoration], width: CGFloat) -> [Badge] {
        let ordered = GitRefDecoration.orderedForDisplay(refs)
        func named(_ ref: GitRefDecoration) -> Badge { Badge(decoration: ref, refs: [ref], isCount: false) }
        func count(_ refs: [GitRefDecoration], kind: GitRefDecorationKind) -> [Badge] {
            refs.isEmpty ? [] : [Badge(decoration: .init(name: String(refs.count), kind: kind), refs: refs, isCount: true)]
        }
        func fits(_ values: [Badge]) -> Bool {
            var used: CGFloat = 0
            for (index, value) in values.enumerated() {
                used += badgeWidth(value) + (index == 0 ? 0 : 4)
                if used > width { return false }
            }
            return true
        }
        let all = ordered.map(named)
        if fits(all) { return all }
        let head = ordered.filter { $0.kind == .head }.map(named)
        let branches = ordered.filter { $0.kind != .head && $0.kind != .tag }
        let tags = ordered.filter { $0.kind == .tag }
        let primary = head + branches.prefix(1).map(named) +
            count(Array(branches.dropFirst()), kind: .localBranch) + count(tags, kind: .tag)
        if fits(primary) { return primary }
        let grouped = head + count(branches, kind: .localBranch) + count(tags, kind: .tag)
        if fits(grouped) { return grouped }
        return ordered.isEmpty ? [] : [Badge(decoration: .init(name: "\(ordered.count) refs", kind: .head),
                                              refs: ordered, isCount: true)]
    }

    private static func badgeWidth(_ badge: Badge) -> CGFloat {
        min(maximumBadgeWidth, ceil(attributed(badge.decoration).size().width) + 4)
    }

    static func height(for refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        refs.isEmpty ? 0 : badgeHeight
    }

    func configure(_ refs: [GitRefDecoration]) {
        if self.refs != refs { popover?.close() }
        self.refs = refs
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { popover?.close() }
    }

    override func layout() {
        super.layout()
        let next = Self.badges(for: refs, width: bounds.width)
        if next != rendered {
            buttons.forEach { $0.removeFromSuperview() }
            rendered = next
            buttons = next.map { badge in
                let button = NSButton()
                button.isBordered = false
                button.alignment = .left
                button.controlSize = .small
                button.attributedTitle = Self.attributed(badge.decoration)
                button.cell?.lineBreakMode = .byTruncatingTail
                button.wantsLayer = true
                button.layer?.cornerRadius = 3
                button.target = self
                button.action = #selector(showRefs(_:))
                button.toolTip = badge.refs.map(\.name).joined(separator: "\n")
                button.setAccessibilityLabel(button.toolTip)
                button.setAccessibilityHelp("Show complete refs")
                addSubview(button)
                return button
            }
        }
        var x: CGFloat = 0
        for (button, badge) in zip(buttons, rendered) {
            let width = min(Self.badgeWidth(badge), max(0, bounds.width - x))
            button.frame = NSRect(x: x, y: 0, width: width, height: Self.badgeHeight)
            button.layer?.backgroundColor = Self.tint(for: badge.decoration.kind).withAlphaComponent(0.10).cgColor
            x += width + 4
        }
    }

    @objc private func showRefs(_ sender: NSButton) {
        popover?.close()
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 11)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        view.string = Self.fullText(for: refs)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: 360, height: layout.usedRect(for: container).height + 20))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(320, max(60, view.frame.height))))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = scroll.frame.size
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }

    static func fullText(for refs: [GitRefDecoration]) -> String {
        let groups: [(String, [GitRefDecorationKind])] = [
            ("HEAD", [.head]), ("Branches", [.currentBranch, .localBranch]),
            ("Remote branches", [.remoteBranch]), ("Tags", [.tag]),
        ]
        let ordered = GitRefDecoration.orderedForDisplay(refs)
        return groups.compactMap { title, kinds in
            let names = ordered.filter { kinds.contains($0.kind) }.map(\.name)
            if title == "HEAD", names == ["HEAD"] { return "HEAD" }
            return names.isEmpty ? nil : title + "\n" + names.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
