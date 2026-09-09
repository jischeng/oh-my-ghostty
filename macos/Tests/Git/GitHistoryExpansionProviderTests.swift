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
}
