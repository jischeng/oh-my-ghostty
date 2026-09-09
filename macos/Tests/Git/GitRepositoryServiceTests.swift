import Foundation
import Testing
@testable import Ghostty

struct GitRepositoryServiceTests {
    private func createTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-test-\(UUID().uuidString)")
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
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TestCommand", code: Int(process.terminationStatus))
        }
    }

    @Test func refusesAmbiguousRepositoryRootsInsteadOfResolvingAnotherPath() async {
        let status = await GitRepositoryService().resolveStatus(workingDirectory: "/tmp/repo\n/other")
        guard case .error = status else { Issue.record("Line-delimited identity must reject roots containing line breaks"); return }
    }

    @Test func detectsNonRepositoryDirectory() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = GitRepositoryService()
        let status = await service.resolveStatus(workingDirectory: dir.path)

        guard case .notRepository(let path) = status else {
            Issue.record("Expected .notRepository, got \(status)")
            return
        }
        #expect(path == dir.path)
    }

    @Test func detectsUnbornEmptyRepository() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)

        let service = GitRepositoryService()
        let status = await service.resolveStatus(workingDirectory: dir.path)

        guard case .unborn(let repo, let branch) = status else {
            Issue.record("Expected .unborn, got \(status)")
            return
        }
        #expect(branch == "main")
        #expect(repo.worktreePath.hasSuffix(dir.lastPathComponent))
    }

    @Test func detectsReadyRepositoryWithCommit() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "first commit"], in: dir.path)

        let service = GitRepositoryService()
        let status = await service.resolveStatus(workingDirectory: dir.path)

        guard case .ready(let repo, let branch, let headCommit) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        #expect(branch == "main")
        #expect(headCommit != nil)
        #expect(repo.worktreePath.hasSuffix(dir.lastPathComponent))
    }

    @Test func detectsDetachedHeadState() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "first commit"], in: dir.path)
        try runCommand(["git", "checkout", "--detach", "HEAD"], in: dir.path)

        let service = GitRepositoryService()
        let status = await service.resolveStatus(workingDirectory: dir.path)

        guard case .detached(let repo, let commitID) = status else {
            Issue.record("Expected .detached, got \(status)")
            return
        }
        #expect(!commitID.rawValue.isEmpty)
        #expect(repo.worktreePath.hasSuffix(dir.lastPathComponent))
    }

    @Test func resolvesSubdirectoryToWorktreeRoot() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "initial"], in: dir.path)

        let subDir = dir.appendingPathComponent("subdir/nested")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let service = GitRepositoryService()
        let status = await service.resolveStatus(workingDirectory: subDir.path)

        guard case .ready(let repo, let branch, _) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        #expect(branch == "main")
        #expect(repo.worktreePath == dir.standardized.path || repo.worktreePath.hasSuffix(dir.lastPathComponent))
        #expect(repo.gitDirPath == repo.worktreePath + "/.git")
        #expect(repo.commonGitDirPath == repo.gitDirPath)
    }

    @Test func detectsWorktreeIdentityCorrectly() async throws {
        let dir = createTempDirectory()
        let wtDir = createTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: wtDir)
        }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "initial"], in: dir.path)
        try runCommand(["git", "worktree", "add", wtDir.path, "-b", "feature-worktree"], in: dir.path)

        let service = GitRepositoryService()
        let status = await service.resolveStatus(workingDirectory: wtDir.path)

        guard case .ready(let repo, let branch, _) = status else {
            Issue.record("Expected .ready, got \(status)")
            return
        }
        #expect(branch == "feature-worktree")
        #expect(repo.worktreePath.hasSuffix(wtDir.lastPathComponent))
        #expect(repo.commonGitDirPath != repo.gitDirPath)
    }

    @Test func identifiesSSHSessionWithoutRunningLocalGit() async throws {
        let service = GitRepositoryService(executor: RemoteRepositoryProbe())
        var session = PaneSessionContext(workingDirectory: "/local/path", terminalTitle: "Terminal")
        session.observeForegroundSSH(
            alias: "prod-server",
            transferTarget: "user@host",
            processGroupID: 1234,
            currentWorkingDirectory: "/local/path",
            currentTerminalTitle: "Terminal",
            remoteWorkingDirectory: "/remote/repo",
            replay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false, args: ["user@host"])
        )

        let status = await service.resolveStatus(
            workingDirectory: "/remote/repo",
            session: session
        )

        guard case .ready(let repository, let branch, _) = status else {
            Issue.record("Expected remote repository, got \(status)")
            return
        }
        #expect(branch == "main")
        #expect(repository.worktreePath == "/remote/repo")
        #expect(repository.sshConnection?.destination == "user@host")

    }
}

private struct RemoteRepositoryProbe: GitExecutor {
    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        #expect(workingDirectory == "/remote/repo")
        let output: String
        if arguments.contains("--show-toplevel") { output = "true\n/remote/repo\n/remote/repo/.git\n/remote/repo/.git\n\n" } else if arguments.first == "symbolic-ref" { output = "main\n" } else { output = String(repeating: "a", count: 40) + "\n" }
        return GitExecutionResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
    }
}
