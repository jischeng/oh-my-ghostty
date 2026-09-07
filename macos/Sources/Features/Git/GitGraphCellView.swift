import AppKit

final class GitGraphCellView: NSView {
    static let laneSpacing: CGFloat = 11
    static let horizontalInset: CGFloat = 6
    static let nodeDiameter: CGFloat = 7
    static let lineWidth: CGFloat = 1.6

    private static let palette: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemRed,
        .systemIndigo,
    ]

    private var row: GitGraphRow?

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        guard let row else {
            return NSSize(width: Self.preferredWidth(laneCount: 1), height: NSView.noIntrinsicMetric)
        }
        return NSSize(
            width: Self.preferredWidth(laneCount: row.requiredLaneCount),
            height: NSView.noIntrinsicMetric
        )
    }

    static func preferredWidth(laneCount: Int) -> CGFloat {
        let lanes = max(laneCount, 1)
        return horizontalInset * 2 + CGFloat(lanes - 1) * laneSpacing + nodeDiameter
    }

    func configure(row: GitGraphRow) {
        self.row = row
        invalidateIntrinsicContentSize()
        needsDisplay = true
        toolTip = row.commitID.shortSHA
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row else { return }

        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        for segment in row.segments {
            draw(segment)
        }

        drawNode(row)
    }

    private func draw(_ segment: GitGraphSegment) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = Self.lineWidth
        path.move(to: point(for: segment.from))
        path.line(to: point(for: segment.to))
        color(for: segment.colorIndex).setStroke()
        path.stroke()
    }

    private func drawNode(_ row: GitGraphRow) {
        let center = point(for: .node(lane: row.nodeLane))
        let radius = Self.nodeDiameter / 2
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: Self.nodeDiameter,
            height: Self.nodeDiameter
        )

        color(for: row.nodeColorIndex).setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    private func point(for graphPoint: GitGraphPoint) -> NSPoint {
        let x = Self.horizontalInset + Self.nodeDiameter / 2
            + CGFloat(graphPoint.lane) * Self.laneSpacing
        let y: CGFloat
        switch graphPoint {
        case .top:
            y = bounds.minY
        case .node:
            y = bounds.midY
        case .bottom:
            y = bounds.maxY
        }
        return NSPoint(x: x, y: y)
    }

    private func color(for index: Int) -> NSColor {
        Self.palette[abs(index) % Self.palette.count]
    }
}
