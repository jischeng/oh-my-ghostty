import Foundation
import CryptoKit

struct GitACPModels {
    let ids: [String]
    let configID: String?

    init(response: [String: Any]) {
        let config = (response["configOptions"] as? [[String: Any]])?.first {
            $0["category"] as? String == "model" || $0["id"] as? String == "model"
        }
        configID = config?["id"] as? String
        func flatten(_ values: [[String: Any]]) -> [String] {
            values.flatMap { item -> [String] in
                if let group = item["options"] as? [[String: Any]] { return flatten(group) }
                return (item["value"] as? String).map { [$0] } ?? []
            }
        }
        if let values = config?["options"] as? [[String: Any]] {
            ids = flatten(values)
        } else {
            ids = ((response["models"] as? [String: Any])?["availableModels"] as? [[String: Any]])?
                .compactMap { $0["modelId"] as? String } ?? []
        }
    }
}

/// Records owned by OMG only. Never sweep an Agent's unrelated global history.
struct GitACPSessionStore {
    let root: URL
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    init(root: URL = OMGApplicationEnvironment.applicationSupportURL().appendingPathComponent("CommitAI/Sessions")) {
        self.root = root
    }

    func create(now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try prune(now: now)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func prune(now: Date = Date()) throws {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey])
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            let values = try entry.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true,
                  let created = values.creationDate, now.timeIntervalSince(created) >= Self.retention else { continue }
            try manager.removeItem(at: entry)
        }
    }

    static func key(repository: GitRepositoryIdentity, route: GitCommitAIRoute, style: String) -> String {
        let data = Data([repository.stateKey, route.agent.rawValue, route.model, style].joined(separator: "\0").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor GitACPService {
    static let shared = GitACPService()
    private struct Session {
        let connection: GitACPConnection
        let id: String
        let directory: URL
        var lastUsed: Date
        var turns = 0
        var bytes = 0
    }
    private var sessions: [String: Session] = [:]
    private var busy: Set<String> = []
    private var cleanup: Task<Void, Never>?
    private let store = GitACPSessionStore()

    func models(agent: GitCommitAgent) async throws -> [String] {
        let session = try await connect(agent: agent)
        await session.connection.stop()
        // Discovery does not contain source code and has no useful history.
        try? FileManager.default.removeItem(at: session.directory)
        return session.models.ids
    }

    func generate(repository: GitRepositoryIdentity, route: GitCommitAIRoute, style: String, prompt: String) async throws -> String {
        let key = GitACPSessionStore.key(repository: repository, route: route, style: style)
        guard busy.insert(key).inserted else { throw GitCommitAIError("This ACP session is busy. Try again shortly.") }
        defer { busy.remove(key) }
        await expireIdle()
        if let old = sessions[key], old.turns >= 8 || old.bytes > 400_000 || Date().timeIntervalSince(old.lastUsed) > 300 {
            sessions.removeValue(forKey: key)
            await old.connection.stop()
        }
        if cleanup == nil {
            cleanup = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.expireIdle()
                }
            }
        }
        do {
            if sessions[key] == nil {
                if sessions.count >= 4 {
                    guard let oldest = sessions.filter({ !busy.contains($0.key) }).min(by: { $0.value.lastUsed < $1.value.lastUsed }) else {
                        throw GitCommitAIError("This ACP session is busy. Try again shortly.")
                    }
                    sessions.removeValue(forKey: oldest.key)
                    await oldest.value.connection.stop()
                }
                let new = try await connect(agent: route.agent)
                do {
                    guard new.models.ids.contains(route.model) else {
                        throw GitCommitAIError("The configured model is not advertised by this ACP adapter. Add it again from the model list.")
                    }
                    if let configID = new.models.configID {
                        _ = try await new.connection.request("session/set_config_option", params: [
                            "sessionId": new.id, "configId": configID, "value": route.model
                        ])
                    } else {
                        _ = try await new.connection.request("session/set_model", params: ["sessionId": new.id, "modelId": route.model])
                    }
                } catch {
                    await new.connection.stop()
                    throw error
                }
                sessions[key] = Session(connection: new.connection, id: new.id, directory: new.directory, lastUsed: Date())
            }
            guard var session = sessions[key] else { throw GitCommitAIError("Invalid ACP response.") }
            let result = try await session.connection.prompt(session: session.id, text:
                "Describe ONLY this request's staged snapshot. Previous snapshots/messages are obsolete; do not combine their changes.\n" + prompt)
            try Task.checkCancellation()
            session.turns += 1
            session.bytes += prompt.utf8.count
            session.lastUsed = Date()
            sessions[key] = session
            let record: [String: Any] = ["agent": route.agent.rawValue, "model": route.model,
                "sessionId": session.id, "message": result, "createdAt": Date().timeIntervalSince1970]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let file = session.directory.appendingPathComponent("turn-\(session.turns).json")
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return result
        } catch {
            if let failed = sessions.removeValue(forKey: key) { await failed.connection.stop() }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func expireIdle() async {
        let expired = sessions.filter { key, session in
            !busy.contains(key) && (Date().timeIntervalSince(session.lastUsed) > 300 || session.turns >= 8 || session.bytes > 400_000)
        }
        for (key, session) in expired {
            sessions.removeValue(forKey: key)
            await session.connection.stop()
        }
        try? store.prune()
    }

    private struct CreatedSession {
        let connection: GitACPConnection
        let id: String
        let directory: URL
        let models: GitACPModels
    }
    private func connect(agent: GitCommitAgent) async throws -> CreatedSession {
        let directory = try store.create()
        let connection = GitACPConnection()
        do {
            var environment = ProcessInfo.processInfo.environment
            for key in Array(environment.keys) where key.hasPrefix("OMG_") || key.hasPrefix("PI_SESSION_") {
                environment.removeValue(forKey: key)
            }
            let overrides = try GitACPEnvironment.prepare(agent: agent, directory: directory, base: environment)
            let invocation = (["/usr/bin/env"] + overrides.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
                + agent.acpCommand).map(GitCommitAIService.shellQuote).joined(separator: " ")
            let shell = environment["SHELL"] ?? "/bin/zsh"
            try await connection.start(executable: shell,
                arguments: ["-lic", "cd " + GitCommitAIService.shellQuote(directory.path) + " && exec " + invocation],
                cwd: directory, environment: environment)
            let initialized = try await connection.request("initialize", params: ["protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "omg-commit", "version": "1"]])
            let info = try JSONSerialization.jsonObject(with: initialized) as? [String: Any]
            guard info?["protocolVersion"] as? Int == 1 else { throw GitCommitAIError("Unsupported ACP protocol version.") }
            let created = try await connection.request("session/new", params: ["cwd": directory.path, "mcpServers": []])
            guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
                  let id = object["sessionId"] as? String else { throw GitCommitAIError("Invalid ACP response.") }
            return CreatedSession(connection: connection, id: id, directory: directory, models: GitACPModels(response: object))
        } catch {
            await connection.stop()
            throw error
        }
    }
}
