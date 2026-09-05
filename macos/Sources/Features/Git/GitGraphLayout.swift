import Foundation

struct GitGraphLayout: Equatable, Sendable {
    private(set) var activeLanes: [GitCommitID]
    private var activeLaneColorIndices: [Int]
    private var nextColorIndex: Int

    init(activeLanes: [GitCommitID] = []) {
        self.activeLanes = activeLanes
        self.activeLaneColorIndices = activeLanes.indices.map { $0 % GitGraphRow.paletteSize }
        self.nextColorIndex = activeLanes.count % GitGraphRow.paletteSize
    }

    var activeCommitIDs: [GitCommitID] {
        activeLanes
    }

    mutating func append(
        commitID: GitCommitID,
        parentIDs: [GitCommitID]
    ) -> GitGraphRow {
        let topLanes = activeLanes
        let topLaneColorIndices = activeLaneColorIndices
        let uniqueParentIDs = Self.uniqueCommitIDs(parentIDs)
        let currentLane = topLanes.firstIndex(of: commitID) ?? topLanes.count
        let wasActive = currentLane < topLanes.count
        let currentColorIndex = if wasActive {
            topLaneColorIndices[currentLane]
        } else {
            allocateColorIndex()
        }

        var bottomLanes = topLanes
        var bottomLaneColorIndices = topLaneColorIndices
        if wasActive {
            bottomLanes.remove(at: currentLane)
            bottomLaneColorIndices.remove(at: currentLane)
        }

        var parentLanes: [GitCommitID: Int] = [:]
        var parentColorIndices: [GitCommitID: Int] = [:]
        var insertionIndex = min(currentLane, bottomLanes.count)

        for (parentIndex, parentID) in uniqueParentIDs.enumerated() {
            if let lane = bottomLanes.firstIndex(of: parentID) {
                parentLanes[parentID] = lane
                parentColorIndices[parentID] = bottomLaneColorIndices[lane]
                insertionIndex = max(insertionIndex, lane + 1)
                continue
            }

            let lane = min(insertionIndex, bottomLanes.count)
            let colorIndex = parentIndex == 0 ? currentColorIndex : allocateColorIndex()
            bottomLanes.insert(parentID, at: lane)
            bottomLaneColorIndices.insert(colorIndex, at: lane)
            parentLanes[parentID] = lane
            parentColorIndices[parentID] = colorIndex
            insertionIndex = lane + 1
        }

        var segments: [GitGraphSegment] = []
        if wasActive {
            segments.append(
                GitGraphSegment(
                    kind: .incoming,
                    from: .top(lane: currentLane),
                    to: .node(lane: currentLane),
                    colorIndex: currentColorIndex,
                    commitID: commitID,
                    parentID: nil
                )
            )
        }

        for (lane, laneCommitID) in topLanes.enumerated() where laneCommitID != commitID {
            guard let bottomLane = bottomLanes.firstIndex(of: laneCommitID) else { continue }
            segments.append(
                GitGraphSegment(
                    kind: .passthrough,
                    from: .top(lane: lane),
                    to: .bottom(lane: bottomLane),
                    colorIndex: topLaneColorIndices[lane],
                    commitID: laneCommitID,
                    parentID: nil
                )
            )
        }

        for parentID in uniqueParentIDs {
            guard let parentLane = parentLanes[parentID],
                  let parentColorIndex = parentColorIndices[parentID] else { continue }
            segments.append(
                GitGraphSegment(
                    kind: .parent,
                    from: .node(lane: currentLane),
                    to: .bottom(lane: parentLane),
                    colorIndex: parentColorIndex,
                    commitID: commitID,
                    parentID: parentID
                )
            )
        }

        activeLanes = bottomLanes
        activeLaneColorIndices = bottomLaneColorIndices

        return GitGraphRow(
            commitID: commitID,
            parentIDs: uniqueParentIDs,
            topLanes: topLanes,
            bottomLanes: bottomLanes,
            nodeLane: currentLane,
            nodeColorIndex: currentColorIndex,
            segments: segments
        )
    }

    private mutating func allocateColorIndex() -> Int {
        defer {
            nextColorIndex = (nextColorIndex + 1) % GitGraphRow.paletteSize
        }
        return nextColorIndex
    }

    private static func uniqueCommitIDs(_ commitIDs: [GitCommitID]) -> [GitCommitID] {
        var seen = Set<GitCommitID>()
        var result: [GitCommitID] = []
        for commitID in commitIDs where !seen.contains(commitID) {
            seen.insert(commitID)
            result.append(commitID)
        }
        return result
    }

}

struct GitGraphRow: Equatable, Sendable {
    static let paletteSize = 8

    let commitID: GitCommitID
    let parentIDs: [GitCommitID]
    let topLanes: [GitCommitID]
    let bottomLanes: [GitCommitID]
    let nodeLane: Int
    let nodeColorIndex: Int
    let segments: [GitGraphSegment]

    var requiredLaneCount: Int {
        max(topLanes.count, bottomLanes.count, nodeLane + 1, 1)
    }
}

struct GitGraphSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case incoming
        case parent
        case passthrough
    }

    let kind: Kind
    let from: GitGraphPoint
    let to: GitGraphPoint
    let colorIndex: Int
    let commitID: GitCommitID
    let parentID: GitCommitID?
}

enum GitGraphPoint: Equatable, Sendable {
    case top(lane: Int)
    case node(lane: Int)
    case bottom(lane: Int)

    var lane: Int {
        switch self {
        case .top(let lane), .node(let lane), .bottom(let lane):
            lane
        }
    }
}
