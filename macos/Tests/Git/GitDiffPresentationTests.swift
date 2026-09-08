import Testing
@testable import Ghostty

struct GitDiffPresentationTests {
    @Test func inlineIncludesUnchangedSourceAndBothSidesOfReplacement() {
        let value = GitDiffPresentation(before: "one\nold\nlast\n", after: "one\nnew\nextra\nlast\n",
                                        patch: "@@ -1,3 +1,4 @@\n one\n-old\n+new\n+extra\n last\n")
        #expect(value.isConsistent)
        #expect(value.text == "one\nold\nnew\nextra\nlast")
        #expect(value.highlights == [1: false, 2: true, 3: true])
        #expect(value.beforeToAfter[2] == 3)
        #expect(value.afterToBefore[3] == 2)
        #expect(value.rows[1].beforeLine == 2 && value.rows[1].afterLine == nil)
        #expect(value.rows[3].afterLine == 3 && value.rows[3].beforeLine == nil)
    }

    @Test func zeroContextInsertionAndDeletionMapFollowingLines() {
        let insertion = GitDiffPresentation(before: "a\nb\nc\n", after: "a\nx\ny\nb\nc\n",
                                             patch: "@@ -1,0 +2,2 @@\n+x\n+y\n")
        #expect(insertion.isConsistent)
        #expect(insertion.beforeToAfter[1] == 3)
        #expect(insertion.afterToBefore[4] == 2)
        let deletion = GitDiffPresentation(before: "a\nb\nc\n", after: "a\nc\n",
                                            patch: "@@ -2 +1,0 @@\n-b\n")
        #expect(deletion.isConsistent)
        #expect(deletion.beforeToAfter[2] == 1)
    }

    @Test func emptyFileAndCRLFAndStaleSnapshot() {
        let added = GitDiffPresentation(before: "", after: "let x = 1\r\n", patch: "@@ -0,0 +1 @@\n+let x = 1\n")
        #expect(added.isConsistent && added.highlights == [0: true])
        let removed = GitDiffPresentation(before: "gone\n", after: "", patch: "@@ -1 +0,0 @@\n-gone\n")
        #expect(removed.isConsistent && removed.highlights == [0: false])
        let stale = GitDiffPresentation(before: "old\n", after: "newer\n", patch: "@@ -1 +1 @@\n-old\n+new\n")
        #expect(!stale.isConsistent)
    }

    @Test func branchTreeSeparatesLocalRemoteAndFolderPrefixes() {
        let id = GitCommitID("abc")
        let branches = [
            GitBranchInfo(name: "feature/one", commit: id, isCurrent: true, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "feature/two", commit: id, isCurrent: false, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "origin/feature/one", commit: id, isCurrent: false, isRemote: true, upstream: "", tracking: ""),
        ]
        let roots = GitBranchNode.build(branches)
        #expect(roots[0].children[0].title == "feature")
        #expect(roots[0].children[0].children.count == 2)
        #expect(roots[1].children[0].title == "origin")
        #expect(roots[1].children[0].children[0].children[0].branch?.isRemote == true)
    }
}
