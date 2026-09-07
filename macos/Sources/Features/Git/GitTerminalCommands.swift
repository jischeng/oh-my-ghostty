import Foundation

enum GitDiffScope: Equatable, Sendable {
    case staged
    case unstaged
}

/// A typed request for a Git command to be entered into the terminal.
///
/// The repository identity is carried by every intent so a command cannot
/// accidentally fall back to the process' current working directory.
enum GitTerminalCommandIntent: Equatable, Sendable {
    case status(repository: GitRepositoryIdentity)
    case log(repository: GitRepositoryIdentity)
    case show(repository: GitRepositoryIdentity, commit: GitCommitID)
    case diff(repository: GitRepositoryIdentity, scope: GitDiffScope, file: String)
    case switchBranch(repository: GitRepositoryIdentity, branch: String)
    case commit(repository: GitRepositoryIdentity, message: String)

    var repository: GitRepositoryIdentity {
        switch self {
        case .status(let repository),
             .log(let repository),
             .show(let repository, _),
             .diff(let repository, _, _),
             .switchBranch(let repository, _),
             .commit(let repository, _):
            repository
        }
    }
}

struct GitTerminalCommand: Equatable, Sendable {
    let argv: [String]

    var shellCommand: String {
        GitShellQuoting.commandLine(for: argv)
    }

}

enum GitTerminalCommandFormatter {
    static func format(_ intent: GitTerminalCommandIntent) -> GitTerminalCommand {
        let repository = intent.repository

        switch intent {
        case .status:
            return GitTerminalCommand(argv: [
                "git", "-C", repository.worktreePath, "status", "--short", "--branch",
            ])

        case .log:
            return GitTerminalCommand(argv: [
                "git", "-C", repository.worktreePath, "log", "--oneline", "--decorate", "--graph",
            ])

        case .show(_, let commit):
            return GitTerminalCommand(argv: ["git", "-C", repository.worktreePath, "show", commit.rawValue])

        case .diff(_, let scope, let file):
            let scopeFlag: String?
            switch scope {
            case .staged:
                scopeFlag = "--cached"
            case .unstaged:
                scopeFlag = nil
            }
            var argv = ["git", "-C", repository.worktreePath, "--literal-pathspecs", "diff"]
            if let scopeFlag { argv.append(scopeFlag) }
            argv += ["--", file]
            return GitTerminalCommand(argv: argv)

        case .switchBranch(_, let branch):
            return GitTerminalCommand(argv: ["git", "-C", repository.worktreePath, "switch", "--", branch])

        case .commit(_, let message):
            return GitTerminalCommand(argv: ["git", "-C", repository.worktreePath, "commit", "-m", message, "--"])
        }
    }

}

/// POSIX shell single-quote escaping shared by every Git terminal command.
/// Newlines remain inside the quoted argument, which preserves multi-line
/// commit messages while keeping shell metacharacters inert.
enum GitShellQuoting {
    static func commandLine(for argv: [String]) -> String {
        argv.map(quoteIfNeeded).joined(separator: " ")
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122,
                       37, 43, 44, 45, 46, 47, 58, 61, 64, 95:
                      true
                  default:
                      false
                  }
              }) else {
            return quote(value)
        }
        return value
    }
}
