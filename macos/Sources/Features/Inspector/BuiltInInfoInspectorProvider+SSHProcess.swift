import AppKit
import Darwin
import Foundation

/// The SSH subprocess, remote listener probe and local-socket helpers behind
/// port forwarding. They hold no provider state; the provider injects them as
/// defaults so tests can replace each one.
extension BuiltInInfoInspectorProvider {
    nonisolated static func launchProcess(
        alias: String,
        remoteHost: String,
        remotePort: Int,
        localPort: Int,
        termination: @escaping (Int32, String) -> Void
    ) throws -> () -> Void {
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-\(UUID().uuidString).err")
        guard FileManager.default.createFile(
            atPath: errorURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let process = Process()
        let forwardHost = PortForwardTarget(
            host: remoteHost,
            port: remotePort
        ).sshHost
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.monitorScript,
            "omg-ssh-port-forward",
            String(ProcessInfo.processInfo.processIdentifier),
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):\(forwardHost):\(remotePort)",
            alias,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        process.terminationHandler = { process in
            try? errorHandle.close()
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            try? FileManager.default.removeItem(at: errorURL)
            let output = String(
                bytes: data.prefix(16_384),
                encoding: .utf8
            ) ?? ""
            termination(process.terminationStatus, output)
        }
        do {
            try process.run()
        } catch {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
            throw error
        }
        return {
            if process.isRunning { process.terminate() }
        }
    }

    nonisolated static let monitorScript = """
    parent_pid="$1"
    shift
    /usr/bin/ssh "$@" &
    ssh_pid=$!
    cleanup() {
      /bin/kill "$ssh_pid" 2>/dev/null || true
      wait "$ssh_pid" 2>/dev/null || true
    }
    trap cleanup EXIT HUP INT TERM
    while /bin/kill -0 "$parent_pid" 2>/dev/null && /bin/kill -0 "$ssh_pid" 2>/dev/null; do
      /bin/sleep 1
    done
    if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
      /bin/kill "$ssh_pid" 2>/dev/null || true
    fi
    wait "$ssh_pid"
    status=$?
    trap - EXIT HUP INT TERM
    exit "$status"
    """

    nonisolated static func waitUntilForwardReady(
        localPort: Int
    ) async -> Bool {
        for _ in 0..<100 {
            if !canBind(port: localPort) { return true }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return false
    }

    static func failureDescription(_ error: Error) -> String {
        if let posix = error as? POSIXError {
            return InfoStrings.current.allocatePortFailed(posix.localizedDescription)
        }
        return error.localizedDescription
    }

    static func sshFailureDescription(
        status: Int32,
        errorOutput: String,
        localPort: Int
    ) -> String {
        let strings = InfoStrings.current
        let lower = errorOutput.lowercased()
        if lower.contains("address already in use") || lower.contains("cannot listen to port") {
            return strings.localPortInUse(localPort)
        }
        if lower.contains("permission denied") {
            return strings.authenticationFailed
        }
        if lower.contains("host key verification failed") {
            return strings.hostKeyFailed
        }
        if lower.contains("could not resolve hostname") {
            return strings.resolveHostFailed
        }
        if lower.contains("connection refused") {
            return strings.connectionRefused
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return strings.connectionTimedOut
        }
        let message = errorOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
            .map { String($0.prefix(240)) }
        return message ?? strings.sshExited(status: status)
    }

    nonisolated static func resolveRemoteProcesses(alias: String, ports: [Int]) async throws -> [Int: String] {
        let command = "exec /bin/sh -c \(shellQuote(remoteProcessCommand(ports: ports)))"
        let result = try await GitProcessRunner().run(
            executablePath: "/usr/bin/ssh",
            arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                        "-o", "ConnectionAttempts=1", "--", alias, command],
            workingDirectory: "/", maxOutputBytes: 64 * 1024, timeout: 6
        )
        guard result.exitCode == 0 else { throw ProcessProbeError.unavailable }
        return try parseRemoteProcessOutput(result.stdout, ports: ports)
    }

    nonisolated static func parseRemoteProcessOutput(_ data: Data, ports: [Int]) throws -> [Int: String] {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ProcessProbeError.invalidOutput
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.popLast() == "OMG_PROCESS_PROBE_V1" else { throw ProcessProbeError.invalidOutput }
        let requested = Set(ports)
        var seen: Set<Int> = []
        var names: [Int: String] = [:]
        for line in lines {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 2, let port = Int(fields[0]), requested.contains(port),
                  seen.insert(port).inserted, fields[1].count <= 128,
                  !fields[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProcessProbeError.invalidOutput
            }
            if !fields[1].isEmpty { names[port] = fields[1] }
        }
        guard seen == requested else { throw ProcessProbeError.invalidOutput }
        return names
    }

    nonisolated static func remoteProcessCommand(ports: [Int]) -> String {
        // Only validated integer ports enter the remote shell. lsof/ss each
        // scan listeners once per batch; fuser is the per-port last resort.
        let ports = Array(Set(ports.filter(validPort))).sorted().map(String.init).joined(separator: " ")
        return """
        export LC_ALL=C
        tool=''
        snapshot=''
        if command -v lsof >/dev/null 2>&1; then
          tool=lsof
          snapshot=$(lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null | awk '
            /^p/ { pid=substr($0,2) }
            /^c/ { name=substr($0,2) }
            /^n/ { endpoint=substr($0,2); sub(/^.*:/,"",endpoint); print endpoint " " pid " " name }
          ')
        elif command -v ss >/dev/null 2>&1; then
          tool=ss
          snapshot=$(ss -H -ltnp 2>/dev/null) || exit 69
        elif command -v fuser >/dev/null 2>&1; then
          tool=fuser
        else
          exit 69
        fi
        for port in \(ports); do
          pid=''
          fallback=''
          if [ "$tool" = lsof ]; then
            row=$(printf '%s\\n' "$snapshot" | awk -v port="$port" '$1 == port { print; exit }')
            pid=$(printf '%s' "$row" | awk '{print $2}')
            fallback=$(printf '%s' "$row" | cut -d ' ' -f 3-)
          elif [ "$tool" = ss ]; then
            socket=$(printf '%s\\n' "$snapshot" | awk -v port="$port" '$4 ~ (":" port "$") { print; exit }')
            pid=$(printf '%s' "$socket" | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p')
            fallback=$(printf '%s' "$socket" | sed -n 's/.*users:(("\\([^"]*\\)".*/\\1/p')
          else
            pid=$(fuser "$port/tcp" 2>/dev/null | awk '{print $1}')
          fi
          name="$fallback"
          if [ -n "$pid" ] && command -v ps >/dev/null 2>&1; then
            args=$(ps -p "$pid" -o args= 2>/dev/null | head -n 1)
            executable=${args%% *}
            [ -z "$executable" ] || name=${executable##*/}
          fi
          printf '%s\\t%s\\n' "$port" "$name"
        done
        printf 'OMG_PROCESS_PROBE_V1\\n'
        """
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func copyToPasteboard(_ value: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    nonisolated static func allocateLocalPort(preferredPort: Int) throws -> Int {
        if validPort(preferredPort), canBind(port: preferredPort) {
            return preferredPort
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    nonisolated static func canBind(port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var reuseAddress: Int32 = 1
        _ = withUnsafePointer(to: &reuseAddress) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
