import Foundation

struct GitGraphLayout: Equatable, Sendable {
    private(set) var activeLanes: [GitCommitID]
    private var activeLaneColorIndices: [Int]
    /// Last row index that used each palette slot (Git Graph's availableColours).
    private var colorLastUsedRow: [Int: Int]
    private var rowIndex: Int
    /// Commits queued as some commit's parent but not yet listed. Only these
    /// may block lane compaction; dangling lanes get filled from the left.
    private var pendingParentIDs: Set<GitCommitID>
    private let primaryRanks: [GitCommitID: Int]

    init(activeLanes: [GitCommitID] = [], primaryFirstParents: [GitCommitID] = []) {
        // Only real continuations enter from above; the first-parent spine
        // supplies ordering ranks, not an invented incoming edge at the tip.
        let initial = activeLanes
        self.activeLanes = initial
        self.activeLaneColorIndices = initial.indices.map { $0 % GitGraphRow.paletteSize }
        colorLastUsedRow = [:]
        rowIndex = 0
        pendingParentIDs = Set(initial)
        var ranks: [GitCommitID: Int] = [:]
        for (index, id) in primaryFirstParents.enumerated() where ranks[id] == nil { ranks[id] = index }
        primaryRanks = ranks
    }

    /// Anchor the displayed timeline's first-parent spine, rather than letting
    /// unrelated pending tips become the new leftmost lane after a merge.
    static func rows(for commits: [GitHistoryCommit]) -> [GitGraphRow] {
        var firstParents: [GitCommitID: GitCommitID] = [:]
        for commit in commits { firstParents[commit.id] = commit.parentIDs.first }
        var primary: [GitCommitID] = []
        var seen = Set<GitCommitID>()
        var current = commits.first?.id
        while let id = current, seen.insert(id).inserted {
            primary.append(id)
            current = firstParents[id]
        }
        let spine = Set(primary)
        var layout = GitGraphLayout(primaryFirstParents: primary)
        let remoteOnly = Set(commits.filter(\.isRemoteOnly).map(\.id))
        var rows = commits.map { layout.append(commitID: $0.id, parentIDs: $0.parentIDs, isRemoteOnly: remoteOnly) }
        recolorForBranchIdentity(&rows, spine: spine)
        return rows
    }

    /// Second pass that gives every fork its own colour from the fork point
    /// down (a lane takes the colour of its topmost node's branch), while the
    /// first-parent spine keeps the trunk colour end to end. Walking bottom-up
    /// resolves each lane's colour to the colour of the child that continues
    /// it, so a branch never shows a stub of its parent's colour.
    private static func recolorForBranchIdentity(_ rows: inout [GitGraphRow], spine: Set<GitCommitID>) {
        guard !rows.isEmpty else { return }
        var laneColour: [GitCommitID: Int] = [:]
        for index in rows.indices.reversed() {
            var row = rows[index]
            let nodeColour = spine.contains(row.commitID)
                ? GitGraphLayout.spineColorIndex
                : laneColour[row.commitID] ?? row.nodeColorIndex
            row.nodeColorIndex = nodeColour
            for lane in row.bottomLanes.indices {
                let id = row.bottomLanes[lane]
                laneColour[id] = spine.contains(id) ? GitGraphLayout.spineColorIndex : (laneColour[id] ?? nodeColour)
            }
            row.segments = row.segments.map { segment in
                var segment = segment
                switch segment.kind {
                case .incoming:
                    segment.colorIndex = nodeColour
                case .passthrough:
                    segment.colorIndex = laneColour[segment.commitID] ?? segment.colorIndex
                case .parent:
                    if let parentID = segment.parentID, let colour = laneColour[parentID] {
                        segment.colorIndex = colour
                    }
                }
                return segment
            }
            rows[index] = row
        }
    }

    var activeCommitIDs: [GitCommitID] {
        activeLanes
    }

    mutating func append(
        commitID: GitCommitID,
        parentIDs: [GitCommitID]
    ) -> GitGraphRow {
        append(commitID: commitID, parentIDs: parentIDs, isRemoteOnly: [])
    }

