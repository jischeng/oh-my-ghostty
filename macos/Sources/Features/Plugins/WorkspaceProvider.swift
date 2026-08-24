import Foundation

/// Generic workspace identity shared by Local, SSH, and future remote providers.
struct WorkspaceDescriptor: Equatable, Sendable {
    enum Kind: String, Sendable {
        case local
        case ssh
    }

    let kind: Kind
    let id: String
    let displayName: String
    let workingDirectory: String

    var icon: GhosttyTabIcon {
        switch kind {
        case .local: .systemSymbol("terminal")
        case .ssh: .systemSymbol("cloud")
        }
    }

    var presentationTitle: String {
        switch kind {
        case .local: workingDirectory
        case .ssh: "☁ \(displayName) \(workingDirectory)"
        }
    }
}

struct WorkspaceFileEntry: Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
}

enum WorkspaceFilesystemError: Error, Equatable, Sendable {
    case unavailable
    case commandFailed(Int32, String)
    case invalidResponse
    case invalidPath
}

/// Data-only filesystem boundary consumed by Files UI/providers.
/// Implementations perform their own bounded asynchronous IO.
protocol WorkspaceFilesystem: Sendable {
    var descriptor: WorkspaceDescriptor { get }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry]
    func createFile(named name: String, in directory: String) async throws
    func createDirectory(named name: String, in directory: String) async throws
}

struct LocalWorkspaceFilesystem: WorkspaceFilesystem {
    let descriptor: WorkspaceDescriptor

    init(workingDirectory: String) {
        let url = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        self.descriptor = .init(
            kind: .local,
            id: "local",
            displayName: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            workingDirectory: url.path
        )
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        try await Task.detached(priority: .utility) {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else {
                throw WorkspaceFilesystemError.unavailable
            }
            return urls.compactMap { url -> WorkspaceFileEntry? in
                guard url.lastPathComponent != ".DS_Store" else { return nil }
                let values = try? url.resourceValues(forKeys: keys)
                return .init(
                    path: url.path,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(500)
            .map { $0 }
        }.value
    }

    func createFile(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw WorkspaceFilesystemError.unavailable
            }
        }.value
    }

    func createDirectory(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        try await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: directory).appendingPathComponent(name),
                    withIntermediateDirectories: false
                )
            } catch {
                throw WorkspaceFilesystemError.unavailable
            }
        }.value
    }

    private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":")
    }
}

struct SSHHostConfiguration: Equatable, Sendable {
    let alias: String
    let hostname: String
    let user: String?
    let port: Int?
    let proxyJump: String?

    var workspaceID: String { "ssh:\(alias)" }

    var icon: GhosttyTabIcon { .systemSymbol("cloud") }

    func displayTitle(for workingDirectory: String) -> String {
        "☁ \(alias) \(workingDirectory)"
    }
}

