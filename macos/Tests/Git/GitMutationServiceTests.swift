import Foundation
import Testing
@testable import Ghostty

struct GitMutationServiceTests {
    private func repository() async throws -> GitRepositoryIdentity {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repo = GitRepositoryIdentity(worktreePath: directory.path, gitDirPath: directory.path + "/.git",
                                         commonGitDirPath: directory.path + "/.git")
        _ = try await git(["init", "-b", "main"], repo)
        _ = try await git(["config", "user.name", "Git Mutation Test"], repo)
        _ = try await git(["config", "user.email", "mutation@example.com"], repo)
        _ = try await git(["config", "commit.gpgSign", "false"], repo)
        _ = try await git(["config", "core.hooksPath", repo.gitDirPath + "/hooks"], repo)
        return repo
    }

    private func git(_ args: [String], _ repo: GitRepositoryIdentity) async throws -> String {
        let result = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repo.worktreePath)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ text: String, _ name: String, _ repo: GitRepositoryIdentity) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: repo.worktreePath).appendingPathComponent(name))
    }

    @Test func checkedFilesCommitIndexWithoutUnselectedOrLaterWorkingTreeEdits() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("selected version", "中文 selected.txt", repo)
        try write("leave me", "unselected.txt", repo)
        try await service.perform(.stage(["中文 selected.txt", "unselected.txt"]), in: repo)
        try await service.perform(.unstage(["unselected.txt"]), in: repo)
        try write("later unstaged edit", "中文 selected.txt", repo)
        try await service.perform(.commit("only the checked index snapshot\n\nDetails"), in: repo)
        #expect(try await git(["show", "HEAD:中文 selected.txt"], repo) == "selected version")
        #expect(try await git(["ls-tree", "--name-only", "HEAD"], repo) != "unselected.txt")
        let unstaged = try await GitDiffService().listFiles(for: repo, target: .unstaged)
        #expect(Set(unstaged.files.map(\.path)) == ["中文 selected.txt", "unselected.txt"])
        #expect(try await git(["log", "-1", "--format=%B"], repo) == "only the checked index snapshot\n\nDetails")
    }

    @Test func unstageBeforeAndAfterFirstCommitPreservesFiles() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("first", "file.txt", repo)
        try await service.perform(.stage(["file.txt"]), in: repo)
        try write("edited after staging", "file.txt", repo)
        try await service.perform(.unstage(["file.txt"]), in: repo)
        #expect(FileManager.default.fileExists(atPath: repo.worktreePath + "/file.txt"))
        try await service.perform(.stage(["file.txt"]), in: repo)
        try await service.perform(.commit("first"), in: repo)
        try write("second", "file.txt", repo)
        try await service.perform(.stage(["file.txt"]), in: repo)
        try await service.perform(.unstage(["file.txt"]), in: repo)
        #expect(try await git(["diff", "--cached", "--name-only"], repo).isEmpty)
        #expect(try String(contentsOfFile: repo.worktreePath + "/file.txt", encoding: .utf8) == "second")
    }

    @Test func branchCreateSwitchPushAndUpstreamUseSelectedBranch() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("base", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        let remotePath = repo.worktreePath + "/remote.git"
        _ = try await git(["init", "--bare", remotePath], repo)
        _ = try await git(["remote", "add", "origin", remotePath], repo)
        try await service.perform(.create(name: "feature/one", start: "refs/heads/main"), in: repo)
        #expect(try await git(["branch", "--show-current"], repo) == "feature/one")
        try write("feature", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("feature"), in: repo)
        let feature = try await git(["rev-parse", "HEAD"], repo)
        try await service.perform(.checkout("main"), in: repo)
        try await service.perform(.push(branch: "feature/one", remote: "origin", destination: "review/one"), in: repo)
        #expect(try await git(["rev-parse", "refs/remotes/origin/review/one"], repo) == feature)
        #expect(try await git(["branch", "--show-current"], repo) == "main")
        try await service.perform(.setUpstream(branch: "feature/one", upstream: "refs/remotes/origin/review/one"), in: repo)
        let branches = try await GitRepositoryService().branches(for: repo)
        #expect(branches.first(where: { $0.name == "feature/one" })?.upstream == "origin/review/one")
        try await service.perform(.create(name: "tracking", start: "refs/remotes/origin/review/one"), in: repo)
        #expect(try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], repo) == "origin/review/one")
        try write("advanced", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("advanced"), in: repo)
        try await service.perform(.push(branch: "tracking", remote: "origin", destination: "review/one"), in: repo)
        let advanced = try await git(["rev-parse", "refs/remotes/origin/review/one"], repo)
        await #expect(throws: (any Error).self) {
            try await service.perform(.push(branch: "feature/one", remote: "origin", destination: "review/one"), in: repo)
        }
        #expect(try await git(["rev-parse", "refs/remotes/origin/review/one"], repo) == advanced)
    }

    @Test func failedCheckoutAndCommitKeepChangesAndDoNotForce() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("base", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        try await service.perform(.create(name: "feature", start: "refs/heads/main"), in: repo)
        try write("feature", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("feature"), in: repo)
        try await service.perform(.checkout("main"), in: repo)
        try write("dirty", "file", repo)
        await #expect(throws: (any Error).self) { try await service.perform(.checkout("feature"), in: repo) }
        #expect(try await git(["branch", "--show-current"], repo) == "main")
        #expect(try String(contentsOfFile: repo.worktreePath + "/file", encoding: .utf8) == "dirty")
        try await service.perform(.stage(["file"]), in: repo)
        let hook = repo.gitDirPath + "/hooks/pre-commit"
        try Data("#!/bin/sh\necho test-hook-rejected >&2\nexit 1\n".utf8).write(to: URL(fileURLWithPath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        await #expect(throws: (any Error).self) { try await service.perform(.commit("must fail"), in: repo) }
        #expect(try await git(["diff", "--cached", "--name-only"], repo) == "file")
        #expect(try await git(["log", "-1", "--format=%s"], repo) == "base")
    }

    @Test func rejectsPathTraversalAndOptionLikeBranchNames() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        await #expect(throws: (any Error).self) { try await service.perform(.stage(["../outside"]), in: repo) }
        await #expect(throws: (any Error).self) { try await service.perform(.checkout("--discard-changes"), in: repo) }
    }
}
