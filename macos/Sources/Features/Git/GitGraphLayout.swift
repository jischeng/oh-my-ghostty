import Foundation

struct GitGraphLayout: Equatable, Sendable {
    private(set) var activeLanes: [GitCommitID]

    init(activeLanes: [GitCommitID] = []) {
        self.activeLanes = activeLanes
    }

    var activeCommitIDs: [GitCommitID] {
        activeLanes
    }

    mutating func append(
        commitID: GitCommitID,
        parentIDs: [GitCommitID]
    ) -> GitGraphRow {
        let topLanes = activeLanes
        let uniqueParentIDs = Self.uniqueCommitIDs(parentIDs)
        let currentLane = topLanes.firstIndex(of: commitID) ?? topLanes.count
        let wasActive = currentLane < topLanes.count

        var bottomLanes = topLanes
        if wasActive {
            bottomLanes.remove(at: currentLane)
        }

        var parentLanes: [GitCommitID: Int] = [:]
        var insertionIndex = min(currentLane, bottomLanes.count)

        for parentID in uniqueParentIDs {
            if let lane = bottomLanes.firstIndex(of: parentID) {
                parentLanes[parentID] = lane
                insertionIndex = max(insertionIndex, lane + 1)
                continue
            }

            let lane = min(insertionIndex, bottomLanes.count)
            bottomLanes.insert(parentID, at: lane)
            parentLanes[parentID] = lane
            insertionIndex = lane + 1
        }

        var segments: [GitGraphSegment] = []
        if wasActive {
            segments.append(
                GitGraphSegment(
                    kind: .incoming,
                    from: .top(lane: currentLane),
                    to: .node(lane: currentLane),
                    colorIndex: Self.colorIndex(for: commitID),
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
                    colorIndex: Self.colorIndex(for: laneCommitID),
                    commitID: laneCommitID,
                    parentID: nil
                )
            )
        }

        for parentID in uniqueParentIDs {
            guard let parentLane = parentLanes[parentID] else { continue }
            segments.append(
                GitGraphSegment(
                    kind: .parent,
                    from: .node(lane: currentLane),
                    to: .bottom(lane: parentLane),
                    colorIndex: Self.colorIndex(for: parentID),
                    commitID: commitID,
                    parentID: parentID
                )
            )
        }

        activeLanes = bottomLanes

        return GitGraphRow(
            commitID: commitID,
            parentIDs: uniqueParentIDs,
            topLanes: topLanes,
            bottomLanes: bottomLanes,
            nodeLane: currentLane,
            nodeColorIndex: Self.colorIndex(for: commitID),
            segments: segments
        )
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

    private static func colorIndex(for commitID: GitCommitID) -> Int {
        let value = commitID.rawValue.utf8.reduce(UInt32(2_166_136_261)) { hash, byte in
            (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(value % UInt32(GitGraphRow.paletteSize))
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
