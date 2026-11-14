import Foundation

/// Caps concurrent auxiliary SSH/SFTP sessions per ControlMaster socket or host
/// identity so bursty Git + Inspector + Quick Open refreshes never trip OpenSSH's
/// default `MaxSessions 10` limit on a shared multiplexed connection.
actor SSHConnectionConcurrencyLimiter {
    static let defaultMaxConcurrentPerConnection = 4

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    let maxConcurrentPerConnection: Int
    private var activeCounts: [String: Int] = [:]
    private var maxObservedCounts: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var preCancelledWaiters: Set<UUID> = []

    init(maxConcurrentPerConnection: Int = SSHConnectionConcurrencyLimiter.defaultMaxConcurrentPerConnection) {
        self.maxConcurrentPerConnection = max(1, maxConcurrentPerConnection)
    }

    func withPermit<T: Sendable>(
        for connectionKey: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(for: connectionKey)
        defer { release(for: connectionKey) }
        try Task.checkCancellation()
        return try await operation()
    }

    func activeConcurrency(for connectionKey: String) -> Int {
        activeCounts[connectionKey] ?? 0
    }

    func maxObservedConcurrency(for connectionKey: String) -> Int {
        maxObservedCounts[connectionKey] ?? 0
    }

    private func acquire(for key: String) async throws {
        try Task.checkCancellation()
        let current = activeCounts[key] ?? 0
        if current < maxConcurrentPerConnection {
            let next = current + 1
            activeCounts[key] = next
            if next > (maxObservedCounts[key] ?? 0) {
                maxObservedCounts[key] = next
            }
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || preCancelledWaiters.remove(waiterID) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[key, default: []].append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: key) }
        }
    }

    private func release(for key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let nextWaiter = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            nextWaiter.continuation.resume(returning: ())
            return
        }

        let remaining = (activeCounts[key] ?? 1) - 1
        if remaining <= 0 {
            activeCounts.removeValue(forKey: key)
        } else {
            activeCounts[key] = remaining
        }
    }

    private func cancelWaiter(id: UUID, for key: String) {
        if var queue = waiters[key],
           let index = queue.firstIndex(where: { $0.id == id }) {
            let removed = queue.remove(at: index)
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            removed.continuation.resume(throwing: CancellationError())
        } else {
            preCancelledWaiters.insert(id)
        }
    }
}

/// Shared bounded IO and exact-connection multiplexing for Git, files and inventory.
enum SSHSessionTransport {
    static let connectionLimiter = SSHConnectionConcurrencyLimiter()

    static func connectionLimiterKey(socket: String?, connection: GitSSHConnection) -> String {
        if let socket, !socket.isEmpty {
            return "socket:\(socket)"
        }
        return "conn:\(connection.identity)"
    }

    static func shellCommand(_ script: String) -> String {
        // Keep nested quotes/newlines out of the user's login shell (including
        // fish). SSH stdin remains available for the actual command payload.
        let encoded = Data(script.utf8).base64EncodedString()
        return "exec /bin/sh -c 'exec /bin/sh -c \"$(printf %s " + encoded + " | base64 -d)\"'"
    }
    static func run(connection: GitSSHConnection, command: String, stdin: Data? = nil,
                    limit: Int? = 1_048_576, timeout: TimeInterval = 60,
                    executable: String? = nil, multiplexing: Bool = true) async throws -> GitExecutionResult {
        let executable = executable ?? connection.executablePath
        let socket = multiplexing ? try GitSSHControlSocket.path(for: connection, executablePath: executable) : nil
        // All auxiliary shell tasks enter through the same remote OMG runtime.
        // Plain SSH hosts without bootstrap retain their existing behavior.
        let routedCommand = shellCommand("""
        if [ -f "$HOME/.local/share/oh-my-ghostty/remote/omg" ] && command -v python3 >/dev/null 2>&1; then
          exec python3 "$HOME/.local/share/oh-my-ghostty/remote/omg" exec \(Ghostty.Shell.quote(command))
        fi
        exec /bin/sh -c \(Ghostty.Shell.quote(command))
        """)
        let limiterKey = connectionLimiterKey(socket: socket, connection: connection)
        return try await connectionLimiter.withPermit(for: limiterKey) {
            try await GitProcessRunner().run(
                executablePath: executable,
                arguments: connection.arguments(controlSocket: socket) + [routedCommand],
                workingDirectory: connection.localWorkingDirectory,
                stdin: stdin,
                maxOutputBytes: limit,
                timeout: timeout
            )
        }
    }

