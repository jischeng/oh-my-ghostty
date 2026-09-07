import Foundation
import Testing
@testable import Ghostty

@MainActor
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
}
