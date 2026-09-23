import AppKit
import QuartzCore

@MainActor
extension Ghostty.SurfaceView {
    /// A transient visual cue for an already-resolved tracked Pin. It never
    /// searches text, changes the terminal selection, or captures mouse input.
    func flashHistoryRow(_ row: UInt32, topPadding: CGFloat) {
        guard let rect = Self.historyHighlightFrame(
            row: row, topPadding: topPadding,
            bounds: bounds, cellHeight: cellSize.height
        ) else { return }
        for child in subviews where child is HistoryJumpHighlightView {
            child.removeFromSuperview()
        }
        let highlight = HistoryJumpHighlightView(frame: rect)
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.32).cgColor
        highlight.layer?.cornerRadius = 4
        highlight.layer?.opacity = 0
        addSubview(highlight, positioned: .above, relativeTo: nil)

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0.08, 1, 0]
        pulse.keyTimes = [0, 0.2, 0.5, 0.75, 1]
        pulse.duration = 1.6
        highlight.layer?.add(pulse, forKey: "historyJumpPulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak highlight] in
            highlight?.removeFromSuperview()
        }
    }

    static func historyHighlightFrame(
        row: UInt32, topPadding: CGFloat, bounds: CGRect, cellHeight: CGFloat
    ) -> CGRect? {
        guard cellHeight > 0, topPadding >= 0 else { return nil }
        let y = bounds.maxY - topPadding - (CGFloat(row) + 1) * cellHeight
        guard y >= bounds.minY, y + cellHeight <= bounds.maxY else { return nil }
        return CGRect(x: bounds.minX + 4, y: y,
                      width: max(0, bounds.width - 8), height: cellHeight)
    }
}

private final class HistoryJumpHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
