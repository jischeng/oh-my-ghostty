import Darwin
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
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Git command exited with code \(code)" : trimmed
        case .outputLimitExceeded(let maxBytes):
            return "Git command output exceeded limit of \(maxBytes) bytes"
        case .cancelled:
            return "Git command was cancelled"
        case .executionFailed(let reason):
            return "Failed to execute Git command: \(reason)"
        }
    }
}

enum GitExecutionTarget: Hashable, Sendable, Equatable {
    case local
    case remote(host: String, user: String?)
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
        let url = URL(fileURLWithPath: path)
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let boundary = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
        guard path.hasPrefix("/"), url.resolvingSymlinksInPath().path.hasPrefix(boundary),
              try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true else {
            throw GitExecutionError.executionFailed("Use patch view for files outside this worktree or non-regular files.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw GitExecutionError.outputLimitExceeded(maxBytes: limit) }
        return data
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

final class LocalGitExecutor: GitExecutor {
    private let gitPath: String?
    private let prefixArguments: [String]
    private let localWorkingDirectory: String?

    init(gitPath: String? = nil, prefixArguments: [String] = [], localWorkingDirectory: String? = nil) {
        self.gitPath = gitPath
        self.prefixArguments = prefixArguments
        self.localWorkingDirectory = localWorkingDirectory
    }

    func execute(
        arguments: [String],
        workingDirectory: String,
        stdin: Data? = nil,
        maxOutputBytes: Int? = 10 * 1024 * 1024
    ) async throws -> GitExecutionResult {
        try Task.checkCancellation()

        let process = Process()
        if let explicit = gitPath {
            process.executableURL = URL(fileURLWithPath: explicit)
            process.arguments = prefixArguments + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: localWorkingDirectory ?? workingDirectory)

        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let preferredPrefix = "/opt/homebrew/bin:/usr/local/bin"
        if !existingPath.contains("/opt/homebrew/bin") && !existingPath.contains("/usr/local/bin") {
            env["PATH"] = "\(preferredPrefix):\(existingPath)"
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C.UTF-8"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdin != nil ? stdinPipe : FileHandle.nullDevice
        if stdin != nil {
            // An SSH connection can fail before consuming its input. Treat a
            // closed pipe as a write error rather than delivering SIGPIPE.
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        let state = ProcessOutputState(maxOutputBytes: maxOutputBytes)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.appendStdout(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.appendStderr(data)
        }

        return try await withTaskCancellationHandler {
            do {
                try process.run()
                if let stdinData = stdin {
                    try? stdinPipe.fileHandleForReading.close()
                    Task.detached {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                throw GitExecutionError.executionFailed(error.localizedDescription)
            }

            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingOut.isEmpty {
                state.appendStdout(remainingOut)
            }
            let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingErr.isEmpty {
                state.appendStderr(remainingErr)
            }

            if Task.isCancelled {
                throw GitExecutionError.cancelled
            }

            if state.isExceeded {
                throw GitExecutionError.outputLimitExceeded(maxBytes: maxOutputBytes ?? 0)
            }

            return GitExecutionResult(
                exitCode: process.terminationStatus,
                stdout: state.stdout,
                stderr: state.stderr
            )
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class ProcessOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let maxOutputBytes: Int?
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private(set) var isExceeded = false

    init(maxOutputBytes: Int?) {
        self.maxOutputBytes = maxOutputBytes
    }

    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let max = maxOutputBytes {
            let current = stdout.count + stderr.count
            if current + data.count > max {
                isExceeded = true
                let remaining = max - current
                if remaining > 0 {
                    stdout.append(data.prefix(remaining))
                }
                return
            }
        }
        stdout.append(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let max = maxOutputBytes {
            let current = stdout.count + stderr.count
            if current + data.count > max {
                isExceeded = true
                let remaining = max - current
                if remaining > 0 {
                    stderr.append(data.prefix(remaining))
                }
                return
            }
        }
        stderr.append(data)
    }
}
