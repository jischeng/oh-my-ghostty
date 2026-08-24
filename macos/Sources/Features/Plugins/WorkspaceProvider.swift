import Foundation

struct PaneSessionContext: Equatable, Sendable {
    struct Local: Equatable, Sendable {
        var workingDirectory: String?
        var terminalTitle: String
    }

    struct SSH: Equatable, Sendable {
        let connectionID: String
        let alias: String
    }

    enum State: Equatable, Sendable {
        case local
        case sshConnecting(SSH)
        case sshReady(SSH, workingDirectory: String)
    }

    private(set) var revision: UInt64 = 0
    private(set) var local: Local
    private(set) var state: State = .local
    private var staleRemoteTerminalTitle: String?

    init(workingDirectory: String?, terminalTitle: String) {
        self.local = .init(
            workingDirectory: workingDirectory,
            terminalTitle: terminalTitle
        )
        self.staleRemoteTerminalTitle = nil
    }

    var workingDirectory: String? {
        switch state {
        case .local, .sshConnecting:
            local.workingDirectory
        case .sshReady(_, let workingDirectory):
            workingDirectory
        }
    }

    var workspace: WorkspaceDescriptor? {
        guard case .sshReady(let ssh, let workingDirectory) = state else {
            return nil
        }
        return SSHPlugin.workspace(
            alias: ssh.alias,
            workingDirectory: workingDirectory
        )
    }

    var presentationTitle: String {
        presentationTitle(pathDisplay: .fullPath)
    }

    func presentationTitle(
        pathDisplay: OhMyGhosttyTabPathDisplay
    ) -> String {
        switch state {
        case .local, .sshConnecting:
            if pathDisplay == .folderName, let workingDirectory = local.workingDirectory {
                return WorkspacePathPresentation.folderName(workingDirectory)
            }
            if !local.terminalTitle.isEmpty { return local.terminalTitle }
            return local.workingDirectory.map(WorkspacePathPresentation.folderName) ?? "Terminal"
        case .sshReady(let ssh, let workingDirectory):
            let path = pathDisplay == .folderName
                ? WorkspacePathPresentation.folderName(workingDirectory)
                : workingDirectory
            return "\(ssh.alias) \(path)"
        }
    }

    var tabIconSystemName: String {
        if case .sshReady = state { return "cloud" }
        return "terminal"
    }

    mutating func updateLocalMetadata(
        workingDirectory: String?,
        terminalTitle: String
    ) {
        guard case .local = state else { return }
        let acceptsTitle = staleRemoteTerminalTitle == nil ||
            staleRemoteTerminalTitle != terminalTitle
        if acceptsTitle { staleRemoteTerminalTitle = nil }
        let next = Local(
            workingDirectory: workingDirectory ?? local.workingDirectory,
            terminalTitle: acceptsTitle && !terminalTitle.isEmpty
                ? terminalTitle
                : local.terminalTitle
        )
        guard next != local else { return }
        local = next
        revision &+= 1
    }

    mutating func apply(
        _ signal: Ghostty.ContextSignal,
        currentWorkingDirectory: String?,
        currentTerminalTitle: String
    ) {
        guard signal.id.hasPrefix("omg-ssh-") else { return }
        let metadata = Self.metadata(signal.metadata)

        switch signal.action {
        case .start:
            guard metadata["type"] == "remote",
                  let alias = metadata["targethost"],
                  SSHPlugin.validAlias(alias) else { return }
            let ssh = SSH(connectionID: signal.id, alias: alias)
            let isCurrentConnection: Bool = switch state {
            case .sshConnecting(let active), .sshReady(let active, _):
                active.connectionID == signal.id
            case .local:
                false
            }
            if !isCurrentConnection, case .local = state {
                local = .init(
                    workingDirectory: currentWorkingDirectory ?? local.workingDirectory,
                    terminalTitle: currentTerminalTitle.isEmpty
                        ? local.terminalTitle
                        : currentTerminalTitle
                )
            }
            if let workingDirectory = metadata["cwd"]?.removingPercentEncoding,
               !workingDirectory.isEmpty {
                state = .sshReady(ssh, workingDirectory: workingDirectory)
            } else {
                state = .sshConnecting(ssh)
            }
            revision &+= 1

        case .end:
            let activeID: String? = switch state {
            case .local:
                nil
            case .sshConnecting(let ssh), .sshReady(let ssh, _):
                ssh.connectionID
            }
            guard activeID == signal.id else { return }
            if let workingDirectory = metadata["cwd"]?.removingPercentEncoding,
               !workingDirectory.isEmpty {
                local.workingDirectory = workingDirectory
            }
            staleRemoteTerminalTitle = currentTerminalTitle
            state = .local
            revision &+= 1
        }
    }

    private static func metadata(_ raw: String) -> [String: String] {
        raw.split(separator: ";").reduce(into: [:]) { result, field in
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }
}

enum WorkspacePathPresentation {
    static func folderName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

struct SSHReplayDescriptor: Codable, Equatable, Sendable {
    let version: Int
    let ssh: String
    let forwardEnv: Bool
    let terminfo: Bool
    let cache: Bool
    let args: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case ssh
        case forwardEnv = "forward_env"
        case terminfo
        case cache
        case args
    }