/// Reads aliases through the user's OpenSSH configuration without owning keys,
/// passwords, known_hosts, ProxyJump, or an SSH agent.
struct SSHPlugin: Sendable {
    static let pluginID = "builtin.ssh"
    static let manifest = PluginManifest(
        id: pluginID,
        version: "0.1.0",
        executable: "builtin",
        capabilities: [.terminalEvents, .tabMetadata, .tabIcon, .inspectorPane],
        minimumHostVersion: "0.1.0"
    )

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OMG.Plugin.Enabled.\(pluginID)")
    }

    static func configurations(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> [SSHHostConfiguration] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [SSHHostConfiguration] = []
        var aliases: [String] = []
        var values: [String: String] = [:]

        func flush() {
            for alias in aliases where !alias.contains("*") && !alias.contains("?") {
                guard let hostname = values["hostname"] else { continue }
                result.append(.init(
                    alias: alias,
                    hostname: hostname,
                    user: values["user"],
                    port: values["port"].flatMap(Int.init),
                    proxyJump: values["proxyjump"]
                ))
            }
            aliases.removeAll()
            values.removeAll()
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1])
            if key == "host" {
                flush()
                let aliasParts = value.split(whereSeparator: { character in
                    character == " " || character == "\t"
                })
                aliases = aliasParts.map(String.init)
            } else if !aliases.isEmpty {
                values[key] = value
            }
        }
        flush()
        return result
    }

    static func configuration(
        alias: String,
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> SSHHostConfiguration? {
        configurations(at: url).first { $0.alias == alias }
    }

    static func workspace(
        alias: String,
        workingDirectory: String
    ) -> WorkspaceDescriptor? {
        guard isEnabled, let host = configuration(alias: alias) else { return nil }
        return .init(
            kind: .ssh,
            id: host.workspaceID,
            displayName: host.alias,
            workingDirectory: workingDirectory
        )
    }

    static func workspace(
        forTitle title: String,
        workingDirectory: String
    ) -> WorkspaceDescriptor? {
        workspace(
            forTitle: title,
            workingDirectory: workingDirectory,
            configurations: configurations()
        )
    }

    static func workspace(
        forTitle title: String,
        workingDirectory: String,
        configurations: [SSHHostConfiguration]
    ) -> WorkspaceDescriptor? {
        guard isEnabled else { return nil }
        let normalizedTitle = title.lowercased()
        for host in configurations {
            let candidates = [
                host.alias.lowercased(),
                host.hostname.lowercased(),
                host.user.map { "\($0.lowercased())@\(host.hostname.lowercased())" },
            ].compactMap { $0 }
            if candidates.contains(where: { normalizedTitle.contains($0) }) {
                return .init(
                    kind: .ssh,
                    id: host.workspaceID,
                    displayName: host.alias,
                    workingDirectory: workingDirectory
                )
            }
        }
        return nil
    }
}

enum WorkspaceFilesystemFactory {
    static func make(for context: InspectorPaneContext) -> any WorkspaceFilesystem {
        if let workspace = context.workspace,
           workspace.kind == .ssh,
           let host = SSHPlugin.configuration(alias: workspace.displayName) {
            return SSHWorkspaceFilesystem(
                host: host,
                workingDirectory: workspace.workingDirectory
            )
        }
        return LocalWorkspaceFilesystem(
            workingDirectory: context.workingDirectory ?? "/"
        )
    }
}

struct SSHWorkspaceFilesystem: WorkspaceFilesystem {
    let host: SSHHostConfiguration
    let descriptor: WorkspaceDescriptor

    init(host: SSHHostConfiguration, workingDirectory: String) {
        self.host = host
        self.descriptor = .init(
            kind: .ssh,
            id: host.workspaceID,
            displayName: host.alias,
            workingDirectory: workingDirectory
        )
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        let output = try await runSFTP(batch: "ls -la \(Self.quote(path))")
        return try Self.parseLongListing(output, directory: path)
    }

    func createFile(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        _ = try await runSFTP(batch: "put /dev/null \(Self.quote(Self.join(directory, name)))")
    }

    func createDirectory(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        _ = try await runSFTP(batch: "mkdir \(Self.quote(Self.join(directory, name)))")
    }

    private func runSFTP(batch: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            process.arguments = ["-q", "-b", "-", host.alias]
            process.standardInput = Self.dataPipe(batch + "\n")
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch { throw WorkspaceFilesystemError.unavailable }
            process.waitUntilExit()
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw WorkspaceFilesystemError.commandFailed(process.terminationStatus, stderr)
            }
            return stdout
        }.value
    }

    private static func parseLongListing(
        _ output: String,
        directory: String
    ) throws -> [WorkspaceFileEntry] {
        var result: [WorkspaceFileEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10, !line.hasPrefix("sftp>") else { continue }
            let isDirectory = line.first == "d"
            let columns = line.split(maxSplits: 8, whereSeparator: { character in
                character == " " || character == "\t"
            })
            guard columns.count == 9 else { continue }
            let name = String(columns[8])
            guard name != ".", name != "..", name != ".DS_Store" else { continue }
            result.append(.init(
                path: join(directory, name),
                name: name,
                isDirectory: isDirectory
            ))
        }
        guard result.count <= 500 else { return Array(result.prefix(500)) }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func dataPipe(_ string: String) -> Pipe {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(string.data(using: .utf8)!)
        pipe.fileHandleForWriting.closeFile()
        return pipe
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":")
    }
}
