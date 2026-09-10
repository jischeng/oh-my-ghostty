import Foundation

struct GitDiffService: Sendable {
    static let defaultDiffByteLimit = 512 * 1024

    private let executor: (any GitExecutor)?
    let diffByteLimit: Int

    init(
        executor: (any GitExecutor)? = nil,
        diffByteLimit: Int = GitDiffService.defaultDiffByteLimit
    ) {
        self.executor = executor
        self.diffByteLimit = max(1, diffByteLimit)
    }

    /// Read both sides of the index in one invocation, including untracked
    /// files. This also avoids three SSH sessions for each checkbox update.
    func workingTreeFiles(for repository: GitRepositoryIdentity, paths: [String]? = nil) async throws -> (staged: [GitDiffFile], unstaged: [GitDiffFile]) {
        let result = try await run(
            ["--literal-pathspecs", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--renames", "--"] + (paths ?? []),
            repository: repository, maxOutputBytes: 512 * 1024
        )
        return try Self.parseWorkingTreeFiles(result.stdout)
    }

    static func parseWorkingTreeFiles(_ data: Data) throws -> (staged: [GitDiffFile], unstaged: [GitDiffFile]) {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var staged: [GitDiffFile] = []
        var unstaged: [GitDiffFile] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.isEmpty && index == records.count { break }
            let bytes = Array(record.prefix(3))
            guard bytes.count == 3, bytes[2] == 32,
                  let path = String(bytes: record.dropFirst(3), encoding: .utf8), !path.isEmpty else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned an invalid status record."))
            }
            let x = String(UnicodeScalar(bytes[0]))
            let y = String(UnicodeScalar(bytes[1]))
            var oldPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard index < records.count, !records[index].isEmpty,
                      let original = String(bytes: records[index], encoding: .utf8) else {
                    throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned an incomplete rename record."))
                }
                oldPath = original
                index += 1
            }
            if x == "?" && y == "?" {
                unstaged.append(.init(path: path, status: "A", isUntracked: true))
            } else if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(x + y) {
                staged.append(.init(path: path, status: "U"))
                unstaged.append(.init(path: path, status: "U"))
            } else {
                if x != " " && x != "!" { staged.append(.init(path: path, oldPath: x == "R" || x == "C" ? oldPath : nil, status: x)) }
                if y != " " && y != "!" { unstaged.append(.init(path: path, oldPath: y == "R" || y == "C" ? oldPath : nil, status: y)) }
            }
        }
        func sorted(_ files: [GitDiffFile]) -> [GitDiffFile] {
            files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return (sorted(staged), sorted(unstaged))
    }

    /// Lists changed paths without reading their contents. Git's `-z` output is
    /// parsed as records so spaces, unicode, quotes and newlines in paths survive.
    func listFiles(for repository: GitRepositoryIdentity, target: GitDiffTarget, parentIDs: [GitCommitID]? = nil) async throws -> GitDiffFileList {
        switch target {
        case .commit(let commit):
            let commitBase = try await commitBase(for: commit, repository: repository, parentIDs: parentIDs)
            let result = try await run(
                ["--literal-pathspecs", "diff", "--no-ext-diff", "--raw", "--numstat", "-z", "--find-renames", commitBase.id, commit.rawValue, "--"],
                repository: repository,
                maxOutputBytes: 256 * 1024
            )
            let changes = try GitCommitChanges(data: result.stdout)
            return GitDiffFileList(
                repository: repository,
                target: target,
                files: changes.files,
                baseDescription: commitBase.isRoot ? GitL10n.text("empty tree") : GitL10n.format("parent {0}", String(describing: GitCommitID(commitBase.id).shortSHA)),
                commitBase: commitBase,
                statistics: changes.statistics
            )

        case .comparison(let base, let head):
            let result = try await run(["--literal-pathspecs", "diff", "--no-ext-diff", "--raw", "--numstat", "-z", "--find-renames",
                                        base.rawValue, head.rawValue, "--"], repository: repository, maxOutputBytes: 256 * 1024)
            let changes = try GitCommitChanges(data: result.stdout)
            return GitDiffFileList(repository: repository, target: target, files: changes.files,
                                   baseDescription: target.description, statistics: changes.statistics)

        case .staged:
            let result = try await run(
                ["--literal-pathspecs", "diff", "--cached", "--no-ext-diff", "--name-status", "-z", "--find-renames", "--"],
                repository: repository,
                maxOutputBytes: 256 * 1024
            )
            return GitDiffFileList(
                repository: repository,
                target: target,
                files: parseNameStatus(result.stdout),
                baseDescription: GitL10n.text("index vs HEAD")
            )

        case .unstaged:
            async let tracked = run(
                ["--literal-pathspecs", "diff", "--no-ext-diff", "--name-status", "-z", "--find-renames", "--"],
                repository: repository,
                maxOutputBytes: 256 * 1024
            )
            async let untracked = run(
                ["--literal-pathspecs", "ls-files", "--others", "--exclude-standard", "-z", "--"],
                repository: repository,
                maxOutputBytes: 256 * 1024
            )
            var files = try await parseNameStatus(tracked.stdout)
            try await files.append(contentsOf: parseUntracked(untracked.stdout))
            return GitDiffFileList(
                repository: repository,
                target: target,
                files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                baseDescription: GitL10n.text("working tree vs index")
            )
        }
    }

    /// Loads commit metadata once for the detail window. File diffs do not call this method.
    func loadCommitMetadata(
        for commit: GitCommitID,
        repository: GitRepositoryIdentity
    ) async throws -> GitCommitMetadata {
        let result = try await (executor ?? repository.executor).execute(
            arguments: [
                "show", "--encoding=UTF-8", "--no-ext-diff", "--no-color", "--no-patch",
                "--format=%H%x00%an%x00%ae%x00%aI%x00%P%x00%B%x00",
                commit.rawValue,
            ],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 128 * 1024
        )
        guard result.isSuccess else {
            throw GitDiffServiceError.invalidCommit(commit)
        }
        let fields = result.stdout
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(bytes: $0, encoding: .utf8) ?? "" }
        guard fields.count >= 6,
              !fields[0].isEmpty,
              !fields[3].isEmpty else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned incomplete commit metadata."))
        }
        let parents = fields[4]
            .split(whereSeparator: { $0.isWhitespace })
            .map { GitCommitID(String($0)) }
        return GitCommitMetadata(
            commitID: GitCommitID(fields[0]),
            authorName: fields[1],
            authorEmail: fields[2].isEmpty ? nil : fields[2],
            authoredAt: fields[3],
            parents: parents,
            message: fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Reads one file only after the caller has selected it in the file list.
    func loadDiff(
        for file: GitDiffFile,
        repository: GitRepositoryIdentity,
        target: GitDiffTarget,
        baseDescription: String? = nil,
        knownBase: GitDiffCommitBase? = nil
    ) async throws -> GitDiffDocument {
        guard !file.path.isEmpty, !file.path.hasPrefix("/") else {
            throw GitDiffServiceError.invalidPath(file.path)
        }

        let arguments: [String]
        let base: String
        let allowsExitCodeOne: Bool
        switch target {
        case .commit(let commit):
            let resolvedBase = try await commitBase(for: commit, repository: repository, knownBase: knownBase)
            base = baseDescription ?? (resolvedBase.isRoot
                ? GitL10n.text("empty tree")
                : GitL10n.format("parent {0}", String(describing: GitCommitID(resolvedBase.id).shortSHA)))
            arguments = [
                "--literal-pathspecs", "diff", "--no-ext-diff", "--no-color", "--unified=3", "--find-renames",
                resolvedBase.id, commit.rawValue, "--", file.oldPath ?? file.path,
            ] + (file.oldPath == nil ? [] : [file.path])
            allowsExitCodeOne = false

        case .comparison(let from, let to):
            base = baseDescription ?? target.description
            arguments = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-color", "--unified=3", "--find-renames",
                         from.rawValue, to.rawValue, "--", file.oldPath ?? file.path] + (file.oldPath == nil ? [] : [file.path])
            allowsExitCodeOne = false

        case .staged:
            base = baseDescription ?? GitL10n.text("index vs HEAD")
            arguments = [
                "--literal-pathspecs", "diff", "--cached", "--no-ext-diff", "--no-color", "--unified=3", "--find-renames",
                "--", file.oldPath ?? file.path,
            ] + (file.oldPath == nil ? [] : [file.path])
            allowsExitCodeOne = false

        case .unstaged:
            base = baseDescription ?? GitL10n.text("working tree vs index")
            if file.isUntracked {
                let absolutePath = GitRepositoryService.absolutePath(file.path, relativeTo: repository.worktreePath)
                arguments = ["--literal-pathspecs", "diff", "--no-index", "--no-color", "--unified=3", "/dev/null", absolutePath]
                allowsExitCodeOne = true
            } else {
                arguments = [
                    "--literal-pathspecs", "diff", "--no-ext-diff", "--no-color", "--unified=3", "--find-renames",
                    "--", file.oldPath ?? file.path,
                ] + (file.oldPath == nil ? [] : [file.path])
                allowsExitCodeOne = false
            }
        }

        do {
            let result = try await (executor ?? repository.executor).execute(
                arguments: arguments,
                workingDirectory: repository.worktreePath,
                stdin: nil,
                maxOutputBytes: diffByteLimit
            )
            guard result.isSuccess || (allowsExitCodeOne && result.exitCode == 1) else {
                throw GitDiffServiceError.gitFailed(gitErrorMessage(from: result))
            }
            let text = result.stdoutString
            return GitDiffDocument(
                file: file,
                text: text,
                isBinary: isBinaryDiff(text),
                isTruncated: false,
                byteLimit: diffByteLimit,
                baseDescription: base
            )
        } catch GitExecutionError.outputLimitExceeded {
            return GitDiffDocument(
                file: file,
                text: GitL10n.format("Diff exceeds the {0} display limit and was truncated.\n", String(describing: formatBytes(diffByteLimit))),
                isBinary: false,
                isTruncated: true,
                byteLimit: diffByteLimit,
                baseDescription: base
            )
        }
    }

    /// Full source snapshots use the same bounded Git reader as patches.
    func sourceVersions(for file: GitDiffFile, repository: GitRepositoryIdentity,
                        target: GitDiffTarget, knownBase: GitDiffCommitBase? = nil) async throws -> (before: String, after: String) {
        func blob(_ revision: String, _ path: String) async throws -> String {
            let result = try await run(["show", "\(revision):\(path)"], repository: repository,
                                       maxOutputBytes: diffByteLimit)
            guard !result.stdout.contains(0), let text = String(data: result.stdout, encoding: .utf8) else {
                throw EditorDocumentError.binaryFile
            }
            return text
        }
        switch target {
        case .commit(let commit):
            let base = try await commitBase(for: commit, repository: repository, knownBase: knownBase)
            async let before = base.isRoot || file.kind == .added ? "" : blob(base.id, file.oldPath ?? file.path)
            async let after = file.kind == .deleted ? "" : blob(commit.rawValue, file.path)
            return try await (before, after)
        case .comparison(let base, let head):
            async let before = file.kind == .added ? "" : blob(base.rawValue, file.oldPath ?? file.path)
            async let after = file.kind == .deleted ? "" : blob(head.rawValue, file.path)
            return try await (before, after)
        case .staged:
            async let before = file.kind == .added ? "" : blob("HEAD", file.oldPath ?? file.path)
            async let after = file.kind == .deleted ? "" : blob("", file.path)
            return try await (before, after)
        case .unstaged:
            async let before = file.isUntracked || file.kind == .added ? "" : blob("", file.oldPath ?? file.path)
            let after: String
            if file.kind == .deleted {
                after = ""
            } else {
                let path = (repository.worktreePath as NSString).appendingPathComponent(file.path)
                let data = try await (executor ?? repository.executor).readWorkingFile(
                    at: path, root: repository.worktreePath, limit: diffByteLimit
                )
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                    throw EditorDocumentError.binaryFile
                }
                after = text
            }
            return try await (before, after)
        }
    }

    private func commitBase(
        for commit: GitCommitID,
        repository: GitRepositoryIdentity,
        knownBase: GitDiffCommitBase? = nil,
        parentIDs: [GitCommitID]? = nil
    ) async throws -> GitDiffCommitBase {
        if let knownBase, knownBase.commit == commit { return knownBase }
        let parents: [String]
        if let parentIDs { parents = parentIDs.map(\.rawValue) } else {
            let result = try await (executor ?? repository.executor).execute(
                arguments: ["rev-list", "--parents", "-n", "1", commit.rawValue],
                workingDirectory: repository.worktreePath,
                stdin: nil,
                maxOutputBytes: 4 * 1024
            )
            guard result.isSuccess else {
                throw GitDiffServiceError.invalidCommit(commit)
            }
            let parts = result.stdoutString.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.first == commit.rawValue || parts.first.map({ $0.hasPrefix(commit.rawValue) }) == true else {
                throw GitDiffServiceError.invalidCommit(commit)
            }
            parents = Array(parts.dropFirst())
        }
        if let parent = parents.first { return GitDiffCommitBase(commit: commit, id: parent, isRoot: false) }
        let emptyTree = try await (executor ?? repository.executor).execute(
            arguments: ["hash-object", "-t", "tree", "--stdin"],
            workingDirectory: repository.worktreePath,
            stdin: Data(),
            maxOutputBytes: 4 * 1024
        )
        guard emptyTree.isSuccess else {
            throw GitDiffServiceError.gitFailed(gitErrorMessage(from: emptyTree))
        }
        return GitDiffCommitBase(
            commit: commit,
            id: emptyTree.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            isRoot: true
        )
    }

    private func run(
        _ arguments: [String],
        repository: GitRepositoryIdentity,
        maxOutputBytes: Int
    ) async throws -> GitExecutionResult {
        let result = try await (executor ?? repository.executor).execute(
            arguments: arguments,
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: maxOutputBytes
        )
        guard result.isSuccess else {
            throw GitDiffServiceError.gitFailed(gitErrorMessage(from: result))
        }
        return result
    }

    private func parseNameStatus(_ data: Data) -> [GitDiffFile] {
        let fields = data.split(separator: 0).map { String(bytes: $0, encoding: .utf8) ?? "" }
        var files: [GitDiffFile] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            index += 1
            guard !status.isEmpty else { continue }
            let isRenameOrCopy = status.first == "R" || status.first == "C"
            let firstPath = index < fields.count ? fields[index] : ""
            index += 1
            guard !firstPath.isEmpty else { continue }
            if isRenameOrCopy, index < fields.count {
                let newPath = fields[index]
                index += 1
                files.append(GitDiffFile(path: newPath, oldPath: firstPath, status: status))
            } else {
                files.append(GitDiffFile(path: firstPath, status: status))
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func parseUntracked(_ data: Data) -> [GitDiffFile] {
        data.split(separator: 0).map {
            GitDiffFile(path: String(bytes: $0, encoding: .utf8) ?? "", status: "A", isUntracked: true)
        }
    }

    private func isBinaryDiff(_ text: String) -> Bool {
        text.contains("Binary files ") || text.contains("GIT binary patch")
    }

    private func gitErrorMessage(from result: GitExecutionResult) -> String {
        let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? GitL10n.format("Git command failed with exit code {0}.", String(describing: result.exitCode)) : message
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return "\(bytes / (1024 * 1024)) MB" }
        return "\(max(1, bytes / 1024)) KB"
    }
}
