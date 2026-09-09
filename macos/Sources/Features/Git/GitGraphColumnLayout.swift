import Foundation

/// Text geometry never depends on graph lane count or node position.
enum GitHistoryRowMetrics {
    static let contentLeadingX: CGFloat = 22
    static let contentAxisY: CGFloat = 12
}

/// Graph topology is projected into its own compact drawing surface. Two lanes
/// retain an 8-point separation; denser graphs compress here, not in text layout.
struct GitGraphColumnLayout: Equatable {
    static let drawingWidth: CGFloat = 18
    var width: CGFloat { Self.drawingWidth }

    func middleX(lane: Int, row: GitGraphRow) -> CGFloat {
        laneX(lane, count: row.requiredLaneCount)
    }

    func edgeX(lane: Int, count: Int) -> CGFloat {
        laneX(lane, count: count)
    }

    private func laneX(_ lane: Int, count: Int) -> CGFloat {
        5 + CGFloat(lane) * 8 / CGFloat(max(1, count - 1))
    }
}
