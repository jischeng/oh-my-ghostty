import AppKit

/// The sidebar header's inbox toggle. Uses a clean borderless 24×24pt icon style
/// matching sibling header controls (`tray` when inactive with a 6×6pt accent dot
/// when tabs wait for the user; `tray.fill` with a subtle borderless rounded pill
/// when active).
final class TabInboxHeaderButton: NativeActionControl {
    static let badgeDiameter: CGFloat = 6
    static let pillCornerRadius: CGFloat = 6

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

    /// At the glyph's top trailing corner, inside the 24pt control.
    var badgeRect: NSRect {
        let glyph = glyphRect
        let diameter = Self.badgeDiameter
        return NSRect(
            x: min(glyph.maxX - diameter / 2, bounds.maxX - diameter - 1),
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
                fill = theme.accent.withAlphaComponent(0.28)
            } else if isHovered && showsHover {
                fill = theme.accent.withAlphaComponent(0.23)
            } else {
                fill = theme.selectedFill
            }
        } else if pressed {
            fill = theme.selectedFill
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
        let glyphColor: NSColor
        if !isEnabled {
            glyphColor = theme.disabled
        } else if isShown {
            glyphColor = theme.accent
        } else {
            glyphColor = theme.foreground
        }
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
