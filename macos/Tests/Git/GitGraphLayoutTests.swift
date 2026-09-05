import Testing
@testable import Ghostty

struct GitGraphLayoutTests {
    @Test func linearHistoryKeepsParentConnectivityUntilRoot() {
        var layout = GitGraphLayout()

        let rowA = layout.append(commitID: id("a"), parentIDs: [id("b")])
        #expect(rowA.nodeLane == 0)
        #expect(rowA.bottomLanes == [id("b")])
        #expect(rowA.containsParentEdge(from: id("a"), to: id("b")))

        let rowB = layout.append(commitID: id("b"), parentIDs: [id("c")])
        #expect(rowB.topLanes == [id("b")])
        #expect(rowB.bottomLanes == [id("c")])
        #expect(rowB.containsIncoming(commitID: id("b"), lane: 0))
        #expect(rowB.containsParentEdge(from: id("b"), to: id("c")))

        let rowC = layout.append(commitID: id("c"), parentIDs: [])
        #expect(rowC.topLanes == [id("c")])
        #expect(rowC.bottomLanes == [])
        #expect(rowC.containsIncoming(commitID: id("c"), lane: 0))
        #expect(layout.activeCommitIDs == [])
    }

    @Test func mergeReusesExistingParentLaneWithoutDuplicateActiveParents() {
        var layout = GitGraphLayout()

        let merge = layout.append(commitID: id("merge"), parentIDs: [id("left"), id("right")])
        #expect(merge.bottomLanes == [id("left"), id("right")])
        #expect(merge.containsParentEdge(from: id("merge"), to: id("left")))
        #expect(merge.containsParentEdge(from: id("merge"), to: id("right")))

        let left = layout.append(commitID: id("left"), parentIDs: [id("base")])
        #expect(left.topLanes == [id("left"), id("right")])
        #expect(left.bottomLanes == [id("base"), id("right")])
        #expect(left.containsPassthrough(commitID: id("right"), from: 1, to: 1))
        #expect(left.containsParentEdge(from: id("left"), to: id("base")))

        let right = layout.append(commitID: id("right"), parentIDs: [id("base")])
        #expect(right.topLanes == [id("base"), id("right")])
        #expect(right.bottomLanes == [id("base")])
        #expect(right.containsPassthrough(commitID: id("base"), from: 0, to: 0))
        #expect(right.containsParentEdge(from: id("right"), to: id("base")))
        #expect(layout.activeCommitIDs == [id("base")])
    }

    @Test func octopusMergeTracksEveryUnprocessedParentInOrder() {
        var layout = GitGraphLayout()

        let row = layout.append(
            commitID: id("octopus"),
            parentIDs: [id("p1"), id("p2"), id("p3")]
        )

        #expect(row.bottomLanes == [id("p1"), id("p2"), id("p3")])
        #expect(layout.activeCommitIDs == [id("p1"), id("p2"), id("p3")])
        #expect(row.containsParentEdge(from: id("octopus"), to: id("p1")))
        #expect(row.containsParentEdge(from: id("octopus"), to: id("p2")))
        #expect(row.containsParentEdge(from: id("octopus"), to: id("p3")))
    }

    @Test func independentRootsDoNotLeaveActiveLanes() {
        var layout = GitGraphLayout()

        let first = layout.append(commitID: id("root-a"), parentIDs: [])
        let second = layout.append(commitID: id("root-b"), parentIDs: [])

        #expect(first.nodeLane == 0)
        #expect(second.nodeLane == 0)
        #expect(first.bottomLanes == [])
        #expect(second.bottomLanes == [])
        #expect(first.segments.isEmpty)
        #expect(second.segments.isEmpty)
        #expect(layout.activeCommitIDs == [])
    }

    @Test func appendingMoreRowsDoesNotMutateEarlierOutput() {
        var layout = GitGraphLayout()

        let first = layout.append(commitID: id("merge"), parentIDs: [id("left"), id("right")])
        let captured = first

        _ = layout.append(commitID: id("left"), parentIDs: [id("base")])
        _ = layout.append(commitID: id("right"), parentIDs: [id("base")])

        #expect(first == captured)
        #expect(first.bottomLanes == [id("left"), id("right")])
    }

    @Test func pagedAppendMatchesSinglePassRowsAndFinalLanes() {
        let history: [(GitCommitID, [GitCommitID])] = [
            (id("merge"), [id("left"), id("right")]),
            (id("left"), [id("base")]),
            (id("right"), [id("base")]),
            (id("base"), []),
            (id("next-root"), []),
        ]

        var singlePass = GitGraphLayout()
        let singleRows = history.map { singlePass.append(commitID: $0.0, parentIDs: $0.1) }

        var paged = GitGraphLayout()
        let firstPage = history.prefix(2).map { paged.append(commitID: $0.0, parentIDs: $0.1) }
        let secondPage = history.dropFirst(2).map { paged.append(commitID: $0.0, parentIDs: $0.1) }

        #expect(firstPage + secondPage == singleRows)
        #expect(paged.activeCommitIDs == singlePass.activeCommitIDs)
    }

    @Test func duplicateParentIDsProduceOneActiveLaneAndOneEdge() {
        var layout = GitGraphLayout()

        let row = layout.append(commitID: id("dup"), parentIDs: [id("parent"), id("parent")])

        #expect(row.parentIDs == [id("parent")])
        #expect(row.bottomLanes == [id("parent")])
        #expect(row.segments.filter { $0.kind == .parent }.count == 1)
    }
}

private func id(_ rawValue: String) -> GitCommitID {
    GitCommitID(rawValue)
}

private extension GitGraphRow {
    func containsIncoming(commitID: GitCommitID, lane: Int) -> Bool {
        segments.contains {
            $0.kind == .incoming
                && $0.commitID == commitID
                && $0.from == .top(lane: lane)
                && $0.to == .node(lane: lane)
        }
    }

    func containsPassthrough(commitID: GitCommitID, from: Int, to: Int) -> Bool {
        segments.contains {
            $0.kind == .passthrough
                && $0.commitID == commitID
                && $0.from == .top(lane: from)
                && $0.to == .bottom(lane: to)
        }
    }

    func containsParentEdge(from commitID: GitCommitID, to parentID: GitCommitID) -> Bool {
        segments.contains {
            $0.kind == .parent
                && $0.commitID == commitID
                && $0.parentID == parentID
        }
    }
}
