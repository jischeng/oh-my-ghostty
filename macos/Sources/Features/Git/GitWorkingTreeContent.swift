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

struct GitRepositoryHeadInfo: Equatable, Sendable {
    let branchName: String?
    let headCommitID: GitCommitID?
}

struct GitRepositoryRefsSnapshot: Equatable, Sendable {
    let branches: [GitBranchInfo]
    let decorationsByCommitID: [GitCommitID: [GitRefDecoration]]
    let hasRemoteRefs: Bool
}

extension GitRepositoryService {
    func headCommit(for repository: GitRepositoryIdentity) async throws -> GitCommitID {
        let result = try await (executor ?? repository.executor).execute(arguments: ["--no-optional-locks", "rev-parse", "--verify", "HEAD"],
            workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 4096)
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
        return GitCommitID(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func remoteAddress(for repository: GitRepositoryIdentity) async throws -> String? {
        let result = try await (executor ?? repository.executor).execute(arguments: ["--no-optional-locks", "config", "--get", "remote.origin.url"],
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

    func refsSnapshot(for repository: GitRepositoryIdentity, head: GitRepositoryHeadInfo) async throws -> GitRepositoryRefsSnapshot {
        let result = try await (executor ?? repository.executor).execute(
            arguments: [
                "--no-optional-locks",
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(symref)%1e",
                "refs/heads",
                "refs/remotes",
                "refs/tags",
            ],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 2 * 1024 * 1024
        )
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }

        var branches: [GitBranchInfo] = []
        var decorations: [GitCommitID: [GitRefDecoration]] = [:]
        var hasRemoteRefs = false

        for record in result.stdout.split(separator: 0x1e, omittingEmptySubsequences: true) {
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count >= 7 else { continue }
            let fullName = (String(bytes: fields[0], encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
            let objectID = (String(bytes: fields[1], encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
            let peeledID = (String(bytes: fields[2], encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
            let headMarker = String(bytes: fields[3], encoding: .utf8) ?? ""
            let upstream = String(bytes: fields[4], encoding: .utf8) ?? ""
            let tracking = String(bytes: fields[5], encoding: .utf8) ?? ""
            let symref = (String(bytes: fields[6], encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
            guard !fullName.isEmpty, !objectID.isEmpty else { continue }

            let isRemote = fullName.hasPrefix("refs/remotes/")
            if isRemote { hasRemoteRefs = true }

            if (fullName.hasPrefix("refs/heads/") || isRemote) && symref.isEmpty {
                let prefix = isRemote ? "refs/remotes/" : "refs/heads/"
                branches.append(GitBranchInfo(
                    name: String(fullName.dropFirst(prefix.count)),
                    commit: GitCommitID(objectID),
                    isCurrent: headMarker == "*",
                    isRemote: isRemote,
                    upstream: upstream,
                    tracking: tracking
                ))
            }

            let rawID = peeledID.isEmpty ? objectID : peeledID
            let kind: GitRefDecorationKind
            if isRemote {
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                kind = .localBranch
            }
            let name = fullName.replacingOccurrences(of: "^refs/(heads|remotes|tags)/", with: "", options: .regularExpression)
            decorations[GitCommitID(rawID), default: []].append(GitRefDecoration(name: name, kind: kind))
        }

        if let headID = head.headCommitID {
            if let branchName = head.branchName {
                decorations[headID]?.removeAll {
                    $0.name == branchName && $0.kind == .localBranch
                }
                decorations[headID, default: []].append(
                    GitRefDecoration(name: branchName, kind: .currentBranch)
                )
            } else {
                decorations[headID, default: []].append(
                    GitRefDecoration(name: "HEAD", kind: .head)
                )
            }
        }
        for key in decorations.keys {
            decorations[key]?.sort {
                if $0.name == $1.name {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.name < $1.name
            }
        }

        return GitRepositoryRefsSnapshot(
            branches: branches,
            decorationsByCommitID: decorations,
            hasRemoteRefs: hasRemoteRefs
        )
    }

    func branches(for repository: GitRepositoryIdentity) async throws -> [GitBranchInfo] {
        let result = try await (executor ?? repository.executor).execute(
            arguments: ["--no-optional-locks",
                        "for-each-ref",
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
