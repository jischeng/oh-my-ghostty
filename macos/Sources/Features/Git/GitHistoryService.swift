import Foundation

enum GitHistoryError: Error, Equatable, Sendable, LocalizedError {
    case commandFailed(String)
    case malformedCommit(String)
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .malformedCommit(let value): "Git returned an invalid commit record: \(value)"
        case .invalidDate(let value): "Git returned an invalid author date: \(value)"
        }
    }
}

struct GitHistoryService: Sendable {
    static let pageSize = 100

    private let executor: any GitExecutor

    init(executor: any GitExecutor = LocalGitExecutor()) {
        self.executor = executor
    }

    func captureSnapshot(
        for repository: GitRepositoryIdentity,
        scope: GitHistoryScope
    ) async throws -> GitHistorySnapshot {
        async let refsResult = executor.execute(
            arguments: [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%1e",
                "refs/heads",
                "refs/remotes",
                "refs/tags",
            ],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 2 * 1024 * 1024
        )
        async let branchResult = executor.execute(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 16 * 1024
        )
        async let headResult = executor.execute(
            arguments: ["rev-parse", "--quiet", "--verify", "HEAD"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 16 * 1024
        )

        let (refs, branch, head) = try await (refsResult, branchResult, headResult)
        guard refs.isSuccess else {
            throw GitHistoryError.commandFailed(refs.stderrString)
        }

        let branchName = branch.isSuccess
            ? branch.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let headID = head.isSuccess
            ? GitCommitID(head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil

        var refsByName: [(name: String, id: GitCommitID, kind: GitRefDecorationKind)] = []
        for record in refs.stdout.split(separator: 0x1e, omittingEmptySubsequences: true) {
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let fullName = (String(bytes: fields[0], encoding: .utf8) ?? "")
                .trimmingCharacters(in: .newlines)
            let objectID = (String(bytes: fields[1], encoding: .utf8) ?? "")
                .trimmingCharacters(in: .newlines)
            let peeledID = fields.count >= 3
                ? (String(bytes: fields[2], encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
                : ""
            let rawID = peeledID.isEmpty ? objectID : peeledID
            guard !fullName.isEmpty, !rawID.isEmpty else { continue }
            let kind: GitRefDecorationKind
            if fullName.hasPrefix("refs/remotes/") {
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                kind = .localBranch
            }
            let name = fullName.replacingOccurrences(of: "^refs/(heads|remotes|tags)/", with: "", options: .regularExpression)
            refsByName.append((name, GitCommitID(rawID), kind))
        }

        var decorations: [GitCommitID: [GitRefDecoration]] = [:]
        for ref in refsByName {
            decorations[ref.id, default: []].append(
                GitRefDecoration(name: ref.name, kind: ref.kind)
            )
        }

        if let headID {
            if let branchName {
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

        let branchRefs = refsByName.filter { $0.kind == .localBranch || $0.kind == .remoteBranch }
        var tipIDs: [GitCommitID]
        switch scope {
        case .currentBranch:
            tipIDs = headID.map { [$0] } ?? []
        case .allBranches:
            tipIDs = branchRefs
                .sorted { $0.name < $1.name }
                .map(\.id)
            if let headID, !tipIDs.contains(headID) {
                tipIDs.append(headID)
            }
        }

        // Keep the order deterministic and avoid asking git to walk the same tip twice.
        var seen = Set<GitCommitID>()
        tipIDs = tipIDs.filter { seen.insert($0).inserted }
        for key in decorations.keys {
            decorations[key]?.sort {
                if $0.name == $1.name {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.name < $1.name
            }
        }

        return GitHistorySnapshot(
            scope: scope,
            branchName: branchName,
            headCommitID: headID,
            tipCommitIDs: tipIDs,
            decorationsByCommitID: decorations
        )
    }

    func loadPage(
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity,
        offset: Int,
        pageSize: Int = GitHistoryService.pageSize
    ) async throws -> GitHistoryPage {
        guard offset >= 0, pageSize > 0 else {
            throw GitHistoryError.commandFailed("Invalid Git history page range")
        }
        guard !snapshot.tipCommitIDs.isEmpty else {
            return GitHistoryPage(commits: [], offset: offset, hasMore: false)
        }

        let requestedCount = pageSize + 1
        let result = try await executor.execute(
            arguments: [
                "log",
                "--topo-order",
                "--no-color",
                "--no-decorate",
                "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x1e",
                "--skip=\(offset)",
                "--max-count=\(requestedCount)",
            ] + snapshot.tipCommitIDs.map(\.rawValue),
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: max(512 * 1024, requestedCount * 512)
        )
        guard result.isSuccess else {
            throw GitHistoryError.commandFailed(result.stderrString)
        }

        let records = result.stdout
            .split(separator: 0x1e, omittingEmptySubsequences: true)
            .filter { !$0.allSatisfy { $0 == 0x0a || $0 == 0x0d } }
        let hasMore = records.count > pageSize
        let commits = try records.prefix(pageSize).map {
            try parseCommit(record: Data($0), snapshot: snapshot)
        }
        return GitHistoryPage(commits: commits, offset: offset, hasMore: hasMore)
    }

    private func parseCommit(
        record: Data,
        snapshot: GitHistorySnapshot
    ) throws -> GitHistoryCommit {
        let normalizedRecord = record.drop(while: { $0 == 0x0a || $0 == 0x0d })
        let fields = normalizedRecord.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 6 else {
            throw GitHistoryError.malformedCommit(String(bytes: normalizedRecord, encoding: .utf8) ?? "")
        }
        let id = GitCommitID(String(bytes: fields[0], encoding: .utf8) ?? "")
        let parentIDs = (String(bytes: fields[1], encoding: .utf8) ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map { GitCommitID(String($0)) }
        let dateValue = String(bytes: fields[4], encoding: .utf8) ?? ""
        guard let date = Self.parseDate(dateValue) else {
            throw GitHistoryError.invalidDate(dateValue)
        }
        return GitHistoryCommit(
            id: id,
            parentIDs: parentIDs,
            authorName: String(bytes: fields[2], encoding: .utf8) ?? "",
            authorEmail: String(bytes: fields[3], encoding: .utf8) ?? "",
            authoredAt: date,
            subject: String(bytes: fields[5], encoding: .utf8) ?? "",
            refDecorations: snapshot.decorationsByCommitID[id] ?? []
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone, .withColonSeparatorInTimeZone]
        return formatter.date(from: value)
    }
}
