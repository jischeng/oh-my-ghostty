import Foundation

struct GitBranchInfo: Equatable, Sendable, Identifiable {
    let name: String
    let commit: GitCommitID
    let isCurrent: Bool
    let isRemote: Bool
    let upstream: String
    let tracking: String
    var id: String { (isRemote ? "refs/remotes/" : "refs/heads/") + name }

    var aheadCount: Int {
        guard let match = tracking.range(of: #"ahead\s+\d+"#, options: .regularExpression) else { return 0 }
        let segment = tracking[match]
        let numStr = segment.split(separator: " ").last.map(String.init) ?? "0"
        return Int(numStr) ?? 0
    }

    var behindCount: Int {
        guard let match = tracking.range(of: #"behind\s+\d+"#, options: .regularExpression) else { return 0 }
        let segment = tracking[match]
        let numStr = segment.split(separator: " ").last.map(String.init) ?? "0"
        return Int(numStr) ?? 0
    }

    var isGone: Bool {
        tracking.contains("gone")
    }

    var upstreamTrackingDisplay: String {
        if upstream.isEmpty {
            return GitL10n.text("No upstream configured")
        }
        if isGone {
            return "\(upstream) · \(GitL10n.text("gone"))"
        }
        if aheadCount == 0 && behindCount == 0 {
            return "\(upstream) · \(GitL10n.text("Up to date"))"
        }
        var parts: [String] = []
        if behindCount > 0 {
            parts.append("↓ \(behindCount)")
        }
        if aheadCount > 0 {
            parts.append("↑ \(aheadCount)")
        }
        return "\(upstream) · \(parts.joined(separator: " "))"
    }
}

struct GitWorkingTreeContent: Equatable, Sendable {
    var staged: [GitDiffFile] = []
    var unstaged: [GitDiffFile] = []
    var branches: [GitBranchInfo] = []
    var worktrees: [GitWorktreeInfo] = []
    var stagedError: String?
    var unstagedError: String?
    var branchesError: String?
    var worktreesError: String?
    var remoteURL: String?

    mutating func applyIndexChanges(paths: [String], staged: [GitDiffFile], unstaged: [GitDiffFile]) {
        let affected = Set(paths + (staged + unstaged).flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) })
        func merge(_ current: [GitDiffFile], _ changes: [GitDiffFile]) -> [GitDiffFile] {
            (current.filter { !affected.contains($0.path) && !($0.oldPath.map(affected.contains) ?? false) } + changes)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        self.staged = merge(self.staged, staged)
        self.unstaged = merge(self.unstaged, unstaged)
    }
}

extension GitRepositoryService {
    func headCommit(for repository: GitRepositoryIdentity) async throws -> GitCommitID {
        let result = try await (executor ?? repository.executor).execute(arguments: ["rev-parse", "--verify", "HEAD"],
            workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 4096)
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
        return GitCommitID(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func remoteAddress(for repository: GitRepositoryIdentity) async throws -> String? {
        let result = try await (executor ?? repository.executor).execute(arguments: ["config", "--get", "remote.origin.url"],
            workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 16 * 1024)
        if result.exitCode == 1 { return nil }
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if var url = URLComponents(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            url.user = nil
            url.password = nil
            url.query = nil
            url.fragment = nil
            return url.string
        }
        return value
    }

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
