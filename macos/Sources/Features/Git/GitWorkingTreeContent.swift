import Foundation

struct GitBranchInfo: Equatable, Sendable, Identifiable {
    let name: String
    let commit: GitCommitID
    let isCurrent: Bool
    let isRemote: Bool
    let upstream: String
    let tracking: String
    var id: String { (isRemote ? "refs/remotes/" : "refs/heads/") + name }
}

struct GitWorkingTreeContent: Equatable, Sendable {
    var staged: [GitDiffFile] = []
    var unstaged: [GitDiffFile] = []
    var branches: [GitBranchInfo] = []
    var stagedError: String?
    var unstagedError: String?
    var branchesError: String?
}

extension GitRepositoryService {
    func branches(for repository: GitRepositoryIdentity) async throws -> [GitBranchInfo] {
        let result = try await (executor ?? repository.executor).execute(
            arguments: ["for-each-ref",
                        "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(symref)",
                        "refs/heads", "refs/remotes"],
            workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 512 * 1024
        )
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, fields[5].isEmpty else { return nil }
            let remote = fields[0].hasPrefix("refs/remotes/")
            let prefix = remote ? "refs/remotes/" : "refs/heads/"
            return GitBranchInfo(name: String(fields[0].dropFirst(prefix.count)),
                                 commit: GitCommitID(fields[1]), isCurrent: fields[2] == "*",
                                 isRemote: remote, upstream: fields[3], tracking: fields[4])
        }
    }
}
