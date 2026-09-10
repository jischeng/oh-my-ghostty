import Foundation

struct GitExecutionResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    var stdoutString: String {
        String(bytes: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(bytes: stderr, encoding: .utf8) ?? ""
    }

    var isSuccess: Bool {
        exitCode == 0
    }
}

enum GitExecutionError: Error, Sendable, Equatable, LocalizedError {
    case processFailed(exitCode: Int32, stderr: String)
    case outputLimitExceeded(maxBytes: Int)
    case cancelled
    case timedOut
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? GitL10n.format("Git command exited with code {0}", String(describing: code)) : trimmed
        case .outputLimitExceeded(let maxBytes):
            return GitL10n.format("Git command output exceeded limit of {0} bytes", String(describing: maxBytes))
        case .timedOut:
            return GitL10n.text("Git command timed out. Refresh before retrying; a write may have completed remotely.")
        case .cancelled:
            return GitL10n.text("Git command was cancelled")
        case .executionFailed(let reason):
            return GitL10n.format("Failed to execute Git command: {0}", String(describing: reason))
        }
    }
}

protocol GitExecutor: Sendable {
    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data
    func execute(
        arguments: [String],
        workingDirectory: String,
        stdin: Data?,
        maxOutputBytes: Int?
    ) async throws -> GitExecutionResult
}

extension GitExecutor {
    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data {
        throw GitExecutionError.executionFailed(GitL10n.text("Working-file reads are unavailable for this executor."))
    }

    func execute(
        arguments: [String],
        workingDirectory: String,
        stdin: Data? = nil,
        maxOutputBytes: Int? = 10 * 1024 * 1024
    ) async throws -> GitExecutionResult {
        try await execute(
            arguments: arguments,
            workingDirectory: workingDirectory,
            stdin: stdin,
            maxOutputBytes: maxOutputBytes
        )
    }
}

struct LocalGitExecutor: GitExecutor {
    private let gitPath: String?

    init(gitPath: String? = nil) { self.gitPath = gitPath }

    func execute(arguments: [String], workingDirectory: String, stdin: Data? = nil,
                 maxOutputBytes: Int? = 10 * 1024 * 1024) async throws -> GitExecutionResult {
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.contains("/opt/homebrew/bin") && !path.contains("/usr/local/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C.UTF-8"
        return try await GitProcessRunner().run(
            executablePath: gitPath ?? "/usr/bin/env",
            arguments: gitPath == nil ? ["git"] + arguments : arguments,
            workingDirectory: workingDirectory, environment: environment,
            stdin: stdin, maxOutputBytes: maxOutputBytes
        )
    }

    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let boundary = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
        guard path.hasPrefix("/"), url.resolvingSymlinksInPath().path.hasPrefix(boundary),
              try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true else {
            throw GitExecutionError.executionFailed(GitL10n.text("Use patch view for files outside this worktree or non-regular files."))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw GitExecutionError.outputLimitExceeded(maxBytes: limit) }
        return data
    }

}
