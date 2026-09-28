import Foundation

struct GitACPAdapterUpdateInfo: Equatable, Sendable {
    let installedVersion: String?
    let latestVersion: String

    var updateAvailable: Bool {
        guard let installedVersion else { return true }
        return GitACPAdapterManager.isNewer(latestVersion, than: installedVersion)
    }
}

/// Codex ACP remains optional. When users explicitly update it, OMG installs a
/// private copy under Application Support and leaves any global npm install alone.
enum GitACPAdapterManager {
    static let packageName = "@agentclientprotocol/codex-acp"
    private static let registryURL = URL(string: "https://registry.npmjs.org/@agentclientprotocol%2Fcodex-acp/latest")!

    private static func adapterRoot(supportURL: URL? = nil) -> URL {
        (supportURL ?? OMGApplicationEnvironment.applicationSupportURL())
            .appendingPathComponent("CommitAI/ACP/codex", isDirectory: true)
    }

    static func activeCodexBinURL(supportURL: URL? = nil) -> URL? {
        let root = adapterRoot(supportURL: supportURL)
        guard let version = try? String(contentsOf: root.appendingPathComponent("current"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), isStableVersion(version) else { return nil }
        let binary = root.appendingPathComponent(version).appendingPathComponent("bin/codex-acp")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary.deletingLastPathComponent() : nil
    }

    static func checkCodexUpdate(supportURL: URL? = nil, session: URLSession = .shared) async throws -> GitACPAdapterUpdateInfo {
        let (data, response) = try await session.data(from: registryURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = object["version"] as? String, isStableVersion(latest) else {
            throw GitCommitAIError("Could not check the stable Codex ACP version.")
        }
        let root = adapterRoot(supportURL: supportURL)
        let managedVersion = try? String(contentsOf: root.appendingPathComponent("current"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installed: String?
        if let managedVersion, isStableVersion(managedVersion) {
            installed = managedVersion
        } else {
            installed = await externalCodexVersion()
        }
        return GitACPAdapterUpdateInfo(installedVersion: installed, latestVersion: latest)
    }

    static func installCodex(version: String, supportURL: URL? = nil) async throws {
        guard isStableVersion(version) else { throw GitCommitAIError("The Codex ACP version is invalid.") }
        let root = adapterRoot(supportURL: supportURL)
        let versionRoot = root.appendingPathComponent(version, isDirectory: true)
        let manifest = versionRoot.appendingPathComponent("lib/node_modules/\(packageName)/package.json")
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let alreadyInstalled = (try? Data(contentsOf: manifest))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["version"] as? String } == version
            && manager.isExecutableFile(atPath: versionRoot.appendingPathComponent("bin/codex-acp").path)

        if !alreadyInstalled {
            try? manager.removeItem(at: versionRoot)
            try manager.createDirectory(at: versionRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let command = [
                "npm install --global --prefix \(shellQuote(versionRoot.path))",
                "--omit=dev --ignore-scripts --no-audit --no-fund",
                "\(shellQuote(packageName + "@" + version))"
            ].joined(separator: " ")
            do {
                let result = try await GitProcessRunner().run(executablePath: "/bin/zsh",
                    arguments: ["-lic", command], workingDirectory: NSHomeDirectory(),
                    environment: ProcessInfo.processInfo.environment, maxOutputBytes: 32_000, timeout: 180)
                guard result.isSuccess else { throw GitCommitAIError("npm could not install the Codex ACP adapter.") }
            } catch {
                try? manager.removeItem(at: versionRoot)
                throw GitCommitAIError("Could not install Codex ACP. Check that Node.js and npm are available, then try again.")
            }
        }

        let installedData = try Data(contentsOf: manifest)
        let installedObject = try JSONSerialization.jsonObject(with: installedData) as? [String: Any]
        guard installedObject?["version"] as? String == version,
              manager.isExecutableFile(atPath: versionRoot.appendingPathComponent("bin/codex-acp").path) else {
            try? manager.removeItem(at: versionRoot)
            throw GitCommitAIError("The installed Codex ACP package did not pass verification.")
        }
        try Data(version.utf8).write(to: root.appendingPathComponent("current"), options: .atomic)
        pruneInactiveCodexVersions(supportURL: supportURL, keeping: version)
    }

    static func pruneInactiveCodexVersions(supportURL: URL? = nil, keeping version: String) {
        guard isStableVersion(version) else { return }
        let root = adapterRoot(supportURL: supportURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries where entry.lastPathComponent != version && isStableVersion(entry.lastPathComponent) {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func isStableVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part) != nil
                && (part.count == 1 || part.first != "0")
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard isStableVersion(candidate), isStableVersion(current) else { return false }
        let lhs = candidate.split(separator: ".").compactMap { Int($0) }
        let rhs = current.split(separator: ".").compactMap { Int($0) }
        for (new, old) in zip(lhs, rhs) where new != old { return new > old }
        return false
    }

    private static func externalCodexVersion() async -> String? {
        guard let result = try? await GitProcessRunner().run(executablePath: "/bin/zsh",
            arguments: ["-lic", "codex-acp --version"], workingDirectory: NSHomeDirectory(),
            environment: ProcessInfo.processInfo.environment, maxOutputBytes: 2_048, timeout: 15), result.isSuccess,
              let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        let components = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard let packageIndex = components.firstIndex(where: { $0 == packageName }),
              components.indices.contains(packageIndex + 1),
              isStableVersion(String(components[packageIndex + 1])) else { return nil }
        return String(components[packageIndex + 1])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
