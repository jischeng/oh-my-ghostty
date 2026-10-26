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

    /// Probe the actual foreground process group, including agents launched by
    /// user aliases/functions which deliberately bypass our startup wrappers.
    static func foregroundAgent(connection: GitSSHConnection, session: String, tty: String) async throws -> SupportedAgent? {
        let arguments = [session, tty].map(Ghostty.Shell.quote).joined(separator: " ")
        let result = try await SSHSessionTransport.run(
            connection: connection, command: "exec python3 - " + arguments,
            stdin: Data(foregroundProbe.utf8), limit: 65_536, timeout: 10
        )
        guard result.isSuccess else { throw CocoaError(.fileReadUnknown) }
        return LocalAgentProcessDetector.detect(in: result.stdoutString)
    }

    static let foregroundProbe = #"""
    import hashlib, json, os, pathlib, subprocess, sys
    session, tty = sys.argv[1:]
    directory = pathlib.Path.home() / '.local/share/oh-my-ghostty/remote/sessions' / hashlib.sha256(session.encode()).hexdigest()
    metadata = json.loads((directory / 'session.json').read_text())
    if metadata.get('protocol') != 1 or metadata.get('tty') != tty:
        raise ValueError('Remote session mismatch')
    result = subprocess.run(['ps', '-t', tty[5:] if tty.startswith('/dev/') else tty, '-o', 'pgid=,tpgid=,args='],
                            capture_output=True, text=True, check=True, timeout=3)
    count = 0
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0] == fields[1] and int(fields[0]) > 0:
            # Only executable/runtime identity is needed; never return prompt args.
            tokens = fields[2].split()
            executable = os.path.basename(tokens[0])
            identity = tokens[:5] if executable in ('node', 'bun', 'deno') else tokens[:1]
            print(' '.join(identity)[:4096])
            count += 1
            if count >= 8:
                break
    """#

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
