import Foundation

/// Commit-graph layout. The lane engine is a streaming pipe state machine
/// adapted from lazygit's `pkg/gui/presentation/graph/graph.go`
/// (jesseduffield/lazygit, MIT): every pending edge is a pipe with a kind
/// (starts / continues / terminates), and per-row spot bookkeeping
/// (taken / traversed) keeps lanes compact without holes. Two rules come from
/// vscode-git-graph's semantics (MIT): the first-parent spine is always
/// promoted to lane 0 and keeps the trunk colour end to end (issue #17), and
/// every fork takes its own colour from the fork point down, never a stub of
/// its parent's colour (issue #23). GitUp's graph served as a visual
/// reference only (GPL, no code copied).
struct GitGraphLayout: Equatable, Sendable {

    enum PipeKind: Int, Equatable, Sendable {
        case terminates
        case starts
        case continues
    }

    /// A pending edge from one commit down to another, positioned on a lane.
    struct Pipe: Equatable, Sendable {
        var fromPos: Int
        var toPos: Int
        let fromID: GitCommitID
        let toID: GitCommitID
        var kind: PipeKind
        var colorIndex: Int
    }

    private(set) var pipes: [Pipe] = []
    private var colorLastUsedRow: [Int: Int] = [:]
    private var rowIndex = 0
    private let primaryRanks: [GitCommitID: Int]

    init(activeLanes: [GitCommitID] = [], primaryFirstParents: [GitCommitID] = []) {
        // Only real continuations enter from above; the first-parent spine
        // supplies ordering ranks, not an invented incoming edge at the tip.
        pipes = activeLanes.enumerated().map {
            Pipe(fromPos: $0.offset, toPos: $0.offset, fromID: $0.element, toID: $0.element,
                 kind: .continues, colorIndex: $0.offset == 0 ? Self.spineColorIndex : $0.offset)
        }
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
        let remoteOnly = Set(commits.filter(\.isRemoteOnly).map(\.id))
        var layout = GitGraphLayout(primaryFirstParents: primary)
        return commits.map { layout.append(commitID: $0.id, parentIDs: $0.parentIDs, isRemoteOnly: remoteOnly) }
    }

    var activeCommitIDs: [GitCommitID] {
        pipes.map(\.toID)
    }

    /// Lane 0's first-parent spine always uses this palette slot.
    static let spineColorIndex = 0

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
        let uniqueParentIDs = Self.uniqueCommitIDs(parentIDs)
        let currentPipes = pipes
        let topLanes = currentPipes.map(\.toID)
        let topLaneColorIndices = currentPipes.map(\.colorIndex)
        let maxPos = currentPipes.map(\.toPos).max()

        // Commit position: right under the first pipe expecting it. Otherwise
        // it is a fresh tip: lane 0 when nothing is active yet, else tacked
        // onto the far end (unrelated tip, e.g. `git log --all`).
        var pos = maxPos.map { $0 + 1 } ?? 0
        for pipe in currentPipes where pipe.toID == commitID {
            pos = pipe.toPos
            break
        }
        let wasActive = currentPipes.contains { $0.toID == commitID }

        var takenSpots = Set<Int>()
        var traversedSpots = Set<Int>()
        let traversedForContinuing = Set(currentPipes.filter { $0.toID != commitID }.map(\.toPos))

        func traverse(_ from: Int, _ to: Int) {
            for spot in min(from, to)...max(from, to) { traversedSpots.insert(spot) }
            takenSpots.insert(to)
        }

        var nextAvailableForContinuing = 0
        func nextPosForContinuingPipe() -> Int {
            while traversedSpots.contains(nextAvailableForContinuing) { nextAvailableForContinuing += 1 }
            return nextAvailableForContinuing
        }

        func nextPosForNewPipe() -> Int {
            var spot = 0
            while takenSpots.contains(spot) || traversedForContinuing.contains(spot) { spot += 1 }
            return spot
        }

        var newPipes: [Pipe] = []
        // Existing pipes: terminate at this commit, or continue, compacting
        // into the nearest free spot on either side of the node.
        for pipe in currentPipes {
            if pipe.toID == commitID {
                newPipes.append(Pipe(fromPos: pipe.toPos, toPos: pos, fromID: pipe.fromID,
                                     toID: pipe.toID, kind: .terminates, colorIndex: pipe.colorIndex))
                traverse(pipe.toPos, pos)
            } else if pipe.toPos < pos {
                let available = nextPosForContinuingPipe()
                newPipes.append(Pipe(fromPos: pipe.toPos, toPos: available, fromID: pipe.fromID,
                                     toID: pipe.toID, kind: .continues, colorIndex: pipe.colorIndex))
                traverse(pipe.toPos, available)
            }
        }
        for pipe in currentPipes where pipe.toID != commitID && pipe.toPos > pos {
            var last = pipe.toPos
            var spot = pipe.toPos
            while spot > pos {
                if takenSpots.contains(spot) || traversedSpots.contains(spot) { break }
                last = spot
                spot -= 1
            }
            newPipes.append(Pipe(fromPos: pipe.toPos, toPos: last, fromID: pipe.fromID,
                                 toID: pipe.toID, kind: .continues, colorIndex: pipe.colorIndex))
            traverse(pipe.toPos, last)
        }

        let nodeColorIndex = wasActive
            ? (currentPipes.first { $0.toID == commitID }?.colorIndex ?? Self.spineColorIndex)
            : freeColorIndex(reserved: topLaneColorIndices, spineFallback: primaryRanks[commitID] != nil)

