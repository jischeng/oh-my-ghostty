import Foundation
import Testing
@testable import Ghostty

struct GitDiffServiceTests {
    @Test func editorSnapshotsSeparateHeadIndexAndWorkingTree() async throws {
        let dir = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("example.swift")
        try write("let value = 1\n", to: url)
        try run(["git", "add", "."], in: dir.path)
        let root = try commit(in: dir, message: "root")
        let repository = try await repositoryIdentity(for: dir)
        let service = GitDiffService()
        let rootFiles = try await service.listFiles(for: repository, target: .commit(GitCommitID(root)))
        let rootSource = try await service.sourceVersions(for: rootFiles.files[0], repository: repository,
                                                          target: .commit(GitCommitID(root)))
        #expect(rootSource.before.isEmpty)
        #expect(rootSource.after == "let value = 1\n")
        try write("let value = 2\n", to: url)
        try run(["git", "add", "."], in: dir.path)
        try write("let value = 3\n", to: url)
        let staged = try await service.listFiles(for: repository, target: .staged)
        let unstaged = try await service.listFiles(for: repository, target: .unstaged)
        let indexSource = try await service.sourceVersions(for: staged.files[0], repository: repository, target: .staged)
        let worktreeSource = try await service.sourceVersions(for: unstaged.files[0], repository: repository, target: .unstaged)
        #expect(indexSource.before == "let value = 1\n")
        #expect(indexSource.after == "let value = 2\n")
        #expect(worktreeSource.before == "let value = 2\n")
        #expect(worktreeSource.after == "let value = 3\n")
    }