    static func python(_ script: String, connection: GitSSHConnection, loginShell: Bool = false) async throws -> Data {
        let remote = loginShell
            ? shellCommand("exec \"${SHELL:-/bin/sh}\" -lic 'exec python3 -'")
            : "exec python3 -"
        let result = try await run(connection: connection, command: remote,
            stdin: Data(("print('OMG_AGENT_RESULT_BEGIN', flush=True)\n" + script).utf8), timeout: 360)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        guard let marker = result.stdoutString.range(of: "OMG_AGENT_RESULT_BEGIN\n") else {
            throw AgentHistoryRemoteError.unavailable
        }
        return Data(result.stdoutString[marker.upperBound...].utf8)
    }

    static func sftp(batch: String, connection: GitSSHConnection) async throws -> String {
        let socket = try GitSSHControlSocket.path(for: connection, executablePath: connection.executablePath)
        let limiterKey = connectionLimiterKey(socket: socket, connection: connection)
        return try await connectionLimiter.withPermit(for: limiterKey) {
            // sftp's -S adapter preserves SSH options without confusing ssh -p/-l
            // with sftp's unrelated flags. Each call owns its temporary adapter.
            let adapter = URL(fileURLWithPath: socket + ".\(UUID().uuidString).sh")
            let arguments = connection.arguments(controlSocket: socket).dropLast(2)
                .map { $0 == "SessionType=default" ? "SessionType=subsystem" : $0 }
            // OpenSSH rejects an explicit SessionType together with sftp's -s.
            // Select the subsystem ourselves and remove just that generated flag.
            let filter = """
            #!/bin/sh
            omg_count=$#
            while [ "$omg_count" -gt 0 ]; do
              omg_arg=$1
              shift
              [ "$omg_arg" = '-s' ] || set -- "$@" "$omg_arg"
              omg_count=$((omg_count - 1))
            done
            """
            let script = filter + "\nexec " + ([connection.executablePath] + arguments)
                .map(Ghostty.Shell.quote).joined(separator: " ") + " \"$@\"\n"
            guard FileManager.default.createFile(atPath: adapter.path, contents: Data(script.utf8),
                                                attributes: [.posixPermissions: 0o700]) else {
                throw WorkspaceFilesystemError.unavailable
            }
            defer { try? FileManager.default.removeItem(at: adapter) }
            let result = try await GitProcessRunner().run(
                executablePath: "/usr/bin/sftp",
                arguments: ["-q", "-S", adapter.path, "-b", "-", "--", connection.destination],
                workingDirectory: connection.localWorkingDirectory,
                environment: ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"], uniquingKeysWith: { _, value in value }),
                stdin: Data((batch + "\n").utf8),
                timeout: 60
            )
            guard result.isSuccess else { throw WorkspaceFilesystemError.commandFailed(result.exitCode, result.stderrString) }
            return result.stdoutString
        }
    }

    static func close(_ connection: GitSSHConnection) async {
        guard let socket = try? GitSSHControlSocket.path(for: connection, executablePath: connection.executablePath) else { return }
        _ = try? await GitProcessRunner().run(executablePath: connection.executablePath,
            arguments: ["-S", socket, "-O", "exit", "--", connection.destination],
            workingDirectory: connection.localWorkingDirectory, timeout: 3)
    }
}
