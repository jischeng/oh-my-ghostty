import Foundation

enum AgentHistoryRemoteError: Error, Equatable {
    case invalidHome
    case invalidPath
    case unavailable
}

struct AgentHistoryRemoteFile: Equatable, Sendable {
    let path: String
    let size: Int
    let modifiedAt: Date
}

struct AgentHistoryRemoteChunk: Equatable, Sendable {
    let file: AgentHistoryRemoteFile
    let headerData: Data
}

/// Reads an Agent's session store on a remote host through portable SSH
/// commands with stdout captured. This mirrors the existing in-tree SSH helpers
/// (BatchMode, bounded timeouts) and never owns keys, passwords, or known_hosts.
struct AgentHistoryRemoteAccess: Sendable {
    let alias: String
    let runCommand: @Sendable (String) async throws -> String

    init(alias: String) {
        self.alias = alias
        self.runCommand = { command in
            try await AgentHistoryRemoteAccess.executeSSH(
                alias: alias,
                command: command
            )
        }
    }

    init(
        alias: String,
        runCommand: @escaping @Sendable (String) async throws -> String
    ) {
        self.alias = alias
        self.runCommand = runCommand
    }

    func remoteHome() async throws -> String {
        let output = try await runCommand("printf '%s' \"$HOME\"")
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"),
              home.utf8.count <= 4_096,
              !home.contains("\0"),
              !home.contains("\n") else {
            throw AgentHistoryRemoteError.invalidHome
        }
        return home
    }

    /// Discovers agent session files and reads their headers in a single remote
    /// batch command over SSH. Existing directories are checked first so that
    /// missing agent directories on the remote host never cause `find` to fail
    /// or exit with a non-zero status.
    func discoverSessions(
        relativeRoots: [String],
        maximumSessions: Int
    ) async throws -> [AgentHistoryRemoteChunk] {
        let safeRoots = relativeRoots.filter { !$0.isEmpty && !$0.contains("'") }
        guard !safeRoots.isEmpty else { return [] }
        let boundedLimit = min(max(maximumSessions, 1), 500)
        let rootsList = safeRoots.map { "'\($0)'" }.joined(separator: " ")
        let script = """
        LC_ALL=C
        export LC_ALL
        dirs=""
        for rel in \(rootsList); do
          d="$HOME/$rel"
          [ -d "$d" ] && dirs="$dirs \\"$d\\""
        done
        [ -z "$dirs" ] && exit 0
        eval "find $dirs -type f -name '*.jsonl' -exec ls -t {} + 2>/dev/null" | head -n \(boundedLimit) | while IFS= read -r f; do
          [ -f "$f" ] || continue
          info=$(ls -ld "$f" 2>/dev/null)
          printf "\\n===OMG_FILE===%s\\n" "$info"
          head -c 32768 "$f" 2>/dev/null | sed '$d'
          printf "\\n===OMG_END===\\n"
        done
        """
        let output = try await runCommand(script)
        return Self.parseBatchStream(output)
    }

    func read(path: String, maximumBytes: Int) async throws -> Data {
        guard Self.validRemotePath(path), maximumBytes > 0 else {
            throw AgentHistoryRemoteError.invalidPath
        }
        let command = "head -c \(maximumBytes) \(Self.shellQuote(path)) 2>/dev/null | sed '$d'"
        let output = try await runCommand(command)
        return Data(output.utf8)
    }

    static func parseBatchStream(_ output: String) -> [AgentHistoryRemoteChunk] {
        var results: [AgentHistoryRemoteChunk] = []
        let parts = output.components(separatedBy: "===OMG_FILE===")
        for part in parts where !part.isEmpty {
            guard let endRange = part.range(of: "\n===OMG_END===") ?? part.range(of: "===OMG_END===") else {
                continue
            }
            let body = String(part[..<endRange.lowerBound])
            guard let newlineIndex = body.firstIndex(of: "\n") else { continue }
            let lsLine = String(body[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
            let headerText = String(body[body.index(after: newlineIndex)...])
            guard let file = parseLongListingLine(lsLine) else { continue }
            results.append(.init(file: file, headerData: Data(headerText.utf8)))
        }
        return results
    }

    /// Parses a single `ls -ld` long listing produced by `ls -ld`.
    static func parseLongListingLine(_ line: String) -> AgentHistoryRemoteFile? {
        guard line.count > 10, line.first != "t" else { return nil }
        let columns = line.split(
            maxSplits: 8,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard columns.count == 9 else { return nil }
        guard let size = Int(columns[4]) else { return nil }
        let name = String(columns[8])
        guard validRemotePath(name) else { return nil }
        let month = String(columns[5])
        let day = String(columns[6])
        let time = String(columns[7])

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        var date: Date?
        if time.contains(":") {
            formatter.dateFormat = "MMM dd HH:mm"
            let parsed = formatter.date(from: "\(month) \(day) \(time)")
            if let parsed, parsed > Date().addingTimeInterval(60) {
                formatter.dateFormat = "MMM dd yyyy"
                date = formatter.date(from: "\(month) \(day) \(time)")
            } else {
                date = parsed
            }
        } else {
            formatter.dateFormat = "MMM dd yyyy"
            date = formatter.date(from: "\(month) \(day) \(time)")
        }

        return .init(
            path: name,
            size: size,
            modifiedAt: date ?? .distantPast
        )
    }

    static func parseLongListings(_ output: String) -> [AgentHistoryRemoteFile] {
        output.split(whereSeparator: \.isNewline)
            .compactMap { parseLongListingLine(String($0)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func validRemotePath(_ path: String) -> Bool {
        path.hasPrefix("/") &&
            !path.isEmpty &&
            path.utf8.count <= 4_096 &&
            !path.contains("\0") &&
            !path.contains("\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func executeSSH(
        alias: String,
        command: String
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let remoteCommand = "exec /bin/sh -c \(shellQuote(command))"
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            alias,
            remoteCommand,
        ]
        process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("omg-agent-history-\(UUID().uuidString).out")
                guard FileManager.default.createFile(
                    atPath: outputURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ), let output = try? FileHandle(forWritingTo: outputURL) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                defer {
                    try? output.close()
                    try? FileManager.default.removeItem(at: outputURL)
                }
                process.standardOutput = output
                do {
                    try process.run()
                } catch {
                    throw AgentHistoryRemoteError.unavailable
                }
                let timeout = Task.detached {
                    try? await Task.sleep(for: .seconds(30))
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                timeout.cancel()
                try? output.close()
                guard process.terminationStatus == 0,
                      let data = try? Data(contentsOf: outputURL) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                // Remote readers drop their potentially incomplete final line
                // before transport, so the bounded JSONL stream stays valid UTF-8.
                guard let text = String(bytes: data, encoding: .utf8) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                return text
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
