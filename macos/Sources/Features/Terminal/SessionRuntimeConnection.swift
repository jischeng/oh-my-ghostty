import AppKit
import CryptoKit
import Foundation

struct SessionRuntimePolicy: Codable, Equatable, Sendable {
    var detachedTTLSeconds = 259_200
    var expiresAt: Int?
    var closeOnAgentDone = true
    var agentDoneGraceSeconds = 60
    var terminateGraceSeconds = 5
    var hostIdleSeconds = 300
    var recordRetentionSeconds = 604_800

    enum CodingKeys: String, CodingKey {
        case detachedTTLSeconds = "detached_ttl_seconds"
        case expiresAt = "expires_at"
        case closeOnAgentDone = "close_on_agent_done"
        case agentDoneGraceSeconds = "agent_done_grace_seconds"
        case terminateGraceSeconds = "terminate_grace_seconds"
        case hostIdleSeconds = "host_idle_seconds"
        case recordRetentionSeconds = "record_retention_seconds"
    }
}

struct SessionRuntimeDescriptor: Codable, Equatable, Sendable {
    static let environmentKey = "OMG_SESSION_RUNTIME_DESCRIPTOR"
    var connection: GitSSHConnection
    var revision: String
    var policy: SessionRuntimePolicy

    var identity: String {
        SHA256.hash(data: Data((connection.identity + "\0" + revision).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func configure(_ config: inout Ghostty.SurfaceConfiguration) throws {
        config.environmentVariables[Self.environmentKey] = String(data: try JSONEncoder().encode(self), encoding: .utf8)
    }

    func openRequest(pane: UUID, restoring: Bool) throws -> String {
        struct Request: Encodable {
            let id: String
            let policy: SessionRuntimePolicy
            let create: Bool
        }
        let data = try JSONEncoder().encode(Request(id: pane.uuidString.lowercased(), policy: policy, create: !restoring))
        guard let result = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}

/// Owns one relay process per exact host/revision. Each surface gets a descriptor,
/// never a process-global SSH target. Remote PTYs outlive this coordinator.
@MainActor
final class SessionRuntimeConnections {
    static let shared = SessionRuntimeConnections()
    private struct Relay { let process: Process; let socket: URL }
    private var relays: [String: Relay] = [:]

    static var resources: URL {
        Bundle.main.resourceURL!.appendingPathComponent("session-runtime", isDirectory: true)
    }

    static func descriptor(connection: GitSSHConnection, policy: SessionRuntimePolicy) throws -> SessionRuntimeDescriptor {
        let revision = try String(contentsOf: resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return .init(connection: connection, revision: revision, policy: policy)
    }

    private func artifactDirectory(revision: String) throws -> URL {
        guard !revision.isEmpty, revision.count <= 128,
              revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let current = try String(contentsOf: Self.resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = OMGApplicationEnvironment.applicationSupportURL().appendingPathComponent("session-runtime/versions")
        let cached = root.appendingPathComponent(revision)
        if revision == current && !FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = root.appendingPathComponent(".copy-" + UUID().uuidString)
            try FileManager.default.copyItem(at: Self.resources, to: staging)
            do { try FileManager.default.moveItem(at: staging, to: cached) } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        guard FileManager.default.fileExists(atPath: cached.appendingPathComponent("revision").path) else {
            throw NSError(domain: "OMGSessionRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The runtime version for this session is unavailable. Its remote process has not been restarted."])
        }
        let currentSnapshot = try String(contentsOf: Self.resources.appendingPathComponent("snapshot-revision"), encoding: .utf8)
        let cachedSnapshot = try String(contentsOf: cached.appendingPathComponent("snapshot-revision"), encoding: .utf8)
        guard currentSnapshot == cachedSnapshot else {
            throw NSError(domain: "OMGSessionRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This session uses an incompatible terminal snapshot version. Its remote process is preserved; reopen it with the matching app version."])
        }
        return cached
    }

    func prepare(_ descriptor: SessionRuntimeDescriptor) throws -> URL {
        if let relay = relays[descriptor.identity], relay.process.isRunning { return relay.socket }
        // Darwin sockaddr_un paths are capped near 104 bytes; the user's
        // /var/folders temporary path plus a host identity can exceed that.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("omg-runtime-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let artifacts = try artifactDirectory(revision: descriptor.revision)
        let key = String(descriptor.identity.prefix(16))
        let socket = root.appendingPathComponent(key + ".sock")
        let configURL = root.appendingPathComponent(key + ".json")
        struct Configuration: Encodable {
            let executable: String
            let arguments: [String]
            let cwd: String
            let bundle: String
            let policy: SessionRuntimePolicy
            let revision: String
            let hooks: String?
        }
        let config = Configuration(executable: descriptor.connection.executablePath,
            arguments: descriptor.connection.arguments.map { $0 == "BatchMode=yes" ? "BatchMode=no" : $0 },
            cwd: descriptor.connection.localWorkingDirectory,
            bundle: artifacts.path, policy: descriptor.policy, revision: descriptor.revision,
            hooks: try AgentHookInstaller.remoteInstallerScript(agents: [.codex, .claude, .pi]))
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        try? FileManager.default.removeItem(at: socket)
        let process = Process()
        process.executableURL = artifacts.appendingPathComponent("omg-sessiond")
        process.arguments = ["connect", socket.path, configURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = artifacts.appendingPathComponent("askpass").path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "omg:0"
        process.environment = environment
        try process.run()
        relays[descriptor.identity] = .init(process: process, socket: socket)
        return socket
    }

    func shutdown() {
        for relay in relays.values where relay.process.isRunning { relay.process.terminate() }
        relays.removeAll()
    }

    func open(connection: GitSSHConnection, policy: SessionRuntimePolicy) throws {
        let descriptor = try Self.descriptor(connection: connection, policy: policy)
        var config = Ghostty.SurfaceConfiguration()
        try descriptor.configure(&config)
        guard let delegate = NSApp.delegate as? AppDelegate else { throw CocoaError(.featureUnsupported) }
        _ = TerminalController.newWindow(delegate.ghostty, withBaseConfig: config)
    }
}
