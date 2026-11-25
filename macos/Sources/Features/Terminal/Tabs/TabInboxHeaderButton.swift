import AppKit

/// The sidebar header's inbox toggle. Matches sibling 24×24pt header icon controls
/// (`12pt .medium` symbol scaled into a centered 16×16pt slot — matching
/// `NativeActionControl` so wide `tray`/`tray.fill` (~16×12.2pt) balances the optical
/// weight and height of `rectangle.stack` next to it; `tray` with a 6×6pt accent dot
/// when inactive and tabs wait for the user, `tray.fill` on a subtle borderless neutral
/// active pill with `theme.foreground` glyph when shown).
final class TabInboxHeaderButton: NativeActionControl {
    static let badgeDiameter: CGFloat = 6
    static let pillCornerRadius: CGFloat = 5
    static let maxGlyphSlot: CGFloat = 16

    private(set) var isShown = false

    /// Tabs waiting for the user; zero while the inbox itself is shown.
    private(set) var attentionCount = 0

    var showsBadge: Bool { !isShown && attentionCount > 0 }

    func update(shown: Bool, attention: Int, strings: ChromeStrings) {
        let count = shown ? 0 : max(0, attention)
        configure(
            title: "",
            symbol: shown ? "tray.fill" : "tray",
            help: strings.toggleInbox(shown: shown, attention: count),
            enabled: true,
            style: .plain,
            identifier: "tabs.inbox"
        )
        setAccessibilityLabel(strings.inbox)
        setAccessibilityValue(shown ? strings.selected : count > 0 ? strings.inboxAttention(count) : "")
        let changed = isShown != shown || attentionCount != count
        isShown = shown
        attentionCount = count
        if changed { needsDisplay = true }
    }

    override var glyphRect: NSRect {
        let size = image?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))?.size
            ?? image?.size
            ?? .zero
        let maxEdge = max(size.width, size.height)
        let scale = maxEdge > 0 ? min(1, Self.maxGlyphSlot / maxEdge) : 0
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// At the glyph's top trailing corner, inside the 24pt control.
    var badgeRect: NSRect {
        let glyph = glyphRect
        let diameter = Self.badgeDiameter
        return NSRect(
            x: min(glyph.maxX - diameter / 2 + 1, bounds.maxX - diameter - 1),
            y: max(glyph.minY - diameter / 2, bounds.minY + 1),
            width: diameter,
            height: diameter
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.pillCornerRadius,
            yRadius: Self.pillCornerRadius
        )
        let pressed = isHighlighted && NativePointerLocation.contains(self)
        let fill: NSColor
        if !isEnabled {
            fill = .clear
        } else if isShown {
            if pressed {
                fill = theme.foreground.withAlphaComponent(0.17)
            } else if isHovered && showsHover {
                fill = theme.foreground.withAlphaComponent(0.13)
            } else {
                fill = theme.hoverFill
            }
        } else if pressed {
            fill = theme.foreground.withAlphaComponent(0.14)
        } else if isHovered && showsHover {
            fill = theme.hoverFill
        } else {
            fill = .clear
        }
        if fill != .clear {
            fill.setFill()
            shape.fill()
        }
        if showsKeyboardFocusBorder && window?.firstResponder === self {
            theme.accent.withAlphaComponent(0.55).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
        let glyphColor: NSColor = isEnabled ? theme.foreground : theme.disabled
        if let image {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                glyphColor.withAlphaComponent(1).setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            let alpha = (isShown || isHovered || pressed ? 1 : restingSymbolAlpha) * glyphColor.alphaComponent
            tinted.draw(
                in: glyphRect,
                from: .zero,
                operation: .sourceOver,
                fraction: alpha,
                respectFlipped: true,
                hints: nil
            )
        }
        guard showsBadge else { return }
        let dot = badgeRect
        theme.background.withAlphaComponent(0.88).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
        theme.accent.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
