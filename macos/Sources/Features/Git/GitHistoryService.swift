import Foundation

enum GitHistoryError: Error, Equatable, Sendable, LocalizedError {
    case commandFailed(String)
    case malformedCommit(String)
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .malformedCommit(let value): GitL10n.format("Git returned an invalid commit record: {0}", String(describing: value))
        case .invalidDate(let value): GitL10n.format("Git returned an invalid author date: {0}", String(describing: value))
        }
    }
}

struct GitPrefetchedRefs: Sendable {
    let head: GitRepositoryHeadInfo
    let refs: GitRepositoryRefsSnapshot
}

struct GitHistoryService: Sendable {
    static let pageSize = 100
    /// Cap the remote-only walk so a never-fetched fork cannot stall snapshots.
    static let remoteOnlyLimit = 4096

    private let executor: (any GitExecutor)?

    init(executor: (any GitExecutor)? = nil) {
        self.executor = executor
    }

    func captureSnapshot(
        for repository: GitRepositoryIdentity,
        scope: GitHistoryScope,
        favoriteRefs: Set<String> = [],
        worktrees: [GitWorktreeInfo] = []
    ) async throws -> GitHistorySnapshot {
        async let refsResult = (executor ?? repository.executor).execute(
            arguments: [
                "--no-optional-locks",
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
        async let branchResult = (executor ?? repository.executor).execute(
            arguments: ["--no-optional-locks", "symbolic-ref", "--quiet", "--short", "HEAD"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 16 * 1024
        )
        async let headResult = (executor ?? repository.executor).execute(
            arguments: ["--no-optional-locks", "rev-parse", "--quiet", "--verify", "HEAD"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 16 * 1024
        )
        async let remoteOnlyResult = fetchRemoteOnlyCommitIDs(for: repository)

        let (refs, branch, head, remoteOnlyIDs) = try await (refsResult, branchResult, headResult, remoteOnlyResult)
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

        let tipIDs = GitHistorySnapshot.tipCommitIDs(
            for: scope,
            headCommitID: headID,
            decorationsByCommitID: decorations,
            favoriteRefs: favoriteRefs,
            worktrees: worktrees
        )
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
            decorationsByCommitID: decorations,
            remoteOnlyCommitIDs: remoteOnlyIDs
        )
    }

    func fetchRemoteOnlyCommitIDs(for repository: GitRepositoryIdentity) async throws -> Set<GitCommitID> {
        let remoteOnly = try await (executor ?? repository.executor).execute(
            arguments: [
                "--no-optional-locks",
                "rev-list",
                "--max-count=\(Self.remoteOnlyLimit)",
                "--remotes",
                "--not",
                "--branches",
            ],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 2 * 1024 * 1024
        )
        var remoteOnlyIDs = Set<GitCommitID>()
        if remoteOnly.isSuccess {
            for line in remoteOnly.stdoutString.split(whereSeparator: \.isNewline) {
                let value = line.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { remoteOnlyIDs.insert(GitCommitID(value)) }
            }
        }
        return remoteOnlyIDs
    }

    static func buildSnapshot(
        scope: GitHistoryScope,
        head: GitRepositoryHeadInfo,
        refs: GitRepositoryRefsSnapshot,
        favoriteRefs: Set<String> = [],
        worktrees: [GitWorktreeInfo] = [],
        remoteOnlyCommitIDs: Set<GitCommitID> = []
    ) -> GitHistorySnapshot {
        let tipIDs = GitHistorySnapshot.tipCommitIDs(
            for: scope,
            headCommitID: head.headCommitID,
            decorationsByCommitID: refs.decorationsByCommitID,
            favoriteRefs: favoriteRefs,
            worktrees: worktrees
        )
        return GitHistorySnapshot(
            scope: scope,
            branchName: head.branchName,
            headCommitID: head.headCommitID,
            tipCommitIDs: tipIDs,
            decorationsByCommitID: refs.decorationsByCommitID,
            remoteOnlyCommitIDs: remoteOnlyCommitIDs
        )
    }

    func loadPage(
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity,
        offset: Int,
        pageSize: Int = GitHistoryService.pageSize,
        query: String = "",
        includeMessage: Bool = false
    ) async throws -> GitHistoryPage {
        guard offset >= 0, pageSize > 0 else {
            throw GitHistoryError.commandFailed(GitL10n.text("Invalid Git history page range"))
        }
        guard !snapshot.tipCommitIDs.isEmpty else {
            return GitHistoryPage(commits: [], offset: offset, hasMore: false)
        }

        if !query.isEmpty {
            let search = GitHistorySearchQuery(query)
            guard !search.isEmpty else {
                return try await loadPage(snapshot: snapshot, repository: repository, offset: offset,
                                          pageSize: pageSize, includeMessage: includeMessage)
            }
            return try await loadSearchPage(
                search: search,
                snapshot: snapshot,
                repository: repository,
                request: LogPageRequest(offset: offset, pageSize: pageSize, includeMessage: includeMessage)
            )
        }

        return try await runLogPage(
            snapshot: snapshot,
            repository: repository,
            request: LogPageRequest(offset: offset, pageSize: pageSize, includeMessage: includeMessage)
        )
    }

    private struct LogPageRequest {
        var offset: Int
        var pageSize: Int
        var includeMessage: Bool
        var extraArguments: [String] = []
        var pathspecs: [String] = []
        var useSnapshotTipsStdin = true
    }

    private func loadSearchPage(
        search: GitHistorySearchQuery,
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity,
        request: LogPageRequest
    ) async throws -> GitHistoryPage {
        let offset = request.offset
        let pageSize = request.pageSize
        let includeMessage = request.includeMessage
        let pathspecs = search.paths.flatMap(GitHistorySearchQuery.pathspecs(for:))

        // Case 1: Pure `message:` and/or `path:` query — 100% native single `git log` pushdown.
        if search.isDirectMessageAndPathOnly {
            let messageFilters = search.explicitMessageTerms
            let extraArgs = messageFilters.isEmpty
                ? []
                : ["--regexp-ignore-case", "--fixed-strings", "--all-match"]
                    + messageFilters.map { "--grep=\($0)" }
            return try await runLogPage(
                snapshot: snapshot,
                repository: repository,
                request: LogPageRequest(
                    offset: offset,
                    pageSize: pageSize,
                    includeMessage: !messageFilters.isEmpty || includeMessage,
                    extraArguments: extraArgs,
                    pathspecs: pathspecs
                )
            )
        }

        // Case 2: Plain-text query — push down `--grep` with `--skip`/`--max-count` directly to `git log`,
        // while preserving `--author` and SHA prefix parity in O(1) subprocesses.
        if search.hasNoFieldTerms, !search.text.isEmpty {
            async let grepTask = runLogPage(
                snapshot: snapshot,
                repository: repository,
                request: LogPageRequest(
                    offset: offset,
                    pageSize: pageSize,
                    includeMessage: true,
                    extraArguments: ["--regexp-ignore-case", "--fixed-strings", "--grep=\(search.text)"]
                )
            )
            async let authorTask = runLogPage(
                snapshot: snapshot,
                repository: repository,
                request: LogPageRequest(
                    offset: 0,
                    pageSize: offset + pageSize,
                    includeMessage: true,
                    extraArguments: ["--regexp-ignore-case", "--fixed-strings", "--author=\(search.text)"]
                )
            )
            async let hashTask = resolveReachableHashCommit(
                prefix: search.text,
                snapshot: snapshot,
                repository: repository
            )

            let (grepPage, authorPage, resolvedHash) = try await (grepTask, authorTask, hashTask)
            let authorMatches = authorPage.commits.filter { search.matches($0) }
            let hashMatches = [resolvedHash].compactMap { $0 }.filter { search.matches($0) }

            if authorMatches.isEmpty && hashMatches.isEmpty {
                return grepPage
            }
            if offset == 0 && grepPage.commits.isEmpty && !grepPage.hasMore && hashMatches.isEmpty {
                let hasMore = authorPage.hasMore || authorMatches.count > pageSize
                return GitHistoryPage(
                    commits: Array(authorMatches.prefix(pageSize)),
                    offset: 0,
                    hasMore: hasMore
                )
            }

            let grepAll: GitHistoryPage
            if offset > 0 && (!grepPage.commits.isEmpty || grepPage.hasMore) {
                grepAll = try await runLogPage(
                    snapshot: snapshot,
                    repository: repository,
                    request: LogPageRequest(
                        offset: 0,
                        pageSize: offset + pageSize,
                        includeMessage: true,
                        extraArguments: ["--regexp-ignore-case", "--fixed-strings", "--grep=\(search.text)"]
                    )
                )
            } else {
                grepAll = grepPage
            }

            var seen = Set<GitCommitID>()
            var merged: [GitHistoryCommit] = []
            for commit in grepAll.commits + authorMatches + hashMatches where seen.insert(commit.id).inserted {
                merged.append(commit)
            }
            merged.sort { $0.authoredAt > $1.authoredAt }

            let sliceStart = min(offset, merged.count)
            let sliceEnd = min(offset + pageSize, merged.count)
            let hasMore = merged.count > offset + pageSize || grepAll.hasMore || authorPage.hasMore
            return GitHistoryPage(
                commits: Array(merged[sliceStart..<sliceEnd]),
                offset: offset,
                hasMore: hasMore
            )
        }

        // Case 3: Explicit `hash:` prefix with unambiguous >= 4-hex prefix.
        if let hashPrefix = search.explicitHashTerms.first,
           hashPrefix.count >= 4,
           let commit = try await resolveReachableHashCommit(
               prefix: hashPrefix,
               snapshot: snapshot,
               repository: repository
           ) {
            let touchesPath: Bool
            if pathspecs.isEmpty {
                touchesPath = true
            } else {
                let pathCheck = try await runLogPage(
                    snapshot: snapshot,
                    repository: repository,
                    request: LogPageRequest(
                        offset: 0,
                        pageSize: 1,
                        includeMessage: false,
                        extraArguments: [commit.id.rawValue, "--no-walk"],
                        pathspecs: pathspecs,
                        useSnapshotTipsStdin: false
                    )
                )
                touchesPath = !pathCheck.commits.isEmpty
            }
            if touchesPath && search.matches(commit) {
                let commits = offset == 0 ? [commit] : []
                return GitHistoryPage(commits: commits, offset: offset, hasMore: false)
            }
        }

        // Case 4: Compound field filters — push down `--grep`, primary `--author`, and `pathspecs` to C git,
        // then verify remaining multi-term predicates in Swift.
        var pushedArgs: [String] = []
        if !search.explicitMessageTerms.isEmpty {
            pushedArgs += ["--regexp-ignore-case", "--fixed-strings", "--all-match"]
            pushedArgs += search.explicitMessageTerms.map { "--grep=\($0)" }
        }
        if let primaryAuthor = search.explicitAuthorTerms.first ?? search.explicitEmailTerms.first {
            if !pushedArgs.contains("--regexp-ignore-case") {
                pushedArgs += ["--regexp-ignore-case", "--fixed-strings"]
            }
            pushedArgs.append("--author=\(primaryAuthor)")
        }

        var matches: [GitHistoryCommit] = []
        var scanned = 0
        var skipped = 0
        let batchSize = max(200, pageSize)
        while matches.count <= pageSize {
            try Task.checkCancellation()
            let batch = try await runLogPage(
                snapshot: snapshot,
                repository: repository,
                request: LogPageRequest(
                    offset: scanned,
                    pageSize: batchSize,
                    includeMessage: true,
                    extraArguments: pushedArgs,
                    pathspecs: pathspecs
                )
            )
            for commit in batch.commits where search.matches(commit) {
                if skipped < offset {
                    skipped += 1
                } else {
                    matches.append(commit)
                }
            }
            scanned += batch.commits.count
            if !batch.hasMore { break }
        }
        return GitHistoryPage(
            commits: Array(matches.prefix(pageSize)),
            offset: offset,
            hasMore: matches.count > pageSize
        )
    }

    private func runLogPage(
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity,
        request: LogPageRequest
    ) async throws -> GitHistoryPage {
        let requestedCount = request.pageSize + 1
        var arguments = [
            "--no-optional-locks",
            "log",
            "--encoding=UTF-8",
            "--topo-order",
            "--no-color",
            "--no-decorate",
            "-z",
            "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%" + (request.includeMessage ? "B" : "s"),
            "--skip=\(request.offset)",
            "--max-count=\(requestedCount)",
        ] + request.extraArguments
        if request.useSnapshotTipsStdin {
            arguments.append("--stdin")
        }
        if !request.pathspecs.isEmpty {
            arguments.append("--")
            arguments.append(contentsOf: request.pathspecs)
        }
        let stdinData = request.useSnapshotTipsStdin
            ? Data((snapshot.tipCommitIDs.map(\.rawValue).joined(separator: "\n") + "\n").utf8)
            : nil
        let result = try await (executor ?? repository.executor).execute(
            arguments: arguments,
            workingDirectory: repository.worktreePath,
            // Keep frozen revisions out of argv: SSH wraps/encodes its command
            // and large all-branch snapshots can exceed the remote shell limit.
            stdin: stdinData,
            maxOutputBytes: max(512 * 1024, requestedCount * 512)
        )
        guard result.isSuccess else {
            throw GitHistoryError.commandFailed(result.stderrString)
        }

        // NUL cannot occur in Git's text fields. `-z` terminates each record,
        // so fixed groups of six fields also preserve empty parents/subjects
        // and legal control characters such as the record separator (0x1e).
        guard result.stdout.isEmpty || result.stdout.last == 0 else {
            throw GitHistoryError.malformedCommit(GitL10n.text("Unterminated history record"))
        }
        let fields: [Data] = result.stdout.isEmpty ? [] : result.stdout.dropLast()
            .split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
        guard fields.count.isMultiple(of: 6) else {
            throw GitHistoryError.malformedCommit(GitL10n.text("Incomplete history record"))
        }
        let recordCount = fields.count / 6
        let hasMore = recordCount > request.pageSize
        let commits = try (0..<min(request.pageSize, recordCount)).map { index in
            var commit = try parseCommit(fields: Array(fields[(index * 6)..<(index * 6 + 6)]), snapshot: snapshot)
            commit.isRemoteOnly = snapshot.remoteOnlyCommitIDs.contains(commit.id)
            if request.includeMessage {
                commit.message = commit.subject
                commit.subject = commit.message.components(separatedBy: "\n").first ?? ""
            }
            return commit
        }
        return GitHistoryPage(commits: commits, offset: request.offset, hasMore: hasMore)
    }

    private func resolveReachableHashCommit(
        prefix: String,
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity
    ) async throws -> GitHistoryCommit? {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...64).contains(trimmed.count), trimmed.allSatisfy(\.isHexDigit) else {
            return nil
        }
        let revParse = try await (executor ?? repository.executor).execute(
            arguments: ["--no-optional-locks", "rev-parse", "--quiet", "--verify", "\(trimmed)^{commit}"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 1024
        )
        guard revParse.isSuccess else { return nil }
        let fullSHA = revParse.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullSHA.isEmpty else { return nil }

        let negatedTips = snapshot.tipCommitIDs.map { "^\($0.rawValue)" }.joined(separator: "\n") + "\n"
        let reachability = try await (executor ?? repository.executor).execute(
            arguments: ["--no-optional-locks", "rev-list", "--max-count=1", fullSHA, "--stdin"],
            workingDirectory: repository.worktreePath,
            stdin: Data(negatedTips.utf8),
            maxOutputBytes: 1024
        )
        guard reachability.isSuccess,
              reachability.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let single = try await runLogPage(
            snapshot: snapshot,
            repository: repository,
            request: LogPageRequest(
                offset: 0,
                pageSize: 1,
                includeMessage: true,
                extraArguments: [fullSHA, "--no-walk"],
                useSnapshotTipsStdin: false
            )
        )
        return single.commits.first
    }

    private func parseCommit(
        fields: [Data],
        snapshot: GitHistorySnapshot
    ) throws -> GitHistoryCommit {
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

/// History search syntax. Plain text keeps the original behavior: a
/// case-insensitive substring of the subject, full message, author name,
/// author email or hash. Field prefixes narrow individual terms and combine
/// with AND: `author:`, `email:`, `path:` (alias `file:`), `message:` (alias
/// `msg:`) and `hash:` (alias `commit:`). Values may be double-quoted to
/// include spaces, e.g. `author:"Jane Doe" path:src/foo.zig`.
struct GitHistorySearchQuery: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case author, email, path, message, hash

        init?(prefix: String) {
            switch prefix.lowercased() {
            case "author": self = .author
            case "email": self = .email
            case "path", "file": self = .path
            case "message", "msg": self = .message
            case "hash", "commit": self = .hash
            default: return nil
            }
        }
    }

    private(set) var text = ""
    private(set) var terms: [Field: [String]] = [:]

    var paths: [String] { terms[.path] ?? [] }
    var isEmpty: Bool { text.isEmpty && terms.values.allSatisfy(\.isEmpty) }
    var hasNoFieldTerms: Bool { terms.values.allSatisfy(\.isEmpty) }
    var explicitMessageTerms: [String] { terms[.message] ?? [] }
    var explicitAuthorTerms: [String] { terms[.author] ?? [] }
    var explicitEmailTerms: [String] { terms[.email] ?? [] }
    var explicitHashTerms: [String] { terms[.hash] ?? [] }
    var isDirectMessageAndPathOnly: Bool {
        text.isEmpty
            && explicitAuthorTerms.isEmpty
            && explicitEmailTerms.isEmpty
            && explicitHashTerms.isEmpty
    }
    var messageTerms: [String] { (text.isEmpty ? [] : [text]) + (terms[.message] ?? []) }
    var authorTerms: [String] { (text.isEmpty ? [] : [text]) + (terms[.author] ?? []) }
    var emailTerms: [String] { (text.isEmpty ? [] : [text]) + (terms[.email] ?? []) }
    var subjectHighlightTerms: [String] { messageTerms + fileTerms }

    /// Highlight needles for a commit's short SHA, including prefix matches on
    /// the full SHA (`hash:` or free text).
    func hashTerms(for id: GitCommitID) -> [String] {
        var result: [String] = []
        if !text.isEmpty {
            if id.shortSHA.localizedCaseInsensitiveContains(text) {
                result.append(text)
            } else if id.rawValue.lowercased().hasPrefix(text.lowercased()) {
                result.append(id.shortSHA)
            }
        }
        for value in terms[.hash] ?? [] where id.rawValue.lowercased().hasPrefix(value.lowercased()) {
            let prefix = String(id.shortSHA.prefix(value.count))
            if !prefix.isEmpty { result.append(prefix) }
        }
        return result
    }

    /// Highlight needles for changed file/folder rows when `path:` or free text
    /// is active. Includes both full path fragments and individual components
    /// so list mode (`src/foo.zig`) and tree mode (`src`, `foo.zig`) both highlight.
    var fileTerms: [String] {
        var result: [String] = text.isEmpty ? [] : [text]
        for raw in paths {
            let cleaned = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: "./*?[]"))
            if !cleaned.isEmpty { result.append(cleaned) }
            for part in raw.split(separator: "/") {
                let segment = part.trimmingCharacters(in: CharacterSet(charactersIn: "*?[]"))
                if !segment.isEmpty, segment != "." && segment != ".." {
                    result.append(segment)
                }
            }
        }
        return result
    }

    /// First non-subject body line matching a message/text term when the
    /// commit's subject itself does not contain that term, or the matched
    /// `path:` filter when not already present in the subject.
    func bodySnippet(for commit: GitHistoryCommit) -> String? {
        let missing = messageTerms.filter { !commit.subject.localizedCaseInsensitiveContains($0) }
        if !missing.isEmpty, !commit.message.isEmpty {
            for (index, rawLine) in commit.message.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if index == 0, line == commit.subject.trimmingCharacters(in: .whitespacesAndNewlines) {
                    continue
                }
                if missing.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                    return line
                }
            }
        }
        if !paths.isEmpty,
           !fileTerms.contains(where: { !$0.isEmpty && commit.subject.localizedCaseInsensitiveContains($0) }) {
            return paths.joined(separator: ", ")
        }
        return nil
    }

    init(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var freeText: [String] = []
        var hasField = false
        for token in Self.tokenize(trimmed) {
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex,
               let field = Field(prefix: String(token[..<colon])) {
                // A prefix still being typed (`author:`) filters nothing yet.
                hasField = true
                let value = Self.unquote(String(token[token.index(after: colon)...]))
                if !value.isEmpty { terms[field, default: []].append(value) }
            } else {
                freeText.append(Self.unquote(token))
            }
        }
        // Without field prefixes, keep the exact phrase (including spacing).
        text = hasField ? freeText.joined(separator: " ") : trimmed
    }

    /// Whether the commit satisfies every non-path term. Path terms need
    /// Git's changed-file information and are applied by the service.
    func matches(_ commit: GitHistoryCommit) -> Bool {
        if !text.isEmpty {
            let haystack = [commit.subject, commit.message, commit.authorName, commit.authorEmail, commit.id.rawValue]
                .joined(separator: "\n")
            guard haystack.localizedCaseInsensitiveContains(text) else { return false }
        }
        for value in terms[.author] ?? [] where !commit.authorName.localizedCaseInsensitiveContains(value) {
            return false
        }
        for value in terms[.email] ?? [] where !commit.authorEmail.localizedCaseInsensitiveContains(value) {
            return false
        }
        for value in terms[.message] ?? [] {
            guard commit.subject.localizedCaseInsensitiveContains(value)
                || commit.message.localizedCaseInsensitiveContains(value) else { return false }
        }
        for value in terms[.hash] ?? [] where !commit.id.rawValue.lowercased().hasPrefix(value.lowercased()) {
            return false
        }
        return true
    }

    /// Repository-root pathspecs for one `path:` value. Values with glob
    /// characters are passed as globs; otherwise the exact path (file or
    /// directory) and the same name at any depth both match.
    static func pathspecs(for value: String) -> [String] {
        var path = value
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return [] }
        if path.contains(where: { "*?[".contains($0) }) { return [":(top,glob)\(path)"] }
        return [":(top,literal)\(path)", ":(top,glob)**/\(path)", ":(top,glob)**/\(path)/**"]
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
    }
}
