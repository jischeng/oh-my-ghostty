import Foundation
import Testing
@testable import Ghostty

@MainActor
struct GitEditorDiffModelTests {
    @Test func adjacentFileNavigationStopsAtTheListBoundaries() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("second\n".utf8).write(to: root.appendingPathComponent("b.txt"))
        let model = makeModel(root: root)
        defer { model.cancel() }

        await model.reload().value
        #expect(model.selected?.path == "a.txt")
        #expect(model.selectAdjacentFile(offset: -1) == nil)
        await model.selectAdjacentFile(offset: 1)?.value
        #expect(model.selected?.path == "b.txt")
        #expect(model.selectAdjacentFile(offset: 1) == nil)
    }

    @Test func refreshResolvesUntrackedAndIndexChangesBeforeLoadingSources() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("new.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let model = makeModel(root: root, file: .init(path: "new.swift", status: "A", isUntracked: true))
        defer { model.cancel() }

        await model.reload().value
        #expect(model.selected?.isUntracked == true)
        #expect(model.content?.before == "")
        #expect(model.content?.after == "let value = 1\n")

        try await git(["add", "--", "new.swift"], in: root)
        await model.reload().value
        #expect(model.error == nil)
        #expect(model.files.isEmpty && model.selected == nil && model.content == nil)

        // The same path now has a different status and ID, and must use its
        // index contents instead of the old untracked-file /dev/null base.
        try Data("let value = 2\n".utf8).write(to: file)
        try Data("other\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        await model.reload().value
        #expect(model.files.count == 2)
        #expect(model.selected?.path == "new.swift")
        #expect(model.selected?.kind == .modified && model.selected?.isUntracked == false)
        #expect(model.content?.before == "let value = 1\n")
        #expect(model.content?.after == "let value = 2\n")
        #expect(model.content?.presentation?.isConsistent == true)
    }

    @Test func refreshRetainsSelectedPathAndRecoversFromFileListFailure() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("before\n".utf8).write(to: root.appendingPathComponent("z.txt"))
        let model = makeModel(root: root)
        defer { model.cancel() }
        await model.reload().value
        let selected = try #require(model.files.first { $0.path == "z.txt" })
        await model.select(selected)?.value
        try await git(["add", "--", "z.txt"], in: root)
        try Data("after\n".utf8).write(to: root.appendingPathComponent("z.txt"))

        let gitDirectory = root.appendingPathComponent(".git")
        let hiddenDirectory = root.appendingPathComponent(".git-hidden")
        try FileManager.default.moveItem(at: gitDirectory, to: hiddenDirectory)
        await model.reload().value
        #expect(model.error != nil && model.files.isEmpty && model.content == nil)
        try FileManager.default.moveItem(at: hiddenDirectory, to: gitDirectory)
        await model.reload().value
        #expect(model.error == nil)
        #expect(model.selected?.path == "z.txt" && model.selected?.kind == .modified)
        #expect(model.content?.before == "before\n" && model.content?.after == "after\n")
    }

    @Test func selectingAnotherFileDiscardsACancelledLoadsLateError() async throws {
        let executor = DelayedDiffExecutor()
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let model = GitEditorDiffModel(request: .init(repository: repository, target: .unstaged, file: nil),
                                       service: GitDiffService(executor: executor))
        defer { model.cancel(); Task { await executor.finishFirst() } }
        let original = model.reload()
        for _ in 0..<100 {
            if await executor.firstStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await executor.firstStarted)
        let next = try #require(model.files.first { $0.path == "b.txt" })
        await model.select(next)?.value
        await executor.finishFirst()
        await original.value
        #expect(!model.isLoading && model.error == nil)
        #expect(model.selected?.path == "b.txt")
        #expect(model.content?.after == "second\n")
        #expect(model.content?.sourceError == nil)
    }

    @Test func deletedCRLFFileUsesSourceDiffForWorkingTreeIndexAndCommit() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["config", "core.autocrlf", "false"], in: root)
        try await git(["config", "user.name", "Diff Test"], in: root)
        try await git(["config", "user.email", "diff@example.com"], in: root)
        let source = "first\r\nsecond\r\nthird\r\n"
        let file = root.appendingPathComponent("deleted.txt")
        try Data(source.utf8).write(to: file)
        try await git(["add", "."], in: root)
        try await git(["commit", "-m", "initial"], in: root)
        try FileManager.default.removeItem(at: file)
        let repository = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git",
                                               commonGitDirPath: root.path + "/.git")
        for target: GitDiffTarget in [.unstaged, .staged, .commit(GitCommitID("HEAD"))] {
            if target == .staged { try await git(["add", "-u"], in: root) }
            if case .commit = target { try await git(["commit", "-m", "delete"], in: root) }
            let resolvedTarget: GitDiffTarget
            if case .commit = target {
                let head = try await LocalGitExecutor().execute(arguments: ["rev-parse", "HEAD"], workingDirectory: root.path)
                resolvedTarget = .commit(GitCommitID(head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else { resolvedTarget = target }
            let model = GitEditorDiffModel(request: .init(repository: repository, target: resolvedTarget, file: nil))
            await model.reload().value
            #expect(model.error == nil)
            #expect(model.content?.sourceError == nil)
            #expect(model.content?.before == source && model.content?.after == "")
            #expect(model.content?.presentation?.isConsistent == true)
            #expect(model.content?.presentation?.beforeHighlights.count == 3)
            model.cancel()
        }
    }

    @Test func commitDiffReusesItsResolvedParentWhenSwitchingFiles() async throws {
        let root = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["config", "user.name", "Diff Test"], in: root)
        try await git(["config", "user.email", "diff@example.com"], in: root)
        for version in ["before", "after"] {
            for name in ["a.txt", "b.txt"] {
                try Data("\(name) \(version)\n".utf8).write(to: root.appendingPathComponent(name))
            }
            try await git(["add", "."], in: root)
            try await git(["commit", "-m", version], in: root)
        }
        let head = try await LocalGitExecutor().execute(arguments: ["rev-parse", "HEAD"], workingDirectory: root.path)
        let repository = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git",
                                               commonGitDirPath: root.path + "/.git")
        let executor = CountingDiffExecutor()
        let model = GitEditorDiffModel(request: .init(repository: repository,
            target: .commit(GitCommitID(head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))), file: nil),
            service: GitDiffService(executor: executor))
        defer { model.cancel() }
        await model.reload().value
        #expect(model.error == nil && model.content?.sourceError == nil)
        #expect(await executor.commands.count == 5)
        let next = try #require(model.files.last)
        await model.select(next)?.value
        #expect(model.content?.presentation?.isConsistent == true)
        #expect(await executor.commands.count == 8)
        #expect(await executor.commands.filter { $0.first == "rev-list" }.count == 1)
    }

    private func makeModel(root: URL, file: GitDiffFile? = nil) -> GitEditorDiffModel {
        let repository = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git",
                                               commonGitDirPath: root.path + "/.git")
        return GitEditorDiffModel(request: .init(repository: repository, target: .unstaged, file: file))
    }

    private func makeRepository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-diff-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try await git(["init", "--quiet"], in: root) } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return root
    }

    private func git(_ arguments: [String], in root: URL) async throws {
        let result = try await LocalGitExecutor().execute(arguments: arguments, workingDirectory: root.path)
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
    }
}

private actor DelayedDiffExecutor: GitExecutor {
    private var first: CheckedContinuation<GitExecutionResult, Error>?
    var firstStarted: Bool { first != nil }

    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        if arguments.contains("--name-status") { return result("") }
        if arguments.contains("ls-files") { return result("a.txt\0b.txt\0") }
        if arguments.last?.hasSuffix("/a.txt") == true {
            return try await withCheckedThrowingContinuation { first = $0 }
        }
        return result("@@ -0,0 +1 @@\n+second\n")
    }

    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data { Data("second\n".utf8) }

    func finishFirst() {
        first?.resume(throwing: GitExecutionError.executionFailed("Late failure from the cancelled request"))
        first = nil
    }

    private func result(_ text: String) -> GitExecutionResult {
        GitExecutionResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
    }
}

private actor CountingDiffExecutor: GitExecutor {
    var commands: [[String]] = []

    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        commands.append(arguments)
        return try await LocalGitExecutor().execute(arguments: arguments, workingDirectory: workingDirectory,
                                                     stdin: stdin, maxOutputBytes: maxOutputBytes)
    }
}
