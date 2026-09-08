import Foundation

struct GitRepositoryService: Sendable {
    let executor: any GitExecutor

    init(executor: any GitExecutor = LocalGitExecutor()) {
        self.executor = executor
    }

    func resolveStatus(
        workingDirectory: String?,
        session: PaneSessionContext? = nil
    ) async -> GitRepositoryStatusKind {
        // 1. Check for remote SSH sessions
        if let session {
            switch session.state {
            case .sshReady(let ssh, let remoteDir):
                return .ssh(host: ssh.alias, workingDirectory: remoteDir)
            case .sshConnecting(let ssh):
                return .ssh(
                    host: ssh.alias,
                    workingDirectory: session.workingDirectory ?? ""
                )
            case .local:
                break
            }
        }

        // 2. Validate working directory
        guard let directory = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return .notRepository(directory: "")
        }

        guard FileManager.default.fileExists(atPath: directory) else {
            return .notRepository(directory: directory)
        }

        // 3. Query repository identity
        do {
            let result = try await executor.execute(
                arguments: [
                    "rev-parse",
                    "--path-format=absolute",
                    "--is-inside-work-tree",
                    "--show-toplevel",
                    "--git-dir",
                    "--git-common-dir",
                ],
                workingDirectory: directory,
                stdin: nil,
                maxOutputBytes: 64 * 1024
            )

            guard result.isSuccess else {
                return .notRepository(directory: directory)
            }

            let lines = result.stdoutString
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            guard lines.count >= 4, lines[0] == "true" else {
                return .notRepository(directory: directory)
            }

            let worktreePath = lines[1]
            let gitDir = lines[2]
            let commonGitDir = lines[3]

            let identity = GitRepositoryIdentity(
                target: .local,
                worktreePath: worktreePath,
                gitDirPath: gitDir,
                commonGitDirPath: commonGitDir
            )

            // 4. Resolve HEAD and branch state
            return await resolveHeadState(for: identity)
        } catch let error as GitExecutionError {
            switch error {
            case .cancelled:
                return .error(title: "Cancelled", message: "Git check was cancelled")
            case .processFailed, .executionFailed, .outputLimitExceeded:
                return .notRepository(directory: directory)
            }
        } catch {
            return .error(title: "Git Error", message: error.localizedDescription)
        }
    }

    private func resolveHeadState(
        for identity: GitRepositoryIdentity
    ) async -> GitRepositoryStatusKind {
        do {
            async let branchResult = executor.execute(
                arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
                workingDirectory: identity.worktreePath,
                stdin: nil,
                maxOutputBytes: 16 * 1024
            )
            async let headResult = executor.execute(
                arguments: ["rev-parse", "--quiet", "--verify", "HEAD"],
                workingDirectory: identity.worktreePath,
                stdin: nil,
                maxOutputBytes: 16 * 1024
            )

            let (branchExec, headExec) = try await (branchResult, headResult)

            let headCommitID: GitCommitID? = if headExec.isSuccess {
                GitCommitID(headExec.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                nil
            }

            if branchExec.isSuccess {
                let branchName = branchExec.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if let headCommitID {
                    return .ready(
                        repository: identity,
                        branch: branchName,
                        headCommitID: headCommitID
                    )
                } else {
                    return .unborn(repository: identity, branch: branchName)
                }
            } else {
                // Detached HEAD
                if let headCommitID {
                    return .detached(repository: identity, commitID: headCommitID)
                } else {
                    return .unborn(repository: identity, branch: "HEAD")
                }
            }
        } catch {
            return .error(title: "Head Resolution Error", message: error.localizedDescription)
        }
    }
}
