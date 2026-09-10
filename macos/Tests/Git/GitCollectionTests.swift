import AppKit
import CodeEditSourceEditor
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitCollectionTests {
    private func branch(_ name: String, remote: Bool = false) -> GitBranchInfo {
        .init(name: name, commit: .init("abc1234"), isCurrent: name == "main", isRemote: remote, upstream: "", tracking: "")
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
    private func window(_ view: NSView, width: CGFloat = 320, height: CGFloat = 460) -> NSWindow {
        let result = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        result.contentView = view
        result.makeKeyAndOrderFront(nil)
        return result
    }

    @Test func changesIdentityIncludesIndexSideButNotMutableStatus() {
        let file = GitDiffFile(path: "src/query/parser.cpp", status: "M")
        let source = GitCollectionSource.changes(staged: [file], unstaged: [file], stagedError: nil, unstagedError: nil)
        for mode in GitCollectionMode.allCases {
            let rows = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: source, mode: mode))
            let leaves = rows.filter { if case .file = $0.item.kind { return true }; return false }
            #expect(leaves.count == 2 && Set(leaves.map(\.id)).count == 2)
            #expect(Set(leaves.map(\.id)) == [GitChangeSection.staged.rowID(path: file.path), GitChangeSection.unstaged.rowID(path: file.path)])
        }
        let changed = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(
            source: .changes(staged: [.init(path: file.path, status: "A")], unstaged: [], stagedError: nil, unstagedError: nil), mode: .list))
        #expect(changed.contains { $0.id == GitChangeSection.staged.rowID(path: file.path) })
    }

    @Test func refModesKeepFullRefsAndGroupRemoteBeforeBranchPath() {
        let branches = [branch("main"), branch("feature/query/parser"), branch("origin/feature/foo", remote: true), branch("upstream/main", remote: true)]
        let tree = GitCollectionBuilder.nodes(source: .refs(branches: branches, worktrees: [], scopes: false, branchesError: nil, worktreesError: nil), mode: .tree)
        #expect(tree.map(\.item.title) == ["Branches", "Remote Branches", "Worktrees"])
        #expect(tree[1].children.map(\.item.title) == ["origin", "upstream"])
        #expect(tree[1].children[0].children[0].item.title == "feature")
        let list = GitCollectionBuilder.nodes(source: .refs(branches: branches, worktrees: [], scopes: false, branchesError: nil, worktreesError: nil), mode: .list)
        func refs(_ nodes: [GitCollectionNode]) -> Set<String> {
            Set(GitCollectionBuilder.rows(nodes).compactMap { row in
                if case .branch(let branch, _) = row.item.kind { return branch.id }; return nil
            })
        }
        #expect(refs(tree) == Set(branches.map(\.id)))
        #expect(refs(tree) == refs(list))
    }

    @Test func searchFindsBranchesWorktreesAndDetachedHeadsWithoutLosingCategories() {
        let branches = [branch("main"), branch("feature/Query"), branch("origin/feature/query", remote: true)]
        let worktree = GitWorktreeInfo(path: "/dev/feature-worktree", head: .init("abc123456789"), branchRef: "refs/heads/feature/Query", isMain: false, isCurrent: false)
        let detached = GitWorktreeInfo(path: "/dev/detached", head: .init("def123456789"), branchRef: nil, isMain: false, isCurrent: false)
        let source = GitCollectionSource.refs(branches: branches, worktrees: [worktree, detached], scopes: true, branchesError: nil, worktreesError: nil)
        let matched = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: source, mode: .tree, query: "QUERY"))
        #expect(matched.filter { $0.item.isCategory }.map(\.item.title) == ["Branches", "Remote Branches", "Worktrees"])
        #expect(matched.contains { $0.id == "refs/heads/feature/Query" })
        #expect(matched.contains { $0.id == "refs/remotes/origin/feature/query" })
        #expect(matched.contains { $0.id == "worktree:" + worktree.path })
        #expect(!matched.contains { if case .scope = $0.item.kind { return true }; return false })
        if case .branch(_, let paths) = matched.first(where: { $0.id == "refs/heads/feature/Query" })?.item.kind {
            #expect(paths == [worktree.path])
        } else { Issue.record("Expected associated worktree metadata") }
        let byHead = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: source, mode: .list, query: "DEF123"))
        #expect(byHead.contains { $0.id == "worktree:" + detached.path && $0.item.title == detached.head?.shortSHA })
    }

    @Test func treeExpansionSurvivesIndexPatchesAndPresentationChanges() async throws {
        let first = GitDiffFile(path: "src/one.cpp", status: "M")
        let second = GitDiffFile(path: "src/query/two.cpp", status: "M")
        let other = GitDiffFile(path: "other.cpp", status: "M")
        let state = GitCollectionState()
        var root = GitCollectionView(source: .changes(staged: [], unstaged: [first, second, other], stagedError: nil, unstagedError: nil),
            mode: .tree, state: state, stateKey: "test/changes", perform: { _ in })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let win = window(host)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        let folder = "changes/unstaged/folder/src"
        coordinator.toggleFolder(folder)
        #expect(!coordinator.rows.contains { $0.id == GitChangeSection.unstaged.rowID(path: second.path) })
        root.source = .changes(staged: [first], unstaged: [second, other], stagedError: nil, unstagedError: nil)
        host.rootView = root
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.collapsed["test/changes"]?.contains(folder) == true)
        #expect(coordinator.rows.first { $0.id == folder }?.expanded == false)
        root.mode = .list
        host.rootView = root
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.rows.contains { $0.id == GitChangeSection.unstaged.rowID(path: second.path) })
        root.mode = .tree
        host.rootView = root
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.rows.first { $0.id == folder }?.expanded == false)
        #expect(find(GitCollectionTableView.self, in: host).first === table)
    }

    @Test func pendingAndCheckboxStatesUseThemeTokensAndPreserveUnrelatedCells() async throws {
        let one = GitDiffFile(path: "one.cpp", status: "A", isUntracked: true)
        let two = GitDiffFile(path: "two.cpp", status: "M")
        var colors = GitCollectionColors()
        colors.text = .systemMint
        colors.accent = .systemPurple
        #expect(colors.status(one) == colors.secondary)
        var root = GitCollectionView(source: .changes(staged: [], unstaged: [one, two], stagedError: nil, unstagedError: nil), perform: { _ in })
        let host = NSHostingView(rootView: root.environment(\.gitCollectionColors, colors))
        host.sizingOptions = []
        let win = window(host)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        func cell(_ path: String, section: GitChangeSection) throws -> GitCollectionCell {
            let row = try #require(coordinator.rows.firstIndex { $0.id == section.rowID(path: path) })
            return try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? GitCollectionCell)
        }
        let untouched = try cell(two.path, section: .unstaged)
        #expect(try cell(one.path, section: .unstaged).checkbox.state == .off)
        root.pending = [one.path]
        host.rootView = root.environment(\.gitCollectionColors, colors)
        try await Task.sleep(for: .milliseconds(50))
        let pending = try cell(one.path, section: .unstaged)
        #expect(pending.checkbox.isHidden && !pending.checkbox.isEnabled)
        #expect(try cell(two.path, section: .unstaged) === untouched)
        root.pending = []
        root.source = .changes(staged: [.init(path: one.path, status: "A")], unstaged: [two], stagedError: nil, unstagedError: nil)
        host.rootView = root.environment(\.gitCollectionColors, colors)
        try await Task.sleep(for: .milliseconds(50))
        let checked = try cell(one.path, section: .staged).checkbox
        #expect(checked.state == .on && !checked.isHidden && checked.isEnabled)
        #expect(checked.contentTintColor == colors.accent)
        #expect(try cell(two.path, section: .unstaged) === untouched)
    }

    @Test func collectionsRenderListAndTreeWithResolvedLightDarkAndCustomThemes() async throws {
        let themes: [(String, String, NSAppearance.Name)] = [
            ("light", "background = f8f8f8\nforeground = 202124\npalette = 4=#4268a4\n", .aqua),
            ("dark", "background = 202126\nforeground = d9dbe3\npalette = 4=#80a9dc\n", .darkAqua),
            ("custom", "background = 20382e\nforeground = dce8d3\npalette = 1=#d79a87\npalette = 2=#93b97d\npalette = 3=#d4c493\npalette = 4=#b5ba78\n", .darkAqua),
        ]
        let staged = [GitDiffFile(path: "foo.cpp", status: "M"), .init(path: "src/query/parser.cpp", status: "A")]
        let unstaged = [GitDiffFile(path: "src/query/parser.cpp", status: "M"),
            .init(path: "src/queries/a-very-long-query-directory/predicate_normalization_pass.cpp", status: "M"),
            .init(path: "src/renamed.cpp", oldPath: "src/original.cpp", status: "R100"),
            .init(path: "tests/removed.cpp", status: "D"),
            .init(path: "generated/diagnostics/results.json", status: "A", isUntracked: true)]
        for (name, text, appearance) in themes {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("git-colors-\(UUID().uuidString)")
            try text.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let config = Ghostty.Config(at: file.path)
            let colors = GitCollectionColors(config: config, background: NSColor(config.backgroundColor))
            #expect(colors.text == config.editorTheme(background: colors.background).text)
            #expect(colors.status(unstaged.last!) == colors.secondary)
            for mode in GitCollectionMode.allCases {
                let content = VStack(spacing: 0) {
                    GitCollectionToolbar(query: .constant(""), mode: .constant(mode), placeholder: "Search files…", controller: GitCollectionController()).padding(10)
                    GitCollectionView(source: .changes(staged: staged, unstaged: unstaged, stagedError: nil, unstagedError: nil),
                        mode: mode, pending: [unstaged[1].path], perform: { _ in })
                }.background(Color(colors.background)).environment(\.gitCollectionColors, colors)
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                let win = window(host, width: 340, height: 620)
                win.appearance = NSAppearance(named: appearance)
                defer { win.contentView = nil; win.close() }
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                let table = try #require(find(GitCollectionTableView.self, in: host).first)
                let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
                let stagedRow = try #require(coordinator.rows.firstIndex { $0.id == GitChangeSection.staged.rowID(path: "foo.cpp") })
                let checked = try #require(table.view(atColumn: 0, row: stagedRow, makeIfNecessary: true) as? GitCollectionCell)
                #expect(checked.checkbox.state == .on && checked.checkbox.contentTintColor == colors.accent)
                if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "/tmp/omg-git-collection-\(mode.rawValue)-\(name).png"))
                }
            }
        }
    }

    @Test func largeIndexSnapshotTransitionKeepsVirtualizationAndUpdatesEveryCheckbox() async throws {
        let files = (0..<1200).map { GitDiffFile(path: "output/entry-\($0).json", status: "A", isUntracked: true) }
        var root = GitCollectionView(source: .changes(staged: [], unstaged: files, stagedError: nil, unstagedError: nil), perform: { _ in })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let win = window(host)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(80))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        let start = Date()
        root.source = .changes(staged: files.map { .init(path: $0.path, status: "A") }, unstaged: [], stagedError: nil, unstagedError: nil)
        host.rootView = root
        host.layoutSubtreeIfNeeded()
        let elapsed = Date().timeIntervalSince(start) * 1000
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.rows.filter { if case .file(_, .staged) = $0.item.kind { return true }; return false }.count == files.count)
        let visible = find(GitStageCheckbox.self, in: table).filter { !$0.isHidden }
        #expect(!visible.isEmpty && visible.count < 100)
        #expect(visible.allSatisfy { $0.state == .on })
        #expect(find(GitCollectionTableView.self, in: host).first === table)
        print("Git collection bulk index transition (1200 files): \(elapsed)ms; visible checkboxes=\(visible.count)")
    }
}
