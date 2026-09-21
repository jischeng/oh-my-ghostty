import Foundation

enum GitIntegrationKind: String, CaseIterable, Sendable {
    case merge, rebase, cherryPick, review
    var title: String {
        switch self {
        case .merge: GitL10n.text("Merge…")
        case .rebase: GitL10n.text("Rebase…")
        case .cherryPick: GitL10n.text("Cherry-pick…")
        case .review: GitL10n.text("Merge into… (PR/MR)")
        }
    }
}

struct GitIntegrationPlan: Equatable, Sendable {
    let kind: GitIntegrationKind
    let source: String
    let target: String
    let sourceSHA: String
    let targetSHA: String
    let originalBranch: String
    var message: String
    var mainline: Int?
}

struct GitIntegrationService: Sendable {
    let repository: GitRepositoryIdentity
    var executor: any GitExecutor { repository.executor }

    func run(_ arguments: [String], input: Data? = nil, limit: Int = 200_000) async throws -> String {
        let result = try await executor.execute(arguments: arguments, workingDirectory: repository.worktreePath,
                                               stdin: input, maxOutputBytes: limit)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolve(_ ref: String) async throws -> String {
        guard ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/") ||
                (ref.count >= 7 && ref.allSatisfy(\.isHexDigit)) else {
            throw GitCommitAIError("Select a valid branch or commit.")
        }
        return try await run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], limit: 1024)
    }

    func prepare(kind: GitIntegrationKind, source: String, target: String, message: String, mainline: Int?) async throws -> GitIntegrationPlan {
        guard target.hasPrefix("refs/heads/"), source != target else { throw GitCommitAIError("Select different source and target branches.") }
        let sourceSHA = try await resolve(source)
        let targetSHA = try await resolve(target)
        let original = try await run(["symbolic-ref", "--quiet", "HEAD"], limit: 1024)
        return .init(kind: kind, source: source, target: target, sourceSHA: sourceSHA,
                     targetSHA: targetSHA, originalBranch: original, message: message, mainline: mainline)
    }

    func context(_ plan: GitIntegrationPlan) async throws -> String {
        if plan.kind == .cherryPick {
            let parents = try await run(["rev-list", "--parents", "-n", "1", plan.sourceSHA]).split(separator: " ").dropFirst()
            if let mainline = plan.mainline {
                guard mainline > 0, mainline <= parents.count else { throw GitCommitAIError("Choose a valid merge parent.") }
                return try await run(["diff", "--no-ext-diff", "--no-textconv", String(Array(parents)[mainline - 1]), plan.sourceSHA, "--"])
            }
            return try await run(["show", "--format=full", "--no-ext-diff", "--no-textconv", plan.sourceSHA, "--"])
        }
        return try await run(["diff", "--no-ext-diff", "--no-textconv", plan.targetSHA + "..." + plan.sourceSHA, "--"])
    }

    func execute(_ plan: GitIntegrationPlan) async throws {
        guard try await resolve(plan.source) == plan.sourceSHA,
              try await resolve(plan.target) == plan.targetSHA,
              try await run(["symbolic-ref", "--quiet", "HEAD"], limit: 1024) == plan.originalBranch else {
            throw GitCommitAIError("Branches changed. Reopen the dialog and try again.")
        }
        if plan.kind == .review { try await createReview(plan); return }
        guard try await run(["status", "--porcelain=v1", "-z"]).isEmpty else {
            throw GitCommitAIError("Commit or stash local changes before this operation.")
        }
        // Fail closed on in-progress operations, including a rebase with a clean index.
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            let result = try await executor.execute(arguments: ["rev-parse", "--verify", "--quiet", marker], workingDirectory: repository.worktreePath)
            if result.isSuccess { throw GitCommitAIError("Finish or abort the current Git operation first.") }
        }
        let status = try await run(["status", "--untracked-files=no"])
        if status.contains("rebase in progress") || status.contains("currently rebasing") || status.contains("cherry-pick") ||
            status.contains("revert") || status.contains("am session") {
            throw GitCommitAIError("Finish or abort the current Git operation first.")
        }
        if plan.kind != .rebase && plan.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitCommitAIError("Enter a commit message.")
        }
        let branch = String(plan.target.dropFirst("refs/heads/".count))
        // switch refuses a target checked out in another worktree. Never use --ignore-other-worktrees.
        if plan.originalBranch != plan.target { _ = try await run(["switch", "--no-guess", branch, "--"]) }
        do {
            switch plan.kind {
            case .merge:
                _ = try await run(["merge", "--no-ff", "--no-commit", "--", plan.sourceSHA])
                let pending = try await executor.execute(arguments: ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], workingDirectory: repository.worktreePath)
                if pending.isSuccess { _ = try await run(["commit", "--file=-"], input: Data(plan.message.utf8)) }
            case .rebase:
                _ = try await run(["-c", "core.editor=true", "rebase", "--", plan.sourceSHA])
            case .cherryPick:
                var args = ["cherry-pick", "--no-commit"]
                if let mainline = plan.mainline { args += ["--mainline", String(mainline)] }
                _ = try await run(args + ["--", plan.sourceSHA])
                _ = try await run(["commit", "--file=-"], input: Data(plan.message.utf8))
            case .review: break
            }
        } catch {
            throw GitCommitAIError(error.localizedDescription + "\n" + GitL10n.text("The target branch remains checked out. Resolve conflicts or abort in the terminal; no automatic reset or push was performed."))
        }
    }

    private func createReview(_ plan: GitIntegrationPlan) async throws {
        guard plan.source.hasPrefix("refs/heads/"),
              let forge = GitForge(origin: try await run(["config", "--get", "remote.origin.url"])) else {
            throw GitCommitAIError("A GitHub or GitLab origin is required.")
        }
        // A review must describe the exact pushed source and target, not stale tracking refs.
        let refs = try await run(["ls-remote", "--heads", "origin", plan.source, plan.target])
        let advertised = Dictionary(refs.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 ? (String(parts[1]), String(parts[0])) : nil
        }, uniquingKeysWith: { first, _ in first })
        guard advertised[plan.source] == plan.sourceSHA, advertised[plan.target] == plan.targetSHA else {
            throw GitCommitAIError("Push the source branch and synchronize the target with origin before creating a PR/MR. Nothing was pushed automatically.")
        }
        let lines = plan.message.components(separatedBy: "\n")
        let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw GitCommitAIError("Enter a title on the first line.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omg-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let file = directory.appendingPathComponent("body.md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        let source = String(plan.source.dropFirst(11)), target = String(plan.target.dropFirst(11))
        let args: [String]
        if forge.kind == .github {
            args = ["gh", "pr", "create", "--repo", forge.base.absoluteString, "--head", source, "--base", target,
                    "--title", title, "--body-file", file.path]
        } else {
            args = ["glab", "mr", "create", "--repo", forge.base.absoluteString, "--source-branch", source,
                    "--target-branch", target, "--title", title, "--description", body, "--yes"]
        }
        let command = args.map(GitCommitAIService.shellQuote).joined(separator: " ")
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"; env["GLAB_PROMPT_DISABLED"] = "1"
        let result = try await GitProcessRunner().run(executablePath: env["SHELL"] ?? "/bin/zsh",
            arguments: ["-lic", "exec " + command], workingDirectory: directory.path, environment: env,
            timeout: 90)
        guard result.isSuccess else {
            throw GitCommitAIError(GitL10n.text("PR/MR creation failed. Check local gh/glab login and existing requests before retrying.") + "\n" + String(result.stderrString.prefix(2000)))
        }
    }
}
