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
        let rightmostLane = max(row.nodeLane, row.segments.flatMap { [$0.from.lane, $0.to.lane] }.max() ?? 0)
        // Give passing lines the same clearance as a node on that lane.
        width = ceil(Self.laneX(rightmostLane) + 4.5)
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
