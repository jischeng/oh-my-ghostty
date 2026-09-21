import Foundation
import Testing
@testable import Ghostty

struct GitIntegrationTests {
    private func fixture() async throws -> (URL, GitIntegrationService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git", commonGitDirPath: root.path + "/.git")
        let service = GitIntegrationService(repository: repo)
        _ = try await service.run(["init", "-b", "main"])
        _ = try await service.run(["config", "user.name", "Test"])
        _ = try await service.run(["config", "user.email", "test@example.com"])
        _ = try await service.run(["config", "commit.gpgsign", "false"])
        _ = try await service.run(["commit", "--allow-empty", "-m", "base"])
        _ = try await service.run(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature.txt"))
        _ = try await service.run(["add", "feature.txt"])
        _ = try await service.run(["commit", "-m", "feature change"])
        _ = try await service.run(["switch", "main"])
        _ = try await service.run(["commit", "--allow-empty", "-m", "main change"])
        return (root, service)
    }

    @Test func largeIntegrationContextFallsBackWithoutChangingRepository() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.run(["switch", "feature"])
        let large = String(repeating: "large change with enough bytes to exceed the patch budget\n", count: 8_000)
        try Data(large.utf8).write(to: root.appendingPathComponent("large.txt"))
        _ = try await service.run(["add", "large.txt"])
        _ = try await service.run(["commit", "-m", "large change"])
        _ = try await service.run(["switch", "main"])
        let source = try await service.resolve("refs/heads/feature")
        for kind in [GitIntegrationKind.merge, .review, .cherryPick] {
            let plan = try await service.prepare(kind: kind,
                source: kind == .cherryPick ? source : "refs/heads/feature",
                target: "refs/heads/main", message: "", mainline: nil)
            let context = try await service.context(plan)
            #expect(context.contains("full patch exceeded"))
            #expect(context.contains("large.txt"))
            #expect(context.utf8.count < 33_000)
        }
        #expect(try await service.run(["symbolic-ref", "HEAD"]) == "refs/heads/main")
        #expect(try await service.run(["status", "--porcelain"]).isEmpty)
    }

