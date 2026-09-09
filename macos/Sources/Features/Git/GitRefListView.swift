import AppKit
import SwiftUI

/// Full ref names share the same colored symbols in popovers and the timeline.
/// Native selectable fields and explicit copy buttons expose untruncated values.
final class GitRefListView: NSView {
    private(set) var refs: [GitRefDecoration] = []
    private var rows: [Row] = []
    private let title = NSTextField(labelWithString: "References")
    private let copyAll = InspectorCopyButton()
    override var isFlipped: Bool { true }

    static func rowHeight(_ name: String, width: CGFloat) -> CGFloat {
        let cell = NSTextFieldCell(textCell: name)
        cell.font = .systemFont(ofSize: 11)
        cell.wraps = true
        cell.isScrollable = false
        cell.usesSingleLineMode = false
        return max(26, ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width - 52),
                                                            height: CGFloat.greatestFiniteMagnitude)).height) + 8)
    }
    static func height(for refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        26 + refs.map { rowHeight($0.name, width: width) }.reduce(0, +)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = .secondaryLabelColor
        addSubview(title)
        addSubview(copyAll)
        copyAll.toolTip = "Copy all refs"
        copyAll.setAccessibilityLabel("Copy all refs")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ refs: [GitRefDecoration]) {
        let ordered = GitRefDecoration.orderedForDisplay(refs)
        guard self.refs != ordered else { return }
        self.refs = ordered
        rows.forEach { $0.removeFromSuperview() }
        rows = ordered.map { ref in
            let row = Row(ref: ref)
            addSubview(row)
            return row
        }
        copyAll.value = ordered.map(\.name).joined(separator: "\n")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 4, y: 5, width: max(1, bounds.width - 32), height: 15)
        copyAll.frame = NSRect(x: bounds.width - 24, y: 2, width: 22, height: 22)
        var y: CGFloat = 26
        for (row, ref) in zip(rows, refs) {
            let height = Self.rowHeight(ref.name, width: bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
    private final class Row: NSView {
        private let name = InspectorCopyableTextField(wrappingLabelWithString: "")
        private let symbol = NSImageView()
        private let copyButton = InspectorCopyButton()
        override var isFlipped: Bool { true }
        init(ref: GitRefDecoration) {
            super.init(frame: .zero)
            name.stringValue = ref.name
            name.isSelectable = true
            name.font = .systemFont(ofSize: 11)
            name.textColor = GitRefBadgesView.tint(for: ref.kind)
            name.maximumNumberOfLines = 0
            name.lineBreakMode = .byWordWrapping
            if let icon = GitRefBadgesView.symbol(for: ref.kind) {
                symbol.image = NSImage(systemSymbolName: icon, accessibilityDescription: ref.kind.rawValue)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            }
            symbol.contentTintColor = name.textColor
            copyButton.value = ref.name
            copyButton.toolTip = "Copy " + ref.name
            [symbol, name, copyButton].forEach(addSubview)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            symbol.frame = NSRect(x: 4, y: 6, width: 12, height: 12)
            name.frame = NSRect(x: 22, y: 4, width: max(1, bounds.width - 52), height: bounds.height - 8)
            copyButton.frame = NSRect(x: bounds.width - 24, y: 2, width: 22, height: 22)
        }
    }
}

struct GitRefBadgeRow: NSViewRepresentable {
    let refs: [GitRefDecoration]
    func makeNSView(context: Context) -> GitRefBadgesView { GitRefBadgesView() }
    func updateNSView(_ view: GitRefBadgesView, context: Context) { view.configure(refs) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitRefBadgesView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: refs.isEmpty ? 0 : 17)
    }
}

struct InspectorCopyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> InspectorCopyableTextField {
        let view = InspectorCopyableTextField(labelWithString: "")
        view.isSelectable = true
        view.font = .systemFont(ofSize: 10)
        view.textColor = .secondaryLabelColor
        view.lineBreakMode = .byTruncatingMiddle
        view.maximumNumberOfLines = 1
        return view
    }
    func updateNSView(_ view: InspectorCopyableTextField, context: Context) {
        if view.stringValue != text { view.stringValue = text }
        view.toolTip = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorCopyableTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 14)
    }
}