        var segments: [GitGraphSegment] = []
        if wasActive {
            segments.append(GitGraphSegment(kind: .incoming, from: .top(lane: pos), to: .node(lane: pos),
                                            colorIndex: nodeColorIndex, commitID: commitID, parentID: nil))
        }
        for pipe in newPipes where pipe.kind == .continues {
            segments.append(GitGraphSegment(kind: .passthrough, from: .top(lane: pipe.fromPos),
                                            to: .bottom(lane: pipe.toPos), colorIndex: pipe.colorIndex,
                                            commitID: pipe.toID, parentID: nil))
        }
        for pipe in newPipes where pipe.kind == .terminates {
            segments.append(GitGraphSegment(kind: .parent, from: .top(lane: pipe.fromPos), to: .node(lane: pos),
                                            colorIndex: pipe.colorIndex, commitID: pipe.fromID, parentID: pipe.toID))
        }

        // First parent continues this commit's own line; extra parents fork.
        // Parent edges are emitted AFTER lane promotion/compaction below, so
        // their target lane matches bottomLanes exactly.
        var starts: [Pipe] = []
        if let firstParent = uniqueParentIDs.first {
            starts.append(Pipe(fromPos: pos, toPos: pos, fromID: commitID, toID: firstParent,
                               kind: .starts, colorIndex: nodeColorIndex))
        }
        for parentID in uniqueParentIDs.dropFirst() {
            let available = nextPosForNewPipe()
            let color = freeColorIndex(reserved: topLaneColorIndices + starts.map(\.colorIndex), spineFallback: false)
            starts.append(Pipe(fromPos: pos, toPos: available, fromID: commitID, toID: parentID,
                               kind: .starts, colorIndex: color))
        }

        // Downstream: live pipes plus new starts. Sort by lane, promote the
        // nearest unprocessed spine pipe to lane 0 with the trunk colour, and
        // compact remaining lanes so no holes appear.
        var downstream = newPipes.filter { $0.kind != .terminates }
        downstream.append(contentsOf: starts)
        downstream.sort { ($0.toPos, $0.kind.rawValue) < ($1.toPos, $1.kind.rawValue) }
        if let spineIndex = downstream.indices.filter({ primaryRanks[downstream[$0].toID] != nil }).min(by: {
            primaryRanks[downstream[$0].toID, default: .max] < primaryRanks[downstream[$1].toID, default: .max]
        }), spineIndex != 0 {
            let spine = downstream.remove(at: spineIndex)
            downstream.insert(Pipe(fromPos: spine.toPos, toPos: 0, fromID: spine.fromID, toID: spine.toID,
                                   kind: spine.kind, colorIndex: Self.spineColorIndex), at: 0)
        }
        if !downstream.isEmpty, primaryRanks[downstream[0].toID] != nil {
            downstream[0].colorIndex = Self.spineColorIndex
        }
        for index in downstream.indices where index > 0 && downstream[index].toPos <= downstream[index - 1].toPos {
            downstream[index].toPos = downstream[index - 1].toPos + 1
        }

        // Emit parent edges for this commit using the final lane positions, so
        // bottomLanes[edge.to.lane] == edge.parentID always holds.
        for pipe in downstream where pipe.fromID == commitID && pipe.kind == .starts {
            segments.append(GitGraphSegment(kind: .parent, from: .node(lane: pos), to: .bottom(lane: pipe.toPos),
                                            colorIndex: pipe.colorIndex, commitID: commitID, parentID: pipe.toID))
        }

        // Colours that left the active set become reusable one palette cycle
        // from now (Git Graph's availableColours).
        let liveColours = Set(downstream.map(\.colorIndex))
        for color in Set(topLaneColorIndices).subtracting(liveColours) where color != Self.spineColorIndex {
            colorLastUsedRow[color] = rowIndex
        }
        pipes = downstream
        rowIndex += 1

        // bottomLanes is indexed by lane position: bottomLanes[lane] is the
        // commit occupying that lane below this row, matching the contract the
        // renderer and tests rely on (and what topLanes provides above).
        var bottomLanes: [GitCommitID] = []
        for pipe in downstream {
            while bottomLanes.count <= pipe.toPos { bottomLanes.append(pipe.toID) }
            bottomLanes[pipe.toPos] = pipe.toID
        }

        return GitGraphRow(
            commitID: commitID,
            parentIDs: uniqueParentIDs,
            topLanes: topLanes,
            bottomLanes: bottomLanes,
            nodeLane: pos,
            nodeColorIndex: nodeColorIndex,
            segments: segments,
            isRemoteOnly: isRemoteOnly.contains(commitID)
        )
    }

    /// Git Graph's availableColours: prefer the palette slot whose last
    /// retirement is at least one full palette cycle away. The trunk slot is
    /// reserved for the first-parent spine unless `spineFallback` is set.
    private mutating func freeColorIndex(reserved: [Int], spineFallback: Bool) -> Int {
        if spineFallback { return Self.spineColorIndex }
        let slots = Array(1..<GitGraphRow.paletteSize)
        let reservedSet = Set(reserved)
        for color in slots where !reservedSet.contains(color)
            && (colorLastUsedRow[color] ?? Int.min) + GitGraphRow.paletteSize <= rowIndex {
            return color
        }
        if let color = slots.filter({ !reservedSet.contains($0) }).min() { return color }
        return slots.min { (colorLastUsedRow[$0] ?? Int.min) < (colorLastUsedRow[$1] ?? Int.min) } ?? 1
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
    static let spineColorIndex = GitGraphLayout.spineColorIndex

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
