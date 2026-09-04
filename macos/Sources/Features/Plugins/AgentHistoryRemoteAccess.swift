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

/// Reads an Agent's session store on a remote host through a single portable
/// mechanism: `ssh <alias> <command>` with stdout captured. This mirrors the
/// existing in-tree SSH helpers (BatchMode, bounded timeouts) and never owns
/// keys, passwords, or known_hosts.
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

    /// Lists `*.jsonl` files under the given absolute remote roots using a
    /// POSIX `find -exec ls -ld` so the same command works on Linux and macOS
    /// hosts. Directories that do not exist are ignored via stderr suppression.
    func enumerate(
        roots: [String],
        maximumFiles: Int
    ) async throws -> [AgentHistoryRemoteFile] {
        let validRoots = roots.filter(Self.validRemotePath)
        guard !validRoots.isEmpty else { return [] }
        let quoted = validRoots.map(Self.shellQuote).joined(separator: " ")
        let command = "find \(quoted) -type f -name '*.jsonl' -exec ls -ld {} \\; 2>/dev/null"
        let output = try await runCommand(command)
        let files = Self.parseLongListings(output)
        return maximumFiles > 0 ? Array(files.prefix(maximumFiles)) : files
    }

    func read(path: String, maximumBytes: Int) async throws -> Data {
        guard Self.validRemotePath(path), maximumBytes > 0 else {
            throw AgentHistoryRemoteError.invalidPath
        }
        let command = "head -c \(maximumBytes) \(Self.shellQuote(path)) 2>/dev/null"
        let output = try await runCommand(command)
        return Data(output.utf8)
    }

    /// Parses `ls -ld` long listings (one per line) produced by
    /// `find -exec ls -ld`. Columns are permissions, links, owner, group, size,
    /// month, day, time/year, then the absolute path.
    static func parseLongListings(_ output: String) -> [AgentHistoryRemoteFile] {
        var files: [AgentHistoryRemoteFile] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10, line.first != "t" else { continue }
            let columns = line.split(
                maxSplits: 8,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard columns.count == 9 else { continue }
            guard let size = Int(columns[4]) else { continue }
            let name = String(columns[8])
            guard validRemotePath(name) else { continue }
            let month = String(columns[5])
            let day = String(columns[6])
            let time = String(columns[7])

            var date: Date?
            if time.contains(":") {
                formatter.dateFormat = "MMM dd HH:mm"
                let parsed = formatter.date(from: "\(month) \(day) \(time)")
                // `ls` prints the current year without a time; a future date
                // means the file is from a previous year.
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

            files.append(.init(
                path: name,
                size: size,
                modifiedAt: date ?? .distantPast
            ))
        }
        return files.sorted { $0.modifiedAt > $1.modifiedAt }
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
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            alias,
            command,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                do {
                    try process.run()
                } catch {
                    throw AgentHistoryRemoteError.unavailable
                }
                let timeout = Task.detached {
                    try? await Task.sleep(for: .seconds(15))
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                timeout.cancel()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    throw AgentHistoryRemoteError.unavailable
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw AgentHistoryRemoteError.unavailable
                }
                return text
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
