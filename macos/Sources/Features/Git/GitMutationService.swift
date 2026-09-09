import Foundation

enum GitBranchOperation: String, Equatable, Sendable {
    case checkout
    case create
    case push
    case setUpstream
}

enum GitMutation: Equatable, Sendable {
    case stage([String])
    case unstage([String])
    case commit(String)
    case checkout(String)
    case create(name: String, start: String)
    case push(branch: String, remote: String, destination: String)
    case setUpstream(branch: String, upstream: String)

    var title: String {
        switch self {
        case .stage: "Staging files…"
        case .unstage: "Unstaging files…"
        case .commit: "Committing…"
        case .checkout: "Switching branch…"
        case .create: "Creating branch…"
        case .push: "Pushing…"
        case .setUpstream: "Setting upstream…"
        }
    }
}

struct GitMutationService: Sendable {
    let executor: (any GitExecutor)?
    init(executor: (any GitExecutor)? = nil) { self.executor = executor }

    func remotes(in repository: GitRepositoryIdentity) async throws -> [String] {
        let result = try await run(["remote"], in: repository)
        return result.stdoutString.split(separator: "\n").map(String.init)
    }

    func perform(_ mutation: GitMutation, in repository: GitRepositoryIdentity) async throws {
        switch mutation {
        case .stage(let paths):
            try validate(paths)
            _ = try await run(["--literal-pathspecs", "add", "--"] + paths, in: repository)
        case .unstage(let paths):
            try validate(paths)
            let head = try await (executor ?? repository.executor).execute(arguments: ["rev-parse", "--verify", "HEAD"],
                                                 workingDirectory: repository.worktreePath)
            if head.isSuccess {
                _ = try await run(["--literal-pathspecs", "restore", "--staged", "--"] + paths, in: repository)
            } else {
                // The empty-tree index is the base before the first commit.
                _ = try await run(["--literal-pathspecs", "rm", "--cached", "--force", "--"] + paths, in: repository)
            }
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitDiffServiceError.gitFailed("Enter a commit message.")
            }
            _ = try await run(["commit", "--file=-"], in: repository, stdin: Data(message.utf8))
        case .checkout(let name):
            try await validateBranch(name, in: repository)
            _ = try await run(["switch", "--no-guess", name, "--"], in: repository)
        case .create(let name, let start):
            try await validateBranch(name, in: repository)
            try validateRef(start)
            _ = try await run(["switch", "-c", name, start, "--"], in: repository)
        case .push(let branch, let remote, let destination):
            try await validateBranch(branch, in: repository)
            try await validateBranch(destination, in: repository)
            guard try await remotes(in: repository).contains(remote) else {
                throw GitDiffServiceError.gitFailed("The selected remote no longer exists.")
            }
            _ = try await run(["push", "--porcelain", "--", remote,
                              "refs/heads/\(branch):refs/heads/\(destination)"], in: repository)
        case .setUpstream(let branch, let upstream):
            try await validateBranch(branch, in: repository)
            try validateRef(upstream)
            _ = try await run(["branch", "--set-upstream-to=\(upstream)", "--", branch], in: repository)
        }
    }

    private func validate(_ paths: [String]) throws {
        guard !paths.isEmpty, paths.allSatisfy({
            !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..")
        }) else { throw GitDiffServiceError.gitFailed("Invalid file selection.") }
    }

    private func validateRef(_ ref: String) throws {
        guard ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/"),
              !ref.contains("\0") else { throw GitDiffServiceError.gitFailed("Invalid branch reference.") }
    }

    private func validateBranch(_ name: String, in repository: GitRepositoryIdentity) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), !name.contains("@{") else {
            throw GitDiffServiceError.gitFailed("Invalid branch name.")
        }
        _ = try await run(["check-ref-format", "--branch", name], in: repository)
    }

    private func run(_ arguments: [String], in repository: GitRepositoryIdentity,
                     stdin: Data? = nil) async throws -> GitExecutionResult {
        let result = try await (executor ?? repository.executor).execute(arguments: arguments, workingDirectory: repository.worktreePath,
                                                stdin: stdin, maxOutputBytes: 1024 * 1024)
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result
    }
}
