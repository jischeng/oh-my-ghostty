import AppKit

/// The same flow calculation supplies row heights and badge frames.
final class GitRefBadgesView: NSView {
    private var labels: [NSTextField] = []
    private var widths: [CGFloat] = []
    override var isFlipped: Bool { true }

    static func attributed(_ decoration: GitRefDecoration) -> NSAttributedString {
        let color: NSColor
        let symbol: String
        switch decoration.kind {
        case .currentBranch: color = .systemBlue; symbol = "arrow.triangle.branch"
        case .localBranch: color = .systemGreen; symbol = "arrow.triangle.branch"
        case .remoteBranch: color = .systemPurple; symbol = "network"
        case .tag: color = .systemOrange; symbol = "tag.fill"
        case .head: color = .systemBlue; symbol = "scope"
        }
        let text = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: decoration.kind.rawValue)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [color])) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 11, height: 11)
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: " " + decoration.name, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ]))
        return text
    }

    static func frames(widths: [CGFloat], availableWidth: CGFloat) -> [NSRect] {
        let available = max(1, availableWidth)
        var x: CGFloat = 0
        var y: CGFloat = 0
        return widths.map { desired in
            let width = min(available, desired)
            if x > 0 && x + width > available { x = 0; y += 20 }
            let rect = NSRect(x: x, y: y, width: width, height: 17)
            x += width + 5
            return rect
        }
    }

    static func height(for refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        let widths = GitRefDecoration.orderedForDisplay(refs).map { ceil(attributed($0).size().width) + 4 }
        return frames(widths: widths, availableWidth: width).last?.maxY ?? 0
    }

    func configure(_ refs: [GitRefDecoration]) {
        labels.forEach { $0.removeFromSuperview() }
        labels = []
        widths = []
        for ref in GitRefDecoration.orderedForDisplay(refs) {
            let label = NSTextField(labelWithAttributedString: Self.attributed(ref))
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.toolTip = "\(ref.kind.rawValue): \(ref.name)"
            label.setAccessibilityLabel(label.toolTip)
            widths.append(ceil(label.attributedStringValue.size().width) + 4)
            labels.append(label)
            addSubview(label)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (label, frame) in zip(labels, Self.frames(widths: widths, availableWidth: bounds.width)) { label.frame = frame }
    }
}
