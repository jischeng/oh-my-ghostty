import AppKit

/// The sidebar header's inbox toggle. While the Tabs view is shown it carries
/// a dot when tabs wait for the user, because their rows may be out of sight.
final class TabInboxHeaderButton: NativeActionControl {
    static let badgeDiameter: CGFloat = 6

    /// Tabs waiting for the user; zero while the inbox itself is shown.
    private(set) var attentionCount = 0

    var showsBadge: Bool { attentionCount > 0 }

    func update(shown: Bool, attention: Int, strings: ChromeStrings) {
        let count = shown ? 0 : max(0, attention)
        configure(title: "", symbol: shown ? "tray.fill" : "tray",
                  help: strings.toggleInbox(shown: shown, attention: count),
                  enabled: true, style: shown ? .bordered : .plain, identifier: "tabs.inbox")
        setAccessibilityLabel(strings.inbox)
        setAccessibilityValue(shown ? strings.selected : count > 0 ? strings.inboxAttention(count) : "")
        guard attentionCount != count else { return }
        attentionCount = count
        needsDisplay = true
    }

    /// At the glyph's top trailing corner, inside the 24 pt control.
    var badgeRect: NSRect {
        let glyph = glyphRect
        let diameter = Self.badgeDiameter
        return NSRect(x: min(glyph.maxX - diameter / 2, bounds.maxX - diameter - 1),
                      y: max(glyph.minY - diameter / 2, bounds.minY + 1),
                      width: diameter, height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsBadge else { return }
        // The colour the tab rows use for an agent that needs attention.
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
    }
}
