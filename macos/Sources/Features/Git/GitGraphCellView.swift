import AppKit

final class GitGraphCellView: NSView {
    static let laneSpacing: CGFloat = 8
    static let horizontalInset: CGFloat = 4
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
    private(set) var isHead = false
    enum Section { case commit, expandedCommit, continuation, expansionEnd }
    private(set) var section = Section.commit
    private var displayLaneCount = 1

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

    func configure(row: GitGraphRow, isHead: Bool = false, laneCount: Int? = nil, section: Section = .commit) {
        self.row = row
        self.isHead = isHead
        self.section = section
        displayLaneCount = laneCount ?? row.requiredLaneCount
        invalidateIntrinsicContentSize()
        needsDisplay = true
        toolTip = isHead ? "Current HEAD · \(row.commitID.shortSHA)" : row.commitID.shortSHA
        setAccessibilityLabel(toolTip)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row else { return }

        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        if section == .commit {
            for segment in row.segments { draw(segment) }
            drawNode(row)
            return
        }
        // Keep the current lane and all passing lanes vertical through the
        // expanded block. Forks and lane compaction happen only at its end.
        let ending = section == .expansionEnd
        let bendY = ending ? max(0, bounds.height - 10) : bounds.height
        for segment in row.segments where segment.kind == .passthrough {
            let top = point(for: segment.from)
            var points = [top, NSPoint(x: top.x, y: bendY)]
            if ending { points.append(point(for: segment.to)) }
            stroke(points, colorIndex: segment.colorIndex)
        }
        let start = point(for: section == .expandedCommit ? .node(lane: row.nodeLane) : .top(lane: row.nodeLane))
        let bend = NSPoint(x: start.x, y: bendY)
        stroke([start, bend], colorIndex: row.nodeColorIndex)
        if ending {
            for segment in row.segments where segment.kind == .parent {
                stroke([bend, point(for: segment.to)], colorIndex: segment.colorIndex)
            }
        }
        if section == .expandedCommit {
            for segment in row.segments where segment.kind == .incoming { draw(segment) }
            drawNode(row)
        }
    }

    private func stroke(_ points: [NSPoint], colorIndex: Int) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = Self.lineWidth
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        color(for: colorIndex).setStroke()
        path.stroke()
    }

    private func draw(_ segment: GitGraphSegment) {
        stroke([point(for: segment.from), point(for: segment.to)], colorIndex: segment.colorIndex)
    }

    private func drawNode(_ row: GitGraphRow) {
        let center = point(for: .node(lane: row.nodeLane))
        let diameter = Self.nodeDiameter
        let radius = diameter / 2
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )

        color(for: row.nodeColorIndex).setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        if isHead {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        }
    }

    private func point(for graphPoint: GitGraphPoint) -> NSPoint {
        let lanes = max(1, displayLaneCount - 1)
        let spacing = min(Self.laneSpacing, max(1, bounds.width - Self.horizontalInset * 2 - Self.nodeDiameter) / CGFloat(lanes))
        let x = Self.horizontalInset + Self.nodeDiameter / 2 + CGFloat(graphPoint.lane) * spacing
        let y: CGFloat
        switch graphPoint {
        case .top:
            y = bounds.minY
        case .node:
            y = min(14, bounds.midY)
        case .bottom:
            y = bounds.maxY
        }
        return NSPoint(x: x, y: y)
    }

    private func color(for index: Int) -> NSColor {
        Self.palette[abs(index) % Self.palette.count]
    }
}
