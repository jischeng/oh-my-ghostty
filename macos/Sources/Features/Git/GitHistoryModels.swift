import Foundation

enum GitHistoryScope: String, CaseIterable, Equatable, Sendable {
    case currentBranch
    case allBranches

    var displayName: String {
        switch self {
        case .currentBranch: "Current branch"
        case .allBranches: "All branches"
        }
    }
}

enum GitRefDecorationKind: String, Equatable, Sendable {
    case currentBranch
    case localBranch
    case remoteBranch
    case tag
    case head
}

struct GitRefDecoration: Hashable, Equatable, Sendable {
    let name: String
    let kind: GitRefDecorationKind

    static func orderedForDisplay(_ refs: [Self]) -> [Self] {
        func rank(_ ref: Self) -> Int {
            if ref.kind == .tag { return 6 }
            if ref.kind == .head { return 5 }
            if ref.name == "main" { return 0 }
            if ref.kind == .remoteBranch && ref.name.hasSuffix("/main") { return 1 }
            if ref.kind == .currentBranch { return 2 }
            return ref.kind == .localBranch ? 3 : 4
        }
        return refs.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct GitHistoryCommit: Identifiable, Hashable, Equatable, Sendable {
    let id: GitCommitID
    let parentIDs: [GitCommitID]
    let authorName: String
    let authorEmail: String
    let authoredAt: Date
    let subject: String
    let refDecorations: [GitRefDecoration]

    init(
        id: GitCommitID,
        parentIDs: [GitCommitID],
        authorName: String,
        authorEmail: String,
        authoredAt: Date,
        subject: String,
        refDecorations: [GitRefDecoration] = []
    ) {
        self.id = id
        self.parentIDs = parentIDs
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.subject = subject
        self.refDecorations = refDecorations
    }
}

struct GitHistorySnapshot: Equatable, Sendable {
    let scope: GitHistoryScope
    let branchName: String?
    let headCommitID: GitCommitID?
    let tipCommitIDs: [GitCommitID]
    let decorationsByCommitID: [GitCommitID: [GitRefDecoration]]

    var browsedBranch: String?

    var isEmpty: Bool { tipCommitIDs.isEmpty }
}

struct GitHistoryPage: Equatable, Sendable {
    let commits: [GitHistoryCommit]
    let offset: Int
    let hasMore: Bool
}

struct InspectorGitHistoryContent: Equatable, Sendable {
    let scope: GitHistoryScope
    let commits: [GitHistoryCommit]
    let selectedCommitID: GitCommitID?
    let hasMore: Bool
    let isLoading: Bool
    let statusMessage: String?
    let snapshot: GitHistorySnapshot?

    init(
        scope: GitHistoryScope = .allBranches,
        commits: [GitHistoryCommit] = [],
        selectedCommitID: GitCommitID? = nil,
        hasMore: Bool = false,
        isLoading: Bool = false,
        statusMessage: String? = nil,
        snapshot: GitHistorySnapshot? = nil
    ) {
        self.scope = scope
        self.commits = commits
        self.selectedCommitID = selectedCommitID
        self.hasMore = hasMore
        self.isLoading = isLoading
        self.statusMessage = statusMessage
        self.snapshot = snapshot
    }
}

struct GitCommitExpansion: Equatable, Sendable {
    var metadata: GitCommitMetadata?
    var files: [GitDiffFile] = []
    var isLoading = false
    var error: String?

    var detailText: String {
        if let error { return error }
        guard let metadata else { return isLoading ? "Loading changed files…" : "No commit details" }
        return "Author  \(metadata.authorDescription)\nDate  \(metadata.authoredAt)\nCommit  \(metadata.commitID.rawValue)\n\nMessage\n\(metadata.message)"
    }
}