    func command(
        executablePath: String,
        remoteWorkingDirectory: String? = nil
    ) -> String? {
        guard version == 1,
              !ssh.isEmpty,
              ssh.utf8.count <= 4_096,
              !ssh.contains("\0"),
              !args.isEmpty,
              args.count <= 128,
              args.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }) else {
            return nil
        }
        if let remoteWorkingDirectory {
            guard remoteWorkingDirectory.utf8.count <= 4_096,
                  !remoteWorkingDirectory.contains("\0") else { return nil }
        }
        var argv = [
            executablePath,
            "+ssh",
            "--forward-env=\(forwardEnv)",
            "--terminfo=\(terminfo)",
            "--cache=\(cache)",
            "--ssh=\(ssh)",
        ]
        if let remoteWorkingDirectory {
            argv.append("--remote-working-directory=\(remoteWorkingDirectory)")
        }
        argv.append("--")
        argv.append(contentsOf: args)
        return argv.map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SSHReplayStore {
    static func url(
        for connectionID: String,
        applicationSupportURL: URL? = nil
    ) -> URL? {
        guard connectionID.hasPrefix("omg-ssh-"),
              connectionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        let support = applicationSupportURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OMG", isDirectory: true)
        return support
            .appendingPathComponent("SSHReplay", isDirectory: true)
            .appendingPathComponent("\(connectionID).json")
    }

    static func load(
        connectionID: String,
        applicationSupportURL: URL? = nil,
        now: Date = Date()
    ) -> SSHReplayDescriptor? {
        guard let url = url(
            for: connectionID,
            applicationSupportURL: applicationSupportURL
        ),
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let modified = attributes[.modificationDate] as? Date,
        now.timeIntervalSince(modified) >= -5 * 60,
        now.timeIntervalSince(modified) <= 24 * 60 * 60,
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
        permissions & 0o077 == 0,
        let size = (attributes[.size] as? NSNumber)?.intValue,
        size <= 64 * 1_024,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return try? JSONDecoder().decode(SSHReplayDescriptor.self, from: data)
    }
}

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
        case .ssh: "\(displayName) \(workingDirectory)"
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
            displayName: WorkspacePathPresentation.folderName(url.path),
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

struct UnavailableWorkspaceFilesystem: WorkspaceFilesystem {
    let descriptor: WorkspaceDescriptor

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        throw WorkspaceFilesystemError.unavailable
    }

    func createFile(named name: String, in directory: String) async throws {
        throw WorkspaceFilesystemError.unavailable
    }

    func createDirectory(named name: String, in directory: String) async throws {
        throw WorkspaceFilesystemError.unavailable
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
        let defaultsKey = "OMG.Plugin.Enabled.\(pluginID)"
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OMG/Plugins", isDirectory: true)
        return FileManager.default.fileExists(
            atPath: supportURL
                .appendingPathComponent(pluginID, isDirectory: true)
                .appendingPathComponent("manifest.json")
                .path
        )
    }

    static func validAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.allSatisfy { character in
            character.isLetter || character.isNumber || ".-_".contains(character)
        }
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
            for alias in aliases where validAlias(alias) {
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
}

enum WorkspaceFilesystemFactory {
    static func make(for context: InspectorPaneContext) -> any WorkspaceFilesystem {
        if let workspace = context.workspace, workspace.kind == .ssh {
            guard let host = SSHPlugin.configuration(alias: workspace.displayName) else {
                return UnavailableWorkspaceFilesystem(descriptor: workspace)
            }
            return SSHWorkspaceFilesystem(
                host: host,
                workingDirectory: workspace.workingDirectory
            )
        }
        if case .sshReady(let ssh, let workingDirectory) = context.session.state {
            return UnavailableWorkspaceFilesystem(descriptor: .init(
                kind: .ssh,
                id: "ssh:\(ssh.alias)",
                displayName: ssh.alias,
                workingDirectory: workingDirectory
            ))
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = ["-q", "-b", "-", host.alias]
        process.standardInput = Self.dataPipe(batch + "\n")

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let temporaryDirectory = FileManager.default.temporaryDirectory
                let token = UUID().uuidString
                let outputURL = temporaryDirectory
                    .appendingPathComponent("omg-sftp-\(token).out")
                let errorURL = temporaryDirectory
                    .appendingPathComponent("omg-sftp-\(token).err")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                defer {
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: errorURL)
                }
                guard let output = try? FileHandle(forWritingTo: outputURL),
                      let errors = try? FileHandle(forWritingTo: errorURL) else {
                    throw WorkspaceFilesystemError.unavailable
                }
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch {
                    throw WorkspaceFilesystemError.unavailable
                }
                let timeout = Task.detached {
                    try? await Task.sleep(for: .seconds(15))
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                timeout.cancel()
                try? output.close()
                try? errors.close()

                let stdout = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                guard process.terminationStatus == 0 else {
                    throw WorkspaceFilesystemError.commandFailed(
                        process.terminationStatus,
                        stderr
                    )
                }
                return stdout
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func parseLongListing(
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