    @Test func smallContextKeepsPatchAndGitErrorsPropagate() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await service.prepare(kind: .merge, source: "refs/heads/feature",
                                             target: "refs/heads/main", message: "", mainline: nil)
        let context = try await service.context(plan)
        #expect(context.contains("+feature"))
        #expect(!context.contains("full patch exceeded"))
        let invalid = GitIntegrationPlan(kind: .merge, source: plan.source, target: plan.target,
            sourceSHA: String(repeating: "0", count: 40), targetSHA: plan.targetSHA,
            originalBranch: plan.originalBranch, message: "")
        await #expect(throws: (any Error).self) { try await service.context(invalid) }
    }

    @Test func mergeUsesChosenDirectionAndMessage() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await service.prepare(kind: .merge, source: "refs/heads/feature", target: "refs/heads/main", message: "Merge reviewed feature", mainline: nil)
        try await service.execute(plan)
        #expect(try await service.run(["log", "-1", "--format=%s"]) == "Merge reviewed feature")
        #expect(try await service.run(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count == 3)
        #expect(try await service.run(["symbolic-ref", "HEAD"]) == "refs/heads/main")
    }

    @Test func rebasePreservesMessageAndRebasesSelectedTarget() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = try await service.resolve("refs/heads/main")
        let plan = try await service.prepare(kind: .rebase, source: "refs/heads/main", target: "refs/heads/feature", message: "", mainline: nil)
        try await service.execute(plan)
        #expect(try await service.run(["symbolic-ref", "HEAD"]) == "refs/heads/feature")
        #expect(try await service.run(["log", "-1", "--format=%s"]) == "feature change")
        #expect(try await service.run(["rev-parse", "HEAD^"]) == main)
    }

    @Test func cherryPickTargetsSelectedBranchAndUsesMessage() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await service.resolve("refs/heads/feature")
        let plan = try await service.prepare(kind: .cherryPick, source: source, target: "refs/heads/main", message: "Apply selected fix", mainline: nil)
        try await service.execute(plan)
        #expect(try await service.run(["log", "-1", "--format=%s"]) == "Apply selected fix")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("feature.txt").path))
    }

    @Test func dirtyAndStalePlansAreRejectedBeforeSwitch() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await service.prepare(kind: .merge, source: "refs/heads/main", target: "refs/heads/feature", message: "merge", mainline: nil)
        try Data("local".utf8).write(to: root.appendingPathComponent("untracked"))
        await #expect(throws: (any Error).self) { try await service.execute(plan) }
        #expect(try await service.run(["symbolic-ref", "HEAD"]) == "refs/heads/main")
        try FileManager.default.removeItem(at: root.appendingPathComponent("untracked"))
        _ = try await service.run(["commit", "--allow-empty", "-m", "moved source"])
        await #expect(throws: (any Error).self) { try await service.execute(plan) }
        #expect(try await service.run(["symbolic-ref", "HEAD"]) == "refs/heads/main")
    }

    @Test func conflictRemainsResolvableAndNoImplicitCommit() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("main conflicting content\n".utf8).write(to: root.appendingPathComponent("feature.txt"))
        _ = try await service.run(["add", "feature.txt"])
        _ = try await service.run(["commit", "-m", "conflict"])
        let before = try await service.resolve("refs/heads/main")
        let plan = try await service.prepare(kind: .merge, source: "refs/heads/feature", target: "refs/heads/main", message: "merge", mainline: nil)
        await #expect(throws: (any Error).self) { try await service.execute(plan) }
        #expect(try await service.resolve("refs/heads/main") == before)
        #expect(!(try await service.run(["ls-files", "--unmerged"])).isEmpty)
        _ = try await service.run(["merge", "--abort"])
        #expect(try await service.run(["status", "--porcelain"]).isEmpty)
    }

    @Test func tagSuggestionBumpsMinorAndResetsPatch() {
        #expect(GitTagService.suggestNextMinor(tags: ["v1.6.124", "v1.5.0"]) == "v1.7.0")
        #expect(GitTagService.suggestNextMinor(tags: ["v2.0.1", "v1.9.9"]) == "v2.1.0")
        #expect(GitTagService.suggestNextMinor(tags: ["1.6"]) == "1.7.0")
        #expect(GitTagService.suggestNextMinor(tags: ["v1.6.124-rc1"]) == "v1.7.0")
        #expect(GitTagService.suggestNextMinor(tags: ["feature-x", "release"]) == nil)
        #expect(GitTagService.suggestNextMinor(tags: []) == nil)
        #expect((try? GitTagService.validate("v1.7.0")) != nil)
        #expect((try? GitTagService.validate("bad name")) == nil)
        #expect((try? GitTagService.validate("-v1")) == nil)
        #expect((try? GitTagService.validate("a..b")) == nil)
        #expect((try? GitTagService.validate("a@{1}")) == nil)
        #expect((try? GitTagService.validate(" a")) == nil)
    }

    @Test func createTagViaMutationUsesAnnotatedTagAndRejectsDuplicate() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git", commonGitDirPath: root.path + "/.git")
        let head = GitCommitID(try await service.resolve("HEAD"))
        try await GitMutationService().perform(.createTag(name: "v1.0.0", message: "release", commit: head), in: repo)
        #expect(try await service.run(["tag", "--list", "v1.0.0"]) == "v1.0.0")
        #expect(try await service.run(["for-each-ref", "--format=%(objecttype)", "refs/tags/v1.0.0"]) == "tag")
        await #expect(throws: (any Error).self) {
            try await GitMutationService().perform(.createTag(name: "v1.0.0", message: "x", commit: head), in: repo)
        }
    }

    @Test func reviewRejectsUnpushedBranchesWithoutInvokingCLI() async throws {
        let (root, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await service.prepare(kind: .review, source: "refs/heads/feature", target: "refs/heads/main", message: "Review feature", mainline: nil)
        await #expect(throws: (any Error).self) { try await service.execute(plan) }
        #expect(try await service.run(["symbolic-ref", "HEAD"]) == "refs/heads/main")
    }

    @Test func forgeURLsHandleSSHNestedGroupsAndDeletedFiles() throws {
        #expect(GitForge(origin: nil) == nil)
        #expect(GitForge(origin: "/local/repo") == nil)
        let github = try #require(GitForge(origin: "git@github.com:owner/repo.git"))
        #expect(github.commit("abc1234")?.absoluteString == "https://github.com/owner/repo/commit/abc1234")
        let gitlab = try #require(GitForge(origin: "ssh://git@code.example.com:2222/group/sub/repo.git"))
        #expect(gitlab.commit("abc1234")?.absoluteString == "https://code.example.com/group/sub/repo/-/commit/abc1234")
        let file = GitDiffFile(path: "folder/space #.txt", status: "D")
        #expect(gitlab.commit("abc1234", file: file, parent: "def1234")?.absoluteString
            == "https://code.example.com/group/sub/repo/-/blob/def1234/folder/space%20%23.txt")
        #expect(gitlab.commit("bad revision") == nil)
        #expect(gitlab.commit("abc1234", file: file) == nil)
        let credentialURL = try #require(GitForge(origin: "https://user:secret@github.com/owner/repo.git"))
        #expect(!credentialURL.base.absoluteString.contains("secret"))
    }
}
