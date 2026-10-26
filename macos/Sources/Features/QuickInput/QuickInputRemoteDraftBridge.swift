import Foundation

/// Uses the unified OMG command installed by +ssh. Never installs an editor or
/// sends keys to an unprepared remote session from an auxiliary SSH connection.
enum QuickInputRemoteDraftBridge {
    static func command(_ action: String, session: String, request: String, tty: String? = nil) -> String {
        let arguments = [action, session, request] + (tty.map { [$0] } ?? [])
        let script = "exec python3 \"$HOME/.local/share/oh-my-ghostty/remote/omg\" " +
            arguments.map(Ghostty.Shell.quote).joined(separator: " ")
        return SSHSessionTransport.shellCommand(script)
    }

    static func begin(connection: GitSSHConnection, session: String, request: String, tty: String) async throws {
        let result = try await SSHSessionTransport.run(
            connection: connection, command: command("draft-begin", session: session, request: request, tty: tty),
            limit: 8_192, timeout: 10
        )
        guard result.isSuccess,
              result.stdoutString.split(separator: "\n").contains("OMG_REMOTE_READY_V1") else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    static func receive(connection: GitSSHConnection, session: String, request: String) async throws -> String {
        let result = try await SSHSessionTransport.run(
            connection: connection, command: command("draft-read", session: session, request: request),
            limit: 1_048_576 + 8_192, timeout: 10
        )
        return try decode(result)
    }

    static func decode(_ result: GitExecutionResult) throws -> String {
        let marker = Data("OMG_REMOTE_DRAFT_V1\n".utf8)
        guard result.isSuccess, let range = result.stdout.range(of: marker) else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = result.stdout[range.upperBound...]
        guard data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    static func finish(connection: GitSSHConnection, session: String, request: String) async {
        _ = try? await SSHSessionTransport.run(
            connection: connection, command: command("draft-finish", session: session, request: request),
            limit: 8_192, timeout: 5
        )
    }
}