    mutating func append(
        commitID: GitCommitID,
        parentIDs: [GitCommitID],
        isRemoteOnly: Set<GitCommitID>
    ) -> GitGraphRow {
        let topLanes = activeLanes
        let topLaneColorIndices = activeLaneColorIndices
        let uniqueParentIDs = Self.uniqueCommitIDs(parentIDs)
        let currentLane = topLanes.firstIndex(of: commitID) ?? topLanes.count
        let wasActive = currentLane < topLanes.count
        // First pass only needs deterministic placeholder colours; the second
        // pass (recolorForBranchIdentity) resolves the final branch colours.
        let currentColorIndex = if wasActive {
            topLaneColorIndices[currentLane]
        } else if topLanes.isEmpty {
            Self.spineColorIndex
        } else {
            freeColorIndex(reserved: [])
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
        // Colours handed out within this row; octopus merges must not give
        // two new lanes the same slot before either can retire.
        var reservedThisRow = Set(bottomLaneColorIndices)

        for (parentIndex, parentID) in uniqueParentIDs.enumerated() {
            if let lane = bottomLanes.firstIndex(of: parentID) {
                parentLanes[parentID] = lane
                parentColorIndices[parentID] = bottomLaneColorIndices[lane]
                insertionIndex = max(insertionIndex, lane + 1)
                continue
            }

            // Lanes whose commit was already processed are dangling: they keep
            // a slot only as a merge target or future node. Pending parents and
            // spine commits must not be displaced sideways, but any other
            // dangling lane may be filled from the left, closing visual holes.
            while insertionIndex < bottomLanes.count,
                  primaryRanks[bottomLanes[insertionIndex]] == nil,
                  !pendingParentIDs.contains(bottomLanes[insertionIndex]) {
                insertionIndex += 1
            }

            let lane = min(insertionIndex, bottomLanes.count)
            // First parents continue the node's own line; extra parents fork
            // into a placeholder colour that the second pass may refine.
            let colorIndex = if parentIndex == 0 {
                currentColorIndex
            } else {
                freeColorIndex(reserved: reservedThisRow)
            }
            reservedThisRow.insert(colorIndex)
            bottomLanes.insert(parentID, at: lane)
            bottomLaneColorIndices.insert(colorIndex, at: lane)
            parentLanes[parentID] = lane
            parentColorIndices[parentID] = colorIndex
            insertionIndex = lane + 1
        }

        // A side branch may have queued a future mainline ancestor to the
        // right of other pending lanes. Promote the nearest unprocessed spine
        // commit before emitting edges, keeping boundary coordinates consistent.
        // The promoted lane keeps the trunk color so lane 0 never changes hue.
        if let lane = bottomLanes.indices.filter({ primaryRanks[bottomLanes[$0]] != nil }).min(by: {
            primaryRanks[bottomLanes[$0], default: .max] < primaryRanks[bottomLanes[$1], default: .max]
        }), lane != 0 {
            let id = bottomLanes.remove(at: lane)
            bottomLaneColorIndices.remove(at: lane)
            bottomLanes.insert(id, at: 0)
            bottomLaneColorIndices.insert(Self.spineColorIndex, at: 0)
        }
        for parentID in uniqueParentIDs { parentLanes[parentID] = bottomLanes.firstIndex(of: parentID) }

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
        // Colours that left the active set become re-usable one palette cycle
        // from now (Git Graph's availableColours), which keeps a hue from
        // repeating within a screenful of rows.
        for color in Set(activeLaneColorIndices).subtracting(bottomLaneColorIndices) where color != Self.spineColorIndex {
            colorLastUsedRow[color] = rowIndex
        }
        activeLaneColorIndices = bottomLaneColorIndices
        pendingParentIDs.formUnion(uniqueParentIDs)
        pendingParentIDs.remove(commitID)
        rowIndex += 1

        return GitGraphRow(
            commitID: commitID,
            parentIDs: uniqueParentIDs,
            topLanes: topLanes,
            bottomLanes: bottomLanes,
            nodeLane: currentLane,
            nodeColorIndex: currentColorIndex,
            segments: segments,
            isRemoteOnly: isRemoteOnly.contains(commitID)
        )
    }

    /// Lane 0's first-parent spine always uses this palette slot.
    static let spineColorIndex = 0

    /// Git Graph's availableColours: prefer the palette slot whose last
    /// retirement is at least one full palette cycle away, so a hue never
    /// repeats within a screenful of rows. `reserved` excludes slots already
    /// handed out to new lanes on the current row. Falls back to the
    /// least-recently-used slot when more lanes than slots are active.
    private mutating func freeColorIndex(reserved: Set<Int>) -> Int {
        let slots = Array(1..<GitGraphRow.paletteSize)
        for color in slots where !reserved.contains(color)
            && (colorLastUsedRow[color] ?? Int.min) + GitGraphRow.paletteSize <= rowIndex {
            return color
        }
        if let color = slots.filter({ !reserved.contains($0) && !activeLaneColorIndices.contains($0) }).min() {
            return color
        }
        return slots.min {
            (colorLastUsedRow[$0] ?? Int.min) < (colorLastUsedRow[$1] ?? Int.min)
        } ?? ((rowIndex % max(1, GitGraphRow.paletteSize - 1)) + 1)
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
    var nodeColorIndex: Int
    var segments: [GitGraphSegment]
    var isRemoteOnly = false

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
    var colorIndex: Int
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
