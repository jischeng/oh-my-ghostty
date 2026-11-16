import Foundation

enum GitHistoryScope: String, CaseIterable, Equatable, Sendable {
    case currentBranch
    case favorites
    case allBranches

    var displayName: String {
        switch self {
        case .currentBranch: GitL10n.text("Current branch")
        case .favorites: GitL10n.text("Favorite Branches")
        case .allBranches: GitL10n.text("All branches")
        }
    }
}

enum GitRefDecorationKind: String, Equatable, Sendable {
    case currentBranch
    case localBranch
    case remoteBranch
    case tag
    case head
    var displayName: String {
        switch self {
        case .head: "HEAD"
        case .currentBranch: GitL10n.text("Current branch")
        case .localBranch: GitL10n.text("Local branch")
        case .remoteBranch: GitL10n.text("Remote branch")
        case .tag: GitL10n.text("Tag")
        }
    }
}

struct GitRefDecoration: Hashable, Equatable, Sendable {
    let name: String
    let kind: GitRefDecorationKind
    var fullRef: String {
        switch kind {
        case .head: name
        case .currentBranch, .localBranch: "refs/heads/" + name
        case .remoteBranch: "refs/remotes/" + name
        case .tag: "refs/tags/" + name
        }
    }

    static func orderedForDisplay(_ refs: [Self]) -> [Self] {
        func rank(_ ref: Self) -> Int {
            if ref.kind == .tag { return 6 }
            if ref.kind == .head { return -1 }
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
    var subject: String
    var message: String = ""
    let refDecorations: [GitRefDecoration]
    /// Reachable from a remote-tracking ref but not from any local branch,
    /// i.e. fetched but not yet merged/pulled into local history.
    var isRemoteOnly = false

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
    private struct BranchRef {
        let name: String
        let fullRef: String
        let id: GitCommitID
    }

    let scope: GitHistoryScope
    let branchName: String?
    let headCommitID: GitCommitID?
    let repositoryHeadCommitID: GitCommitID?
    let tipCommitIDs: [GitCommitID]
    let decorationsByCommitID: [GitCommitID: [GitRefDecoration]]
    /// Commits only reachable from remote-tracking refs (fetched, not pulled).
    var remoteOnlyCommitIDs: Set<GitCommitID>
    let sortedTags: [GitRefDecoration]

    var browsedBranch: String?
    var browsedRef: String?
    var browsedWorktree: String?

    var isEmpty: Bool { tipCommitIDs.isEmpty }

    init(
        scope: GitHistoryScope,
        branchName: String?,
        headCommitID: GitCommitID?,
        repositoryHeadCommitID: GitCommitID?? = nil,
        tipCommitIDs: [GitCommitID],
        decorationsByCommitID: [GitCommitID: [GitRefDecoration]],
        remoteOnlyCommitIDs: Set<GitCommitID> = [],
        sortedTags: [GitRefDecoration]? = nil,
        browsedBranch: String? = nil,
        browsedRef: String? = nil,
        browsedWorktree: String? = nil
    ) {
        self.scope = scope
        self.branchName = branchName
        self.headCommitID = headCommitID
        self.repositoryHeadCommitID = repositoryHeadCommitID ?? headCommitID
        self.tipCommitIDs = tipCommitIDs
        self.decorationsByCommitID = decorationsByCommitID
        self.remoteOnlyCommitIDs = remoteOnlyCommitIDs
        self.sortedTags = sortedTags ?? Array(
            Set(decorationsByCommitID.values.joined().filter { $0.kind == .tag })
        ).sorted { $0.name < $1.name }
        self.browsedBranch = browsedBranch
        self.browsedRef = browsedRef
        self.browsedWorktree = browsedWorktree
    }

    /// Computes deduplicated walk tips in deterministic order for the given scope.
    static func tipCommitIDs(
        for scope: GitHistoryScope,
        headCommitID: GitCommitID?,
        decorationsByCommitID: [GitCommitID: [GitRefDecoration]],
        favoriteRefs: Set<String>,
        worktrees: [GitWorktreeInfo]
    ) -> [GitCommitID] {
        var branchRefs: [BranchRef] = []
        if scope != .currentBranch {
            for (commitID, decorations) in decorationsByCommitID {
                for ref in decorations where ref.kind == .currentBranch || ref.kind == .localBranch || ref.kind == .remoteBranch {
                    branchRefs.append(BranchRef(name: ref.name, fullRef: ref.fullRef, id: commitID))
                }
            }
        }

        var tipIDs: [GitCommitID]
        switch scope {
        case .currentBranch:
            tipIDs = headCommitID.map { [$0] } ?? []
        case .favorites:
            tipIDs = branchRefs
                .filter { favoriteRefs.contains($0.fullRef) }
                .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
                .map(\.id)
            if favoriteRefs.contains("HEAD"), let headCommitID {
                tipIDs.append(headCommitID)
            }
            let worktreeHeads = worktrees
                .filter { !$0.isBare && favoriteRefs.contains(GitHistoryBranchFavorites.worktreeID(path: $0.path)) }
                .sorted { $0.path < $1.path }
                .compactMap(\.head)
            tipIDs.append(contentsOf: worktreeHeads)
        case .allBranches:
            tipIDs = branchRefs
                .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
                .map(\.id)
            if let headCommitID {
                tipIDs.append(headCommitID)
            }
        }

        // Keep the order deterministic and avoid asking git to walk the same tip twice.
        var seen = Set<GitCommitID>()
        return tipIDs.filter { seen.insert($0).inserted }
    }

    /// Derives an in-memory snapshot for another scope without re-querying Git refs.
    func recontextualized(
        for scope: GitHistoryScope,
        favoriteRefs: Set<String>,
        worktrees: [GitWorktreeInfo] = []
    ) -> GitHistorySnapshot {
        let tipIDs = Self.tipCommitIDs(
            for: scope,
            headCommitID: repositoryHeadCommitID,
            decorationsByCommitID: decorationsByCommitID,
            favoriteRefs: favoriteRefs,
            worktrees: worktrees
        )
        return GitHistorySnapshot(
            scope: scope,
            branchName: branchName,
            headCommitID: repositoryHeadCommitID,
            repositoryHeadCommitID: repositoryHeadCommitID,
            tipCommitIDs: tipIDs,
            decorationsByCommitID: decorationsByCommitID,
            remoteOnlyCommitIDs: remoteOnlyCommitIDs,
            sortedTags: sortedTags
        )
    }

    /// Derives an in-memory snapshot focused on a single branch or tag ref.
    func browsingBranch(ref: String, branches: [GitBranchInfo]) -> GitHistorySnapshot? {
        if ref.hasPrefix("refs/tags/") {
            guard let commitID = decorationsByCommitID.first(where: {
                $0.value.contains { $0.kind == .tag && $0.fullRef == ref }
            })?.key else {
                return nil
            }
            return GitHistorySnapshot(
                scope: scope,
                branchName: branchName,
                headCommitID: repositoryHeadCommitID,
                repositoryHeadCommitID: repositoryHeadCommitID,
                tipCommitIDs: [commitID],
                decorationsByCommitID: decorationsByCommitID,
                remoteOnlyCommitIDs: remoteOnlyCommitIDs,
                sortedTags: sortedTags,
                browsedBranch: String(ref.dropFirst("refs/tags/".count)),
                browsedRef: ref
            )
        }
        guard let tip = branches.first(where: { $0.id == ref }) else {
            return nil
        }
        return GitHistorySnapshot(
            scope: scope,
            branchName: branchName,
            headCommitID: repositoryHeadCommitID,
            repositoryHeadCommitID: repositoryHeadCommitID,
            tipCommitIDs: [tip.commit],
            decorationsByCommitID: decorationsByCommitID,
            remoteOnlyCommitIDs: remoteOnlyCommitIDs,
            sortedTags: sortedTags,
            browsedBranch: tip.name,
            browsedRef: tip.id
        )
    }

    /// Derives an in-memory snapshot focused on a worktree's current HEAD.
    func browsingWorktree(path: String, worktrees: [GitWorktreeInfo]) -> GitHistorySnapshot? {
        guard let tree = worktrees.first(where: { $0.path == path && !$0.isBare }) else {
            return nil
        }
        return GitHistorySnapshot(
            scope: scope,
            branchName: branchName,
            headCommitID: tree.head,
            repositoryHeadCommitID: repositoryHeadCommitID,
            tipCommitIDs: tree.head.map { [$0] } ?? [],
            decorationsByCommitID: decorationsByCommitID,
            remoteOnlyCommitIDs: remoteOnlyCommitIDs,
            sortedTags: sortedTags,
            browsedBranch: tree.branchRef == nil ? tree.head?.shortSHA ?? GitL10n.text("No commits") : tree.branchName,
            browsedWorktree: path
        )
    }
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

    var statistics: GitDiffStatistics?
}
