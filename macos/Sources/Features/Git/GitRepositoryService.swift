import Foundation

struct GitRepositoryService: Sendable {
    let executor: (any GitExecutor)?

    init(executor: (any GitExecutor)? = nil) {
        self.executor = executor
    }

    func resolveStatus(
        workingDirectory: String?,
        session: PaneSessionContext? = nil
    ) async -> GitRepositoryStatusKind {
        if let session, case .sshConnecting(let ssh) = session.state {
            return .ssh(host: ssh.alias, workingDirectory: "")
        }
        let target: GitExecutionTarget
        do { target = try session.map { try GitExecutionTarget(session: $0) } ?? .local } catch { return .error(title: "SSH Git", message: error.localizedDescription) }
        let command = executor ?? target.executor

        // 2. Validate working directory
        guard let directory = workingDirectory,
              !directory.isEmpty else {
            return .notRepository(directory: "")
        }

        guard directory.hasPrefix("/"), !directory.contains("\0"),
              !directory.contains("\n"), !directory.contains("\r") else {
            return .error(title: "Git Path", message: "Repository directories must be absolute paths without line breaks.")
        }
        guard target != .local || FileManager.default.fileExists(atPath: directory) else {
            return .notRepository(directory: directory)
        }

        // 3. Query repository identity
        do {
            let result = try await command.execute(
                arguments: [
                    "rev-parse",
                    "--is-inside-work-tree",
                    "--show-toplevel",
                    "--absolute-git-dir",
                    "--git-common-dir",
                    "--show-prefix",
                ],
                workingDirectory: directory,
                stdin: nil,
                maxOutputBytes: 64 * 1024
            )

            guard result.isSuccess else {
                if result.stderrString.contains("not a git repository") { return .notRepository(directory: directory) }
                return .error(title: "Git Error", message: result.stderrString.isEmpty ? "Git repository check failed." : result.stderrString)
            }

            let lines = result.stdoutString
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

            guard lines.count == 6, lines[0] == "true", lines[1].hasPrefix("/"), lines[2].hasPrefix("/"),
                  lines.allSatisfy({ !$0.contains("\r") && !$0.contains("\0") }) else {
                return .error(title: "Git Path", message: "Git returned unsupported repository paths. Use Git 2.23+ and a repository root without line breaks.")
            }

            let worktreePath = lines[1]
            let gitDir = lines[2]
            let prefix = lines.count > 4 ? lines[4] : ""
            let commonGitDir = Self.absolutePath(lines[3], relativeTo: worktreePath + "/" + prefix)

            let identity = GitRepositoryIdentity(
                target: target,
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
                return .error(title: target == .local ? "Git Error" : "SSH Git Error", message: error.localizedDescription)
            }
        } catch {
            return .error(title: "Git Error", message: error.localizedDescription)
        }
    }

    /// Git paths must be normalized lexically, never through the Mac filesystem
    /// when the repository belongs to an SSH endpoint.
    static func absolutePath(_ path: String, relativeTo directory: String) -> String {
        let absolute = path.hasPrefix("/") ? path : directory + "/" + path
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private func resolveHeadState(
        for identity: GitRepositoryIdentity
    ) async -> GitRepositoryStatusKind {
        do {
            async let branchResult = (executor ?? identity.executor).execute(
                arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
                workingDirectory: identity.worktreePath,
                stdin: nil,
                maxOutputBytes: 16 * 1024
            )
            async let headResult = (executor ?? identity.executor).execute(
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
