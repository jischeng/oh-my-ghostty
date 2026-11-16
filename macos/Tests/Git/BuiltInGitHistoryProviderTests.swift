import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct BuiltInGitHistoryProviderTests {
    private func createTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("git-history-provider-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runCommand(_ args: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_AUTHOR_NAME": "Provider Test",
            "GIT_AUTHOR_EMAIL": "provider@example.com",
            "GIT_COMMITTER_NAME": "Provider Test",
            "GIT_COMMITTER_EMAIL": "provider@example.com",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitHistoryProviderTest", code: Int(process.terminationStatus))
        }
    }

    @Test func favoritesScopeLoadsAndRefreshesTheUnionOfSelectedTips() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "base"], in: directory.path)
        try runCommand(["git", "branch", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "main tip"], in: directory.path)
        try runCommand(["git", "checkout", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "feature tip"], in: directory.path)
        try runCommand(["git", "checkout", "main"], in: directory.path)
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal",
                                           workingDirectory: directory.path)
        let oldScope = OhMyGhosttySettings.shared.gitHistoryScope
        defer {
            OhMyGhosttySettings.shared.gitHistoryScope = oldScope
            registry.presentationDidChange(to: nil, context: context)
        }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        func waitFor(_ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<100 {
                if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !content.isLoading, !content.history.isLoading, predicate(content) { return content }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "GitProviderTimeout", code: 1)
        }
        let initial = try await waitFor { $0.repository != nil && $0.history.snapshot != nil }
        let store = GitHistoryBranchFavorites(repository: try #require(initial.repository))
        defer { for ref in store.refs { store.toggle(ref) } }
        store.toggle("HEAD")
        store.toggle("refs/heads/feature")
        func selectFavorites() {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                                   action: .init(context: context, kind: .gitAction(.selectHistoryScope(.favorites))))
        }
        selectFavorites()
        let both = try await waitFor { $0.history.scope == .favorites && $0.history.commits.count == 3 }
        #expect(Set(both.history.commits.map(\.subject)) == ["base", "main tip", "feature tip"])
        store.toggle("HEAD")
        selectFavorites()
        let feature = try await waitFor { $0.history.scope == .favorites && $0.history.commits.count == 2 }
        #expect(Set(feature.history.commits.map(\.subject)) == ["base", "feature tip"])
    }

    @Test func checkboxCommitClearsDraftOnlyOnSuccessAndRetainsItOnHookFailure() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "config", "user.name", "Provider Test"], in: directory.path)
        try runCommand(["git", "config", "user.email", "provider@example.com"], in: directory.path)
        try runCommand(["git", "config", "commit.gpgSign", "false"], in: directory.path)
        try runCommand(["git", "config", "core.hooksPath", directory.path + "/.git/hooks"], in: directory.path)
        let file = directory.appendingPathComponent("file.txt")
        try Data("first".utf8).write(to: file)
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal",
                                           workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        func send(_ action: InspectorGitAction) {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                                   action: .init(context: context, kind: .gitAction(action)))
        }
        func waitFor(_ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<100 {
                if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !content.isLoading, content.operation == nil, predicate(content) { return content }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "GitProviderTimeout", code: 1)
        }
        let initial = try await waitFor { !$0.workingTree.unstaged.isEmpty }
        send(.updateCommitDraft("first"))
        send(.setFileStaged(initial.workingTree.unstaged[0], true))
        if case .git(let pending) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) {
            #expect(pending.isUpdatingIndex && !pending.isLoading)
            #expect(pending.workingTree.unstaged == initial.workingTree.unstaged)
            #expect(pending.commitDraft == "first")
        } else { Issue.record("Missing content during stage") }
        let staged = try await waitFor { $0.workingTree.staged.count == 1 }
        #expect(!staged.isUpdatingIndex && staged.commitDraft == "first")
        send(.commitStaged)
        let committed = try await waitFor { $0.history.commits.count == 1 && $0.workingTree.staged.isEmpty }
        #expect(committed.commitDraft.isEmpty)
        try Data("second".utf8).write(to: file)
        send(.refresh)
        let changed = try await waitFor { !$0.workingTree.unstaged.isEmpty }
        send(.setFileStaged(changed.workingTree.unstaged[0], true))
        _ = try await waitFor { $0.workingTree.staged.count == 1 }
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho rejected-by-test-hook >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        send(.updateCommitDraft("keep this draft"))
        send(.commitStaged)
        let rejected = try await waitFor { $0.operationError != nil }
        #expect(rejected.commitDraft == "keep this draft")
        #expect(rejected.workingTree.staged.count == 1)
        #expect(rejected.history.commits.count == 1)
        send(.clearOperationError)
        _ = try await waitFor { $0.operationError == nil }
    }

    @Test func changesAndBranchHistoryUseRealRepositoryData() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "base"], in: directory.path)
        try runCommand(["git", "branch", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "main only"], in: directory.path)
        try Data("untracked".utf8).write(to: directory.appendingPathComponent("new.swift"))
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal",
                                           workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        var initial: InspectorGitContent?
        for _ in 0..<80 {
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
               content.history.commits.count == 2, !content.isLoading {
                initial = content
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let loaded = try #require(initial)
        #expect(loaded.workingTree.unstaged.contains { $0.path == "new.swift" && $0.isUntracked })
        #expect(loaded.workingTree.branches.contains { $0.name == "main" && $0.isCurrent })
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.browseBranch("refs/heads/feature"))))
        for _ in 0..<80 {
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
               content.history.snapshot?.browsedBranch == "feature", !content.isLoading, !content.history.isLoading {
                #expect(content.branch == "main")
                #expect(content.activeTab == .history)
                #expect(content.history.commits.map(\.subject) == ["base"])
                registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                    action: .init(context: context, kind: .gitAction(.selectHistoryScope(.allBranches))))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Selected branch history was not loaded")
    }

    @Test func cachesHistoryAndSelectionPerWorktree() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "first"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "second"], in: directory.path)
        let subdirectory = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let tabID = UUID()
        let context = InspectorPaneContext(tabID: tabID, surfaceID: UUID(), title: "Terminal", workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)

        var selectedID: GitCommitID?
        for _ in 0..<40 {
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
               let commit = content.history.commits.first {
                #expect(content.history.scope == .allBranches)
                selectedID = commit.id
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let id = try #require(selectedID)
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID, action: .init(context: context, kind: .gitAction(.selectCommit(id))))

        let nestedContext = InspectorPaneContext(tabID: tabID, surfaceID: UUID(), title: "Terminal", workingDirectory: subdirectory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: nestedContext)
        for _ in 0..<40 {
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: nestedContext),
               content.history.selectedCommitID == id {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("History selection was not retained for the same worktree")
    }

    @Test func scopeAndBranchSwitchesReuseSnapshotAndSortedTagsWithoutExtraGitQueries() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "base"], in: directory.path)
        try runCommand(["git", "tag", "v1.0"], in: directory.path)
        try runCommand(["git", "branch", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "main tip"], in: directory.path)
        try runCommand(["git", "tag", "v2.0"], in: directory.path)
        try runCommand(["git", "checkout", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "feature tip"], in: directory.path)
        try runCommand(["git", "checkout", "main"], in: directory.path)

        let spy = HistoryCommandSpy()
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, executor: spy)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal",
                                           workingDirectory: directory.path)
        let oldScope = OhMyGhosttySettings.shared.gitHistoryScope
        OhMyGhosttySettings.shared.gitHistoryScope = GitHistoryScope.allBranches.rawValue
        defer {
            OhMyGhosttySettings.shared.gitHistoryScope = oldScope
            registry.presentationDidChange(to: nil, context: context)
        }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)

        func waitFor(_ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<100 {
                if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !content.isLoading, !content.history.isLoading, predicate(content) { return content }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "GitProviderTimeout", code: 1)
        }

        let initial = try await waitFor { $0.repository != nil && $0.history.snapshot != nil && $0.history.commits.count == 3 }
        #expect(initial.history.snapshot?.sortedTags.map(\.name) == ["v1.0", "v2.0"])
        let store = GitHistoryBranchFavorites(repository: try #require(initial.repository))
        defer { for ref in store.refs { store.toggle(ref) } }
        store.toggle("refs/heads/feature")

        func switchAndVerify(
            _ action: InspectorGitAction,
            predicate: (InspectorGitContent) -> Bool
        ) async throws -> InspectorGitContent {
            await spy.reset()
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                                   action: .init(context: context, kind: .gitAction(action)))
            if case .git(let loading) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) {
                #expect(loading.history.isLoading)
                #expect(loading.history.snapshot?.sortedTags.map(\.name) == ["v1.0", "v2.0"])
            } else {
                Issue.record("Missing content immediately after scope/branch switch")
            }
            let settled = try await waitFor(predicate)
            let recorded = await spy.commands
            #expect(recorded.count == 1)
            #expect(recorded.first?.contains("log") == true)
            #expect(!recorded.contains {
                $0.contains("for-each-ref") || $0.contains("rev-list") || $0.contains("symbolic-ref")
            })
            return settled
        }

        let current = try await switchAndVerify(.selectHistoryScope(.currentBranch)) {
            $0.history.scope == .currentBranch && $0.history.commits.count == 2
        }
        #expect(current.history.commits.map(\.subject) == ["main tip", "base"])

        let favorites = try await switchAndVerify(.selectHistoryScope(.favorites)) {
            $0.history.scope == .favorites && $0.history.commits.count == 2
        }
        #expect(favorites.history.commits.map(\.subject) == ["feature tip", "base"])

        let all = try await switchAndVerify(.selectHistoryScope(.allBranches)) {
            $0.history.scope == .allBranches && $0.history.commits.count == 3
        }
        #expect(Set(all.history.commits.map(\.subject)) == ["base", "main tip", "feature tip"])

        let browsed = try await switchAndVerify(.browseBranch("refs/heads/feature")) {
            $0.history.snapshot?.browsedBranch == "feature" && $0.history.commits.count == 2
        }
        #expect(browsed.history.commits.map(\.subject) == ["feature tip", "base"])

        let browsedTag = try await switchAndVerify(.browseRef("refs/tags/v1.0")) {
            $0.history.snapshot?.browsedBranch == "v1.0" && $0.history.commits.count == 1
        }
        #expect(browsedTag.history.commits.map(\.subject) == ["base"])
    }

    @Test func favoritedDetachedWorktreeIsIncludedInFavoritesAfterSwitchAndRefresh() async throws {
        let directory = createTempDirectory()
        let worktreeDirectory = createTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: worktreeDirectory)
            try? FileManager.default.removeItem(at: directory)
        }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "base"], in: directory.path)
        try runCommand(["git", "branch", "side"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "main tip"], in: directory.path)
        try runCommand(["git", "checkout", "side"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "detached worktree tip"], in: directory.path)
        let detachedPath = worktreeDirectory.appendingPathComponent("detached-wt").path
        try runCommand(["git", "worktree", "add", "--detach", "--", detachedPath, "HEAD"], in: directory.path)
        try runCommand(["git", "checkout", "main"], in: directory.path)
        try runCommand(["git", "branch", "-D", "side"], in: directory.path)

        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal",
                                           workingDirectory: directory.path)
        let oldScope = OhMyGhosttySettings.shared.gitHistoryScope
        OhMyGhosttySettings.shared.gitHistoryScope = GitHistoryScope.allBranches.rawValue
        defer {
            OhMyGhosttySettings.shared.gitHistoryScope = oldScope
            registry.presentationDidChange(to: nil, context: context)
        }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)

        func waitFor(_ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<100 {
                if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !content.isLoading, !content.history.isLoading, predicate(content) { return content }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "GitProviderTimeout", code: 1)
        }

        let initial = try await waitFor {
            $0.repository != nil && $0.history.snapshot != nil && $0.workingTree.worktrees.count == 2
        }
        #expect(initial.history.commits.map(\.subject) == ["main tip", "base"])

        let detachedTree = try #require(initial.workingTree.worktrees.first { !$0.isCurrent && $0.branchRef == nil })
        let store = GitHistoryBranchFavorites(repository: try #require(initial.repository))
        defer { for ref in store.refs { store.toggle(ref) } }
        store.toggle(GitHistoryBranchFavorites.worktreeID(path: detachedTree.path))

        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.selectHistoryScope(.favorites))))
        let switched = try await waitFor { $0.history.scope == .favorites && $0.history.commits.count == 2 }
        #expect(switched.history.commits.map(\.subject) == ["detached worktree tip", "base"])

        try runCommand(["git", "commit", "--allow-empty", "-m", "detached second"], in: detachedPath)
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.refresh)))
        let refreshed = try await waitFor { $0.history.scope == .favorites && $0.history.commits.count == 3 }
        #expect(refreshed.history.commits.map(\.subject) == ["detached second", "detached worktree tip", "base"])

        let updatedTree = try #require(refreshed.workingTree.worktrees.first { !$0.isCurrent && $0.branchRef == nil })
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.browseWorktree(updatedTree.path))))
        let browsed = try await waitFor { $0.history.snapshot?.browsedWorktree == updatedTree.path }
        #expect(browsed.history.snapshot?.headCommitID == updatedTree.head)
        #expect(browsed.history.snapshot?.repositoryHeadCommitID == initial.history.snapshot?.repositoryHeadCommitID)
        #expect(browsed.history.commits.map(\.subject) == ["detached second", "detached worktree tip", "base"])

        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.selectHistoryScope(.currentBranch))))
        let current = try await waitFor {
            $0.history.scope == .currentBranch && $0.history.snapshot?.browsedWorktree == nil && $0.history.commits.count == 2
        }
        #expect(current.history.snapshot?.headCommitID == initial.history.snapshot?.repositoryHeadCommitID)
        #expect(current.history.commits.map(\.subject) == ["main tip", "base"])
    }
}

private actor HistoryCommandSpy: GitExecutor {
    private(set) var commands: [[String]] = []

    func reset() {
        commands.removeAll()
    }

    func execute(
        arguments: [String],
        workingDirectory: String,
        stdin: Data?,
        maxOutputBytes: Int?
    ) async throws -> GitExecutionResult {
        commands.append(arguments)
        return try await LocalGitExecutor().execute(
            arguments: arguments,
            workingDirectory: workingDirectory,
            stdin: stdin,
            maxOutputBytes: maxOutputBytes
        )
    }
}
