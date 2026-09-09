import AppKit

/// One fixed-height row. Every badge opens the complete, copyable ref list.
final class GitRefBadgesView: NSView {
    static let maximumBadgeWidth: CGFloat = 104
    static let badgeHeight: CGFloat = 17

    struct Badge: Equatable {
        let decoration: GitRefDecoration
        let refs: [GitRefDecoration]
        let isCount: Bool
        var widthLimit: CGFloat = GitRefBadgesView.maximumBadgeWidth
    }
    private var refs: [GitRefDecoration] = []
    private var rendered: [Badge] = []
    private var buttons: [NSButton] = []
    private(set) var popover: NSPopover?
    override var isFlipped: Bool { true }

    static func attributed(_ decoration: GitRefDecoration) -> NSAttributedString {
        let color = tint(for: decoration.kind)
        let symbol = symbol(for: decoration.kind)
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

    static func symbol(for kind: GitRefDecorationKind) -> String? {
        switch kind {
        case .currentBranch, .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "network"
        case .tag: "tag.fill"
        case .head: "circle.inset.filled"
        }
    }

    static func tint(for kind: GitRefDecorationKind) -> NSColor {
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
        func fit(_ values: [Badge]) -> [Badge]? {
            var widths = values.map(badgeWidth)
            let minimums = zip(values, widths).map { badge, width in
                badge.isCount || badge.decoration.kind == .head ? width : min(48, width)
            }
            let gaps = CGFloat(max(0, values.count - 1)) * 4
            guard minimums.reduce(0, +) + gaps <= width else { return nil }
            var excess = max(0, widths.reduce(0, +) + gaps - width)
            // Keep a readable tag before sacrificing its name to an aggregate.
            let indices = values.indices.sorted { (values[$0].decoration.kind == .tag ? 1 : 0) < (values[$1].decoration.kind == .tag ? 1 : 0) }
            for index in indices {
                let removed = min(excess, widths[index] - minimums[index])
                widths[index] -= removed
                excess -= removed
            }
            return values.enumerated().map { index, badge in
                var badge = badge
                badge.widthLimit = widths[index]
                return badge
            }
        }
        let head = ordered.filter { $0.kind == .head }.map(named)
        let branches = ordered.filter { $0.kind != .head && $0.kind != .tag }
        let tags = ordered.filter { $0.kind == .tag }
        let tagBadges = tags.prefix(1).map(named) + count(Array(tags.dropFirst()), kind: .tag)
        if let all = fit(head + branches.map(named) + tagBadges) { return all }
        let primary = head + branches.prefix(1).map(named) + count(Array(branches.dropFirst()), kind: .localBranch) + tagBadges
        if let result = fit(primary) { return result }
        if let result = fit(head + count(branches, kind: .localBranch) + tagBadges) { return result }
        let others = ordered.filter { $0.kind != .tag }
        let otherBadge = others.isEmpty ? [] : [Badge(decoration: .init(name: "\(others.count) refs", kind: .head), refs: others, isCount: true)]
        if let result = fit(otherBadge + tagBadges) { return result }
        return ordered.isEmpty ? [] : [Badge(decoration: .init(name: "\(ordered.count) refs", kind: .head), refs: ordered, isCount: true)]
    }

    private static func badgeWidth(_ badge: Badge) -> CGFloat {
        min(badge.widthLimit, ceil(attributed(badge.decoration).size().width) + 4)
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
        let view = GitRefListView()
        view.configure(refs)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: GitRefListView.height(for: refs, width: 360))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(320, max(60, view.frame.height))))
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
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
