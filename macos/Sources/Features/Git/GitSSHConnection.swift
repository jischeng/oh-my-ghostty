import Foundation

struct GitSSHConnection: Hashable, Sendable {
    let destination: String
    let options: [String]
    let workspaceID: String
    let executablePath: String

    init(destination: String, options: [String] = [], workspaceID: String? = nil, executablePath: String = "/usr/bin/ssh") throws {
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              !destination.contains(where: { $0.isWhitespace || $0 == "\0" }),
              options.allSatisfy({ !$0.contains("\0") }),
              !(workspaceID ?? "").contains("\0"), executablePath.hasPrefix("/"),
              !executablePath.contains("\0") else {
            throw GitExecutionError.executionFailed("Invalid SSH connection.")
        }
        self.executablePath = executablePath
        self.destination = destination
        self.options = options
        self.workspaceID = workspaceID ?? "ssh:\(destination)"
    }

    init(session: PaneSessionContext.SSH) throws {
        guard session.replay != nil else {
            throw GitExecutionError.executionFailed("Exact SSH options are unavailable. Reconnect this SSH session to capture its original connection parameters.")
        }
        var options: [String] = []
        var executablePath = "/usr/bin/ssh"
        if let replay = session.replay {
            guard replay.version == 1, replay.ssh == "ssh" || (replay.ssh.hasPrefix("/") && (replay.ssh as NSString).lastPathComponent == "ssh"),
                  replay.transferTarget == session.transferTarget else {
                throw GitExecutionError.executionFailed("Git requires a replayable OpenSSH connection.")
            }
            executablePath = replay.ssh == "ssh" ? "/usr/bin/ssh" : replay.ssh
            let takesValue: Set<String> = ["-B", "-I", "-P", "-p", "-l", "-i", "-F", "-J", "-S", "-b", "-c", "-m", "-o"]
            let skipsValue: Set<String> = ["-L", "-R", "-D", "-E", "-e"]
            var index = 0
            while index < replay.args.count {
                let arg = replay.args[index]
                if arg == session.transferTarget { break }
                if takesValue.contains(arg) || skipsValue.contains(arg) {
                    guard index + 1 < replay.args.count else { throw GitExecutionError.executionFailed("Incomplete SSH option.") }
                    if takesValue.contains(arg) { options += [arg, replay.args[index + 1]] }
                    index += 2
                } else if arg.count > 2, takesValue.contains(String(arg.prefix(2))) {
                    options += [String(arg.prefix(2)), String(arg.dropFirst(2))]
                    index += 1
                } else {
                    if arg.hasPrefix("-"), arg.dropFirst().allSatisfy({ "46AaCvqtxXYy".contains($0) }) {
                        options += arg.dropFirst().filter { "46AaC".contains($0) }.map { "-" + String($0) }
                    }
                    index += 1
                }
            }
        }
        try self.init(destination: session.transferTarget, options: options, workspaceID: "ssh:\(session.alias)", executablePath: executablePath)
    }

    var identity: String { ([destination, workspaceID, executablePath] + options).joined(separator: "\0") }
    var arguments: [String] {
        // These options precede user config/replay options: OpenSSH uses the first value.
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
         "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "SessionType=default",
         "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "StdinNull=no",
         "-o", "ControlMaster=no", "-o", "ControlPersist=no"] + options + ["--", destination]
    }
}

struct SSHGitExecutor: GitExecutor {
    let connection: GitSSHConnection
    var sshPath: String?
    static let marker = Data("\u{1e}OMG-GIT-v1\u{1f}".utf8)

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw GitExecutionError.executionFailed("Invalid remote Git path or argument.")
        }
        let command = "cd " + Self.quote(workingDirectory) + " || exit; " +
            "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; " +
            "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; " +
            "exec env LC_ALL=C GIT_TERMINAL_PROMPT=0 git " + arguments.map(Self.quote).joined(separator: " ")
        return try await run(command, stdin: stdin, limit: maxOutputBytes)
    }

    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data {
        guard path.hasPrefix("/"), root.hasPrefix("/"), !path.contains("\0"), !root.contains("\0") else {
            throw GitExecutionError.executionFailed("Invalid remote file path.")
        }
        let script = """
        file=\(Self.quote(path))
        root=$(cd \(Self.quote(root)) && pwd -P) || exit
        parent=$(cd "${file%/*}" && pwd -P) || exit
        root=${root%/}
        case "$parent" in "$root"|"$root"/*) ;; *) echo 'File is outside this worktree.' >&2; exit 1;; esac
        if [ -L "$file" ] || [ ! -f "$file" ]; then echo 'Use patch view for symlinks or non-regular files.' >&2; exit 1; fi
        exec head -c \(limit + 1) "$file"
        """
        let result = try await run(script, stdin: nil, limit: limit + 1)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        guard result.stdout.count <= limit else { throw GitExecutionError.outputLimitExceeded(maxBytes: limit) }
        return result.stdout
    }

    private func run(_ script: String, stdin: Data?, limit: Int?) async throws -> GitExecutionResult {
        let framed = "printf '\\036OMG-GIT-v1\\037'; " + script
        // Only a quote-free base64 alphabet crosses the login shell. The
        // decoded POSIX script is a -c argument, leaving SSH stdin for git commit.
        let encoded = Data(framed.utf8).base64EncodedString()
        let command = "exec /bin/sh -c 'exec /bin/sh -c \"$(printf %s " + encoded + " | base64 -d)\"'"
        let result = try await LocalGitExecutor(gitPath: sshPath ?? connection.executablePath, prefixArguments: connection.arguments,
                                                localWorkingDirectory: "/").execute(
            arguments: [command], workingDirectory: "/", stdin: stdin,
            maxOutputBytes: limit.map { $0 + 64 * 1024 }
        )
        guard result.exitCode != 255 else {
            throw GitExecutionError.executionFailed("SSH connection failed. If a write was in progress, refresh before retrying; its outcome may be unknown.\n" + result.stderrString)
        }
        guard let marker = result.stdout.range(of: Self.marker) else {
            throw GitExecutionError.executionFailed("SSH did not start the Git command.\n" + result.stderrString)
        }
        let output = Data(result.stdout[marker.upperBound...])
        if let limit, output.count > limit { throw GitExecutionError.outputLimitExceeded(maxBytes: limit) }
        return GitExecutionResult(exitCode: result.exitCode, stdout: output, stderr: result.stderr)
    }
}

struct UnavailableGitExecutor: GitExecutor {
    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        throw GitExecutionError.executionFailed("Invalid SSH target.")
    }
    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data {
        throw GitExecutionError.executionFailed("Invalid SSH target.")
    }
}
