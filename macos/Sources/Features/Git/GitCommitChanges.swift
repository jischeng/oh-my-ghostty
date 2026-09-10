import Foundation

/// `git diff --raw --numstat -z` emits raw path records followed by numeric
/// records. Consume NUL fields before interpreting tabs so all valid paths,
/// including rename pairs and paths containing tabs/newlines, stay intact.
struct GitCommitChanges {
    let files: [GitDiffFile]
    let statistics: GitDiffStatistics

    init(data: Data) throws {
        var fields = try data.split(separator: 0).map { field in
            guard let text = String(bytes: field, encoding: .utf8) else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned a path that is not UTF-8."))
            }
            return text
        }[...]
        var files: [GitDiffFile] = []
        while fields.first?.hasPrefix(":") == true {
            let record = fields.removeFirst().split(separator: " ")
            guard record.count == 5, let status = record.last, let path = fields.popFirst() else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned an incomplete changed-file record."))
            }
            if status.first == "R" || status.first == "C" {
                guard let newPath = fields.popFirst() else {
                    throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned an incomplete rename record."))
                }
                files.append(GitDiffFile(path: newPath, oldPath: path, status: String(status)))
            } else {
                files.append(GitDiffFile(path: path, status: String(status)))
            }
        }
        var additions = 0
        var deletions = 0
        var binary = 0
        var paths = Set<String>()
        while let field = fields.popFirst() {
            let values = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard values.count == 3 else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned incomplete change statistics."))
            }
            let path: String
            if values[2].isEmpty {
                guard fields.popFirst() != nil, let newPath = fields.popFirst() else {
                    throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned incomplete rename statistics."))
                }
                path = newPath
            } else { path = String(values[2]) }
            guard paths.insert(path).inserted else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned duplicate change statistics."))
            }
            if values[0] == "-" && values[1] == "-" {
                binary += 1
            } else if let added = Int(values[0]), let removed = Int(values[1]), added >= 0, removed >= 0 {
                guard added <= Int.max - additions, removed <= Int.max - deletions else {
                    throw GitDiffServiceError.gitFailed(GitL10n.text("Git change statistics exceeded the supported range."))
                }
                additions += added
                deletions += removed
            } else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned invalid change statistics."))
            }
        }
        guard paths == Set(files.map(\.path)) else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Git returned mismatched files and change statistics."))
        }
        self.files = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        statistics = GitDiffStatistics(additions: additions, deletions: deletions, binaryFiles: binary)
    }
}
