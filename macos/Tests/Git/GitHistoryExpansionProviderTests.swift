import Foundation
import Testing
@testable import Ghostty

private actor OnePageFailure: GitExecutor {
    private var failed = false
    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        if arguments.contains("--skip=100"), !failed {
            failed = true
            return GitExecutionResult(exitCode: 1, stdout: Data(), stderr: Data("page probe failed".utf8))
        }
        return try await LocalGitExecutor().execute(arguments: arguments, workingDirectory: workingDirectory,
                                                     stdin: stdin, maxOutputBytes: maxOutputBytes)
    }
}

actor GitWorkingTreeReadProbe: GitExecutor {
    enum Component: CaseIterable, Sendable, Equatable { case staged, unstaged, branches }
    private var failure: Component?
    private(set) var writes = 0

    func fail(_ component: Component?) { failure = component }

    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        let component: Component?
        if arguments.contains("--porcelain=v1"), failure == .staged || failure == .unstaged {
            component = failure
        } else if arguments.contains("--cached") {
            component = .staged
        } else if arguments.contains("ls-files") {
            component = .unstaged
        } else if arguments.contains(where: { $0.contains("%(upstream:track)") }) {
            component = .branches
        } else { component = nil }
        if let component, component == failure {
            return GitExecutionResult(exitCode: 1, stdout: Data(), stderr: Data("\(component) read failed".utf8))
        }
        if arguments.contains("add") || arguments.contains("restore") || arguments.contains("reset") || arguments.first == "commit" { writes += 1 }
        return try await LocalGitExecutor().execute(arguments: arguments, workingDirectory: workingDirectory,
                                                     stdin: stdin, maxOutputBytes: maxOutputBytes)
    }
}

