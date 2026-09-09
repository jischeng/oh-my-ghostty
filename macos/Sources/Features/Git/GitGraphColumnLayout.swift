import Foundation

enum GitHistoryRowMetrics {
    static let contentAxisY: CGFloat = 12
}

/// Reserve only this row's drawn node and edges, followed by a small text gap.
/// Lane coordinates stay stable across row boundaries without a global gutter.
struct GitGraphColumnLayout: Equatable {
    let width: CGFloat
    var contentX: CGFloat { width + 3 }

    init(row: GitGraphRow) {
        let nodeRight = Self.laneX(row.nodeLane) + 4.5
        let edgeRight = row.segments.flatMap { [$0.from.lane, $0.to.lane] }
            .map { Self.laneX($0) + 0.8 }.max() ?? 0
        width = ceil(max(nodeRight, edgeRight))
    }

    func middleX(lane: Int, row: GitGraphRow) -> CGFloat {
        Self.laneX(lane)
    }

    func edgeX(lane: Int, count: Int) -> CGFloat {
        Self.laneX(lane)
    }

    private static func laneX(_ lane: Int) -> CGFloat {
        8 + CGFloat(lane) * 10
    }
}
