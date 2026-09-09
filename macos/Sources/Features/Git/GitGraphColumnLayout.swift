import Foundation

/// Text uses only this node's gutter. Edge widths agree across adjacent
/// commits, so forks can bulge locally without shifting the mainline column.
struct GitGraphColumnLayout: Equatable {
    let width: CGFloat
    let topWidth: CGFloat
    let bottomWidth: CGFloat

    // The graph has its own gutter; disclosure lives at the row's trailing edge.
    static let contentAxisY: CGFloat = 12
    var contentX: CGFloat { width + 4 }

    static func width(for row: GitGraphRow) -> CGFloat {
        24 + min(32, CGFloat(row.nodeLane) * 8)
    }

    init(row: GitGraphRow, previous: GitGraphRow? = nil, next: GitGraphRow? = nil) {
        width = Self.width(for: row)
        topWidth = min(width, previous.map(Self.width) ?? width)
        bottomWidth = min(width, next.map(Self.width) ?? width)
    }

    func middleX(lane: Int, row: GitGraphRow) -> CGFloat {
        let nodeX = 7.5 + min(32, CGFloat(row.nodeLane) * 8)
        if lane <= row.nodeLane {
            return 7.5 + CGFloat(lane) * (nodeX - 7.5) / CGFloat(max(1, row.nodeLane))
        }
        let remaining = max(1, row.requiredLaneCount - row.nodeLane - 1)
        return nodeX + CGFloat(lane - row.nodeLane) * min(8, (width - 7.5 - nodeX) / CGFloat(remaining))
    }

    func edgeX(lane: Int, count: Int, top: Bool) -> CGFloat {
        let width = top ? topWidth : bottomWidth
        return 7.5 + CGFloat(lane) * min(8, (width - 15) / CGFloat(max(1, count - 1)))
    }
}