@MainActor
struct GitHistoryExpansionProviderTests {
    private func repository(commits: Int) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-expand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executor = LocalGitExecutor()
        let initialized = try await executor.execute(arguments: ["init", "-b", "main"], workingDirectory: directory.path)
        #expect(initialized.isSuccess)
        var input = ""
        for index in 0..<commits {
            let message = "Commit \(index)\n\nBody \(index)"
            let file = "let value = \(index)\n"
            input += "commit refs/heads/main\ncommitter Test <test@example.com> \(1700000000 + index) +0000\ndata \(message.utf8.count)\n\(message)\nM 100644 inline file.swift\ndata \(file.utf8.count)\n\(file)\n"
        }
        let result = try await executor.execute(arguments: ["fast-import", "--quiet"], workingDirectory: directory.path,
                                                stdin: Data(input.utf8), maxOutputBytes: 64 * 1024)
        try #require(result.isSuccess, Comment(rawValue: result.stderrString))
        return directory
    }

    private func waitFor(_ registry: InspectorRegistry, context: InspectorPaneContext,
                         predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
        for _ in 0..<120 {
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
               !content.isLoading, !content.history.isLoading, predicate(content) { return content }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "GitExpansionTimeout", code: 1)
    }

    @Test func repeatedCommitExpansionUsesCachedDetailsAndKnownParents() async throws {
        let directory = try await repository(commits: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ExpansionQueryRecorder()
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, executor: recorder)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal", workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        let initial = try await waitFor(registry, context: context) { $0.history.commits.count == 2 }
        let id = try #require(initial.history.commits.first?.id)
        func toggle() {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                action: .init(context: context, kind: .gitAction(.openCommit(id))))
        }
        toggle()
        _ = try await waitFor(registry, context: context) { $0.expandedCommits[id]?.metadata != nil }
        let reads = await recorder.detailReads
        #expect(reads == 2)
        #expect(await recorder.parentReads == 0)
        toggle()
        toggle()
        _ = try await waitFor(registry, context: context) { $0.expandedCommits[id]?.metadata != nil }
        #expect(await recorder.detailReads == reads)
        toggle()
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
            action: .init(context: context, kind: .gitAction(.refresh)))
        _ = try await waitFor(registry, context: context) { $0.expandedCommits.isEmpty }
        toggle()
        _ = try await waitFor(registry, context: context) { $0.expandedCommits[id]?.metadata != nil }
        #expect(await recorder.detailReads == reads + 2)
    }

    @Test func doubleClickLoadsCommitMetadataAndFilesThenCollapses() async throws {
        let directory = try await repository(commits: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal", workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        let initial = try await waitFor(registry, context: context) { $0.history.commits.count == 1 }
        let commit = try #require(initial.history.commits.first?.id)
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.openCommit(commit))))
        let expanded = try await waitFor(registry, context: context) { $0.expandedCommits[commit]?.metadata != nil }
        #expect(expanded.expandedCommits[commit]?.files.map(\.path) == ["file.swift"])
        #expect(expanded.expandedCommits[commit]?.metadata?.message == "Commit 0\n\nBody 0")
        #expect(expanded.expandedCommits[commit]?.metadata?.authorName == "Test")
        #expect(expanded.expandedCommits[commit]?.statistics == GitDiffStatistics(additions: 1, deletions: 0, binaryFiles: 0))
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.openCommit(commit))))
        _ = try await waitFor(registry, context: context) { $0.expandedCommits.isEmpty }
    }

    @Test func pagingPastTwoHundredSurvivesFailureAndDuplicateLoadRequests() async throws {
        let directory = try await repository(commits: 230)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, historyService: GitHistoryService(executor: OnePageFailure()))
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal", workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        func more() {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                                   action: .init(context: context, kind: .gitAction(.loadMoreHistory)))
        }
        let first = try await waitFor(registry, context: context) { $0.history.commits.count == 100 }
        #expect(first.history.hasMore)
        more()
        let failed = try await waitFor(registry, context: context) { $0.history.statusMessage != nil }
        #expect(failed.history.commits.count == 100 && failed.history.hasMore)
        more()
        more()
        let second = try await waitFor(registry, context: context) { $0.history.commits.count == 200 }
        #expect(second.history.hasMore && second.history.statusMessage == nil)
        more()
        let last = try await waitFor(registry, context: context) { $0.history.commits.count == 230 }
        #expect(!last.history.hasMore)
        #expect(Set(last.history.commits.map(\.id)).count == 230)
        #expect(last.history.commits.last?.subject == "Commit 0")
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.refresh)))
        let refreshed = try await waitFor(registry, context: context) { $0.history.commits.count == 230 }
        #expect(!refreshed.history.hasMore)
    }

    @Test(arguments: [true, false])
    func refreshAndPagingKeepChangesAndLoadedHistory(refreshFirst: Bool) async throws {
        let directory = try await repository(commits: 230)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("untracked".utf8).write(to: directory.appendingPathComponent("untracked.swift"))
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal", workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        let initial = try await waitFor(registry, context: context) { $0.history.commits.count == 100 }
        try #require(!initial.workingTree.unstaged.isEmpty && !initial.workingTree.branches.isEmpty)
        func send(_ action: InspectorGitAction) {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                action: .init(context: context, kind: .gitAction(action)))
        }
        send(refreshFirst ? .refresh : .loadMoreHistory)
        send(refreshFirst ? .loadMoreHistory : .refresh)
        if case .git(let loading) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) {
            #expect(loading.workingTree == initial.workingTree)
        }
        let loaded = try await waitFor(registry, context: context) { $0.history.commits.count == 200 }
        #expect(loaded.workingTree == initial.workingTree)
        #expect(loaded.history.hasMore)
        send(.refresh)
        send(.selectHistoryScope(.currentBranch))
        let filtered = try await waitFor(registry, context: context) { $0.history.snapshot?.scope == .currentBranch }
        #expect(filtered.workingTree == initial.workingTree)
        #expect(filtered.history.commits.count == 100)
    }

    @Test(arguments: GitWorkingTreeReadProbe.Component.allCases)
    func independentWorkingTreeFailuresPreserveOtherResultsAndGuardOnlyAffectedActions(
        failed: GitWorkingTreeReadProbe.Component
    ) async throws {
        let directory = try await repository(commits: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = LocalGitExecutor()
        _ = try await executor.execute(arguments: ["reset", "--hard", "HEAD"], workingDirectory: directory.path)
        try Data("staged".utf8).write(to: directory.appendingPathComponent("staged.swift"))
        try Data("unstaged".utf8).write(to: directory.appendingPathComponent("unstaged.swift"))
        _ = try await executor.execute(arguments: ["add", "--", "staged.swift"], workingDirectory: directory.path)
        let probe = GitWorkingTreeReadProbe()
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, executor: probe)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "Terminal", workingDirectory: directory.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        defer { registry.presentationDidChange(to: nil, context: context) }
        func send(_ action: InspectorGitAction) {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                action: .init(context: context, kind: .gitAction(action)))
        }
        let initial = try await waitFor(registry, context: context) { $0.history.commits.count == 1 }
        let staged = try #require(initial.workingTree.staged.first)
        let unstaged = try #require(initial.workingTree.unstaged.first)
        await probe.fail(failed)
        send(.refresh)
        let failedContent = try await waitFor(registry, context: context) {
            [$0.workingTree.stagedError, $0.workingTree.unstagedError, $0.workingTree.branchesError].compactMap { $0 }.count == 1
        }
        #expect(failedContent.workingTree.staged == initial.workingTree.staged)
        #expect(failedContent.workingTree.unstaged == initial.workingTree.unstaged)
        #expect(failedContent.workingTree.branches == initial.workingTree.branches)
        switch failed {
        case .staged:
            send(.updateCommitDraft("must not commit stale index data"))
            send(.commitStaged)
            send(.setFileStaged(staged, false))
        case .unstaged: send(.setFileStaged(unstaged, true))
        case .branches:
            send(.selectTab(.changes))
            send(.browseBranch("refs/heads/main"))
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) {
                #expect(content.activeTab == .changes)
            }
        }
        #expect(await probe.writes == 0)
        // A separate, successfully read component remains actionable.
        send(failed == .unstaged ? .setFileStaged(staged, false) : .setFileStaged(unstaged, true))
        _ = try await waitFor(registry, context: context) { $0.operation == nil }
        #expect(await probe.writes == 1)
        await probe.fail(nil)
        send(.refresh)
        let recovered = try await waitFor(registry, context: context) {
            $0.workingTree.stagedError == nil && $0.workingTree.unstagedError == nil && $0.workingTree.branchesError == nil
        }
        #expect(recovered.workingTree.staged.count == (failed == .unstaged ? 0 : 2))
    }
}

private actor ExpansionQueryRecorder: GitExecutor {
    var detailReads = 0
    var parentReads = 0
    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        if arguments.contains("--raw") || arguments.contains("--no-patch") { detailReads += 1 }
        if arguments.first == "rev-list" { parentReads += 1 }
        return try await LocalGitExecutor().execute(arguments: arguments, workingDirectory: workingDirectory,
            stdin: stdin, maxOutputBytes: maxOutputBytes)
    }
}
