import Foundation

/// The source of a diff shown by the Git inspector.
enum GitDiffTarget: Hashable, Sendable, Equatable, CustomStringConvertible {
    case commit(GitCommitID)
    case staged
    case unstaged

    var description: String {
        switch self {
        case .commit(let commit):
            "commit \(commit.shortSHA)"
        case .staged:
            "staged changes"
        case .unstaged:
            "working tree changes"
        }
    }
}

enum GitDiffChangeKind: String, Hashable, Sendable, Equatable {
    case added = "A"
    case copied = "C"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case typeChanged = "T"
    case unmerged = "U"
    case unknown = "?"

    init(status: String) {
        switch status.first.map(String.init) {
        case "A": self = .added
        case "C": self = .copied
        case "D": self = .deleted
        case "M": self = .modified
        case "R": self = .renamed
        case "T": self = .typeChanged
        case "U": self = .unmerged
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .added: "Added"
        case .copied: "Copied"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .typeChanged: "Type changed"
        case .unmerged: "Unmerged"
        case .unknown: "Changed"
        }
    }
}

struct GitDiffFile: Hashable, Sendable, Equatable, Identifiable {
    let id: String
    let path: String
    let oldPath: String?
    let status: String
    let kind: GitDiffChangeKind
    let isUntracked: Bool

    init(path: String, oldPath: String? = nil, status: String, isUntracked: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.kind = GitDiffChangeKind(status: status)
        self.isUntracked = isUntracked
        self.id = "\(status):\(oldPath ?? ""):\(path)"
    }

    var displayPath: String {
        guard let oldPath, oldPath != path else { return path }
        return "\(oldPath) → \(path)"
    }
}

struct GitDiffFileList: Hashable, Sendable, Equatable {
    let repository: GitRepositoryIdentity
    let target: GitDiffTarget
    let files: [GitDiffFile]
    let baseDescription: String
}

struct GitDiffDocument: Hashable, Sendable, Equatable {
    let file: GitDiffFile
    let text: String
    let isBinary: Bool
    let isTruncated: Bool
    let byteLimit: Int
    let baseDescription: String

    var summary: String? {
        guard isBinary else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Binary file"
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GitDiffServiceError: Error, Sendable, Equatable, LocalizedError {
    case invalidCommit(GitCommitID)
    case invalidPath(String)
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommit(let commit): "Commit \(commit) does not exist."
        case .invalidPath(let path): "The file path is invalid: \(path)"
        case .gitFailed(let message): message
        }
    }
}
