import Foundation

struct GitCommitID: Hashable, Sendable, Equatable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    var shortSHA: String {
        String(rawValue.prefix(7))
    }
}

struct GitRepositoryIdentity: Hashable, Sendable, Equatable {
    let target: GitExecutionTarget
    let worktreePath: String
    let gitDirPath: String
    let commonGitDirPath: String

    var repositoryName: String {
        let name = URL(fileURLWithPath: worktreePath).lastPathComponent
        return name.isEmpty ? worktreePath : name
    }

    init(
        target: GitExecutionTarget = .local,
        worktreePath: String,
        gitDirPath: String,
        commonGitDirPath: String
    ) {
        self.target = target
        self.worktreePath = worktreePath
        self.gitDirPath = gitDirPath
        self.commonGitDirPath = commonGitDirPath
    }
}

enum GitHead: Hashable, Sendable, Equatable {
    case branch(String)
    case detached(commitID: GitCommitID)
    case unborn(branch: String)

    var displayName: String {
        switch self {
        case .branch(let name):
            name
        case .detached(let commitID):
            "detached at \(commitID.shortSHA)"
        case .unborn(let branch):
            "\(branch) (no commits)"
        }
    }

    var branchName: String? {
        switch self {
        case .branch(let name), .unborn(let name):
            name
        case .detached:
            nil
        }
    }
}

enum GitRepositoryStatusKind: Equatable, Sendable {
    case notRepository(directory: String)
    case unborn(repository: GitRepositoryIdentity, branch: String)
    case detached(repository: GitRepositoryIdentity, commitID: GitCommitID)
    case ready(repository: GitRepositoryIdentity, branch: String, headCommitID: GitCommitID?)
    case ssh(host: String, workingDirectory: String)
    case error(title: String, message: String)

    var repository: GitRepositoryIdentity? {
        switch self {
        case .unborn(let repo, _),
             .detached(let repo, _),
             .ready(let repo, _, _):
            repo
        case .notRepository, .ssh, .error:
            nil
        }
    }

    var headDescription: String? {
        switch self {
        case .ready(_, let branch, _):
            branch
        case .unborn(_, let branch):
            "\(branch) (initial)"
        case .detached(_, let commitID):
            "detached at \(commitID.shortSHA)"
        case .notRepository, .ssh, .error:
            nil
        }
    }
}

struct GitRepositoryContext: Equatable, Sendable {
    let identity: GitRepositoryIdentity
    let head: GitHead
    let headCommitID: GitCommitID?

    init(
        identity: GitRepositoryIdentity,
        head: GitHead,
        headCommitID: GitCommitID? = nil
    ) {
        self.identity = identity
        self.head = head
        self.headCommitID = headCommitID
    }
}