    @Test func branchesReportCurrentAndUpstreamDivergence() async throws {
        let dir = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("base\n", to: dir.appendingPathComponent("file"))
        try run(["git", "add", "."], in: dir.path)
        _ = try commit(in: dir, message: "base")
        try run(["git", "remote", "add", "origin", dir.path], in: dir.path)
        try run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], in: dir.path)
        try run(["git", "branch", "--set-upstream-to=origin/main"], in: dir.path)
        try write("ahead\n", to: dir.appendingPathComponent("file"))
        try run(["git", "add", "."], in: dir.path)
        _ = try commit(in: dir, message: "ahead")
        let repository = try await repositoryIdentity(for: dir)
        let branches = try await GitRepositoryService().branches(for: repository)
        let current = try #require(branches.first(where: { $0.isCurrent }))
        #expect(current.name == "main")
        #expect(current.upstream == "origin/main")
        #expect(current.tracking == "[ahead 1]")
        #expect(branches.contains { $0.name == "origin/main" && $0.isRemote && !$0.isCurrent })
        try run(["git", "checkout", "--detach"], in: dir.path)
        let detached = try await GitRepositoryService().branches(for: repository)
        #expect(!detached.contains(where: { $0.isCurrent }))
    }

    @Test func diffLineMapIgnoresHeadersAndNoNewlineMarkers() {
        let patch = """
        diff --git a/file b/file
        --- a/file
        +++ b/file
        @@ -2,2 +2,3 @@
         same
        -old
        +new
        +extra
        \\ No newline at end of file
        @@ -10 +11 @@
        -last
        +changed
        """
        let lines = GitDiffLineMap(patch)
        #expect(lines.before == [2: false, 9: false])
        #expect(lines.after == [2: true, 3: true, 10: true])
    }

    @Test func listsRootCommitAndPreservesUnicodeSpacePath() async throws {
        let dir = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "中文 file.txt"
        try write("hello\n", to: dir.appendingPathComponent(path))
        try run(["git", "add", "--", path], in: dir.path)
        let commit = try commit(in: dir, message: "root")
        let repository = try await repositoryIdentity(for: dir)
        let service = GitDiffService()

        let list = try await service.listFiles(
            for: repository,
            target: .commit(GitCommitID(commit))
        )
        #expect(list.baseDescription == "empty tree")
        #expect(list.files.map(\.path) == [path])
        let metadata = try await service.loadCommitMetadata(
            for: GitCommitID(commit),
            repository: repository
        )
        #expect(metadata.commitID.rawValue == commit)
        #expect(metadata.authorName == "Git Diff Test")
        #expect(metadata.authorDescription == "Git Diff Test <git-diff@example.com>")
        #expect(metadata.authoredAt.contains("T"))
        #expect(metadata.parents.isEmpty)
        #expect(metadata.message == "root")
        let document = try await service.loadDiff(
            for: list.files[0],
            repository: repository,
            target: .commit(GitCommitID(commit))
        )
        #expect(document.text.contains("+hello"))
        #expect(!document.isBinary)
    }

    @Test func separatesStagedUnstagedUntrackedAndBinaryChanges() async throws {
        let dir = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracked = "tracked file.txt"
        try write("base\n", to: dir.appendingPathComponent(tracked))
        try run(["git", "add", "--", tracked], in: dir.path)
        _ = try commit(in: dir, message: "base")

        try write("staged\n", to: dir.appendingPathComponent(tracked))
        try run(["git", "add", "--", tracked], in: dir.path)
        try write("staged and unstaged\n", to: dir.appendingPathComponent(tracked))
        let untracked = "un tracked 中文.txt"
        try write("new\n", to: dir.appendingPathComponent(untracked))
        let binary = "image.bin"
        try Data([0, 1, 2, 255, 0, 8]).write(to: dir.appendingPathComponent(binary))

        let repository = try await repositoryIdentity(for: dir)
        let service = GitDiffService()
        let staged = try await service.listFiles(for: repository, target: .staged)
        #expect(staged.files.map(\.path) == [tracked])
        let limitedDocument = try await GitDiffService(diffByteLimit: 64).loadDiff(
            for: staged.files[0],
            repository: repository,
            target: .staged
        )
        #expect(limitedDocument.isTruncated)
        #expect(limitedDocument.text.contains("display limit"))

        let unstaged = try await service.listFiles(for: repository, target: .unstaged)
        #expect(unstaged.files.map(\.path).contains(tracked))
        #expect(unstaged.files.map(\.path).contains(untracked))
        #expect(unstaged.files.map(\.path).contains(binary))
        let binaryFile = try #require(unstaged.files.first(where: { $0.path == binary }))
        let binaryDocument = try await service.loadDiff(
            for: binaryFile,
            repository: repository,
            target: .unstaged
        )
        #expect(binaryDocument.isBinary)
    }

    @Test func detectsRenameInMergeCommitRelativeToFirstParent() async throws {
        let dir = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("base\n", to: dir.appendingPathComponent("old name.txt"))
        try run(["git", "add", "."], in: dir.path)
        _ = try commit(in: dir, message: "base")
        try run(["git", "checkout", "-b", "rename"], in: dir.path)
        try run(["git", "mv", "old name.txt", "new name.txt"], in: dir.path)
        _ = try commit(in: dir, message: "rename")
        try run(["git", "checkout", "main"], in: dir.path)
        try write("main\n", to: dir.appendingPathComponent("main.txt"))
        try run(["git", "add", "."], in: dir.path)
        _ = try commit(in: dir, message: "main change")
        try run(["git", "merge", "--no-ff", "rename", "-m", "merge"], in: dir.path)
        let mergeCommit = try output(["git", "rev-parse", "HEAD"], in: dir.path)

        let repository = try await repositoryIdentity(for: dir)
        let list = try await GitDiffService().listFiles(
            for: repository,
            target: .commit(GitCommitID(mergeCommit))
        )
        let metadata = try await GitDiffService().loadCommitMetadata(
            for: GitCommitID(mergeCommit),
            repository: repository
        )
        #expect(metadata.parents.count == 2)
        #expect(metadata.message == "merge")
        let rename = try #require(list.files.first(where: { $0.kind == .renamed }))
        #expect(rename.oldPath == "old name.txt")
        #expect(rename.path == "new name.txt")
    }

    private func makeRepository() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-diff-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try run(["git", "init", "-b", "main"], in: url.path)
        return url
    }

    private func repositoryIdentity(for url: URL) async throws -> GitRepositoryIdentity {
        let status = await GitRepositoryService().resolveStatus(workingDirectory: url.path)
        guard let repository = status.repository else {
            throw NSError(domain: "GitDiffTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "No repository identity: \(status)"])
        }
        return repository
    }

    private func commit(in directory: URL, message: String) throws -> String {
        try run(["git", "commit", "-m", message], in: directory.path)
        return try output(["git", "rev-parse", "HEAD"], in: directory.path)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)?.write(to: url)
    }

    private func run(_ arguments: [String], in directory: String) throws {
        let process = try makeProcess(arguments, directory: directory)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitDiffTests", code: Int(process.terminationStatus))
        }
    }

    private func output(_ arguments: [String], in directory: String) throws -> String {
        let process = try makeProcess(arguments, directory: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitDiffTests", code: Int(process.terminationStatus))
        }
        return (String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeProcess(_ arguments: [String], directory: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_AUTHOR_NAME": "Git Diff Test",
            "GIT_AUTHOR_EMAIL": "git-diff@example.com",
            "GIT_COMMITTER_NAME": "Git Diff Test",
            "GIT_COMMITTER_EMAIL": "git-diff@example.com",
        ]
        return process
    }
}
