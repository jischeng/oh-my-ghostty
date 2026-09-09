import Foundation

struct GitWorktreeInfo: Equatable, Sendable, Identifiable {
    let path: String
    let head: GitCommitID?
    let branchRef: String?
    let isMain: Bool
    let isCurrent: Bool
    var isBare = false
    var lockedReason: String?
    var prunableReason: String?
    var id: String { path }
    var branchName: String { branchRef.map { String($0.dropFirst("refs/heads/".count)) } ?? "Detached HEAD" }
    var canOpen: Bool { !isBare && prunableReason == nil }
    var canRemove: Bool { !isMain && !isCurrent && !isBare && lockedReason == nil && prunableReason == nil }

    static func parse(_ data: Data, currentPath: String) throws -> [GitWorktreeInfo] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitDiffServiceError.gitFailed("Worktree paths could not be decoded as UTF-8.")
        }
        var result: [GitWorktreeInfo] = []
        var fields: [String: String] = [:]
        func append() {
            guard let path = fields["worktree"] else { return }
            result.append(GitWorktreeInfo(path: path, head: fields["HEAD"].map(GitCommitID.init),
                branchRef: fields["branch"], isMain: result.isEmpty,
                isCurrent: (path as NSString).standardizingPath == (currentPath as NSString).standardizingPath,
                isBare: fields["bare"] != nil, lockedReason: fields["locked"], prunableReason: fields["prunable"]))
            fields.removeAll(keepingCapacity: true)
        }
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty { append(); continue }
            let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            fields[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
        }
        append()
        return result
    }
}

extension GitRepositoryService {
    func worktrees(for repository: GitRepositoryIdentity) async throws -> [GitWorktreeInfo] {
        let result = try await (executor ?? repository.executor).execute(arguments: ["worktree", "list", "--porcelain", "-z"],
            workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 512 * 1024)
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
        let currentPath: String
        switch repository.target {
        case .local: currentPath = URL(fileURLWithPath: repository.worktreePath).resolvingSymlinksInPath().path
        case .ssh: currentPath = repository.worktreePath
        }
        return try GitWorktreeInfo.parse(result.stdout, currentPath: currentPath)
    }
}
