import Darwin
import Foundation

/// Executable specification for launching a local stdio Language Server.
struct EditorLSPServerCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]?

    init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Pure incremental parser & encoder for JSON-RPC 2.0 `Content-Length: <bytes>\r\n\r\n` stdio streams.
struct LSPMessageFramer: Sendable {
    static let maxPayloadBytes = 32 * 1_024 * 1_024
    private static let crlfTerminator = Data("\r\n\r\n".utf8)
    private static let lfTerminator = Data("\n\n".utf8)

    private var buffer = Data()

    init() {}

    static func encode(_ jsonObject: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var messages: [Data] = []
        while let parsed = try nextFrame() {
            messages.append(parsed)
        }
        return messages
    }

    private struct HeaderSpan {
        let bodyStartOffset: Int
        let contentLength: Int
    }

    private mutating func nextFrame() throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        guard let header = try parseHeaderIfPresent() else { return nil }
        let totalNeeded = header.bodyStartOffset + header.contentLength
        guard buffer.count >= totalNeeded else { return nil }

        let startIdx = buffer.startIndex + header.bodyStartOffset
        let endIdx = startIdx + header.contentLength
        let payload = Data(buffer[startIdx..<endIdx])
        buffer.removeSubrange(buffer.startIndex..<endIdx)
        if buffer.isEmpty {
            buffer.removeAll(keepingCapacity: false)
        }
        return payload
    }

    private func parseHeaderIfPresent() throws -> HeaderSpan? {
        let separatorRange: Range<Data.Index>
        if let crlf = buffer.range(of: Self.crlfTerminator) {
            separatorRange = crlf
        } else if let lf = buffer.range(of: Self.lfTerminator) {
            separatorRange = lf
        } else {
            return nil
        }

        let headerBytes = buffer[buffer.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerBytes, encoding: .ascii)
                ?? String(data: headerBytes, encoding: .utf8) else {
            throw EditorLSPError.malformedHeader
        }

        var contentLength: Int?
        for rawLine in headerString.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let parsed = Int(value), parsed >= 0, parsed <= Self.maxPayloadBytes else {
                    throw EditorLSPError.invalidContentLength
                }
                contentLength = parsed
            }
        }

        guard let length = contentLength else {
            throw EditorLSPError.malformedHeader
        }
        let bodyStart = buffer.distance(from: buffer.startIndex, to: separatorRange.upperBound)
        return HeaderSpan(bodyStartOffset: bodyStart, contentLength: length)
    }
}

enum EditorLSPError: Error, Equatable, Sendable {
    case serverUnavailable
    case launchFailed(String)
    case malformedHeader
    case invalidContentLength
    case requestTimedOut
    case connectionClosed
    case responseError(code: Int, message: String)
}

/// On-demand, zero-bundled-binary local LSP client manager with 5-minute idle reaping.
actor EditorLSPManager {
    struct ServerKey: Hashable, Sendable {
        let workspaceRoot: String
        let serverGroup: String
    }

    struct OpenDocumentRequest: Sendable {
        let path: String
        let languageID: String
        let text: String
        let workspaceRoot: String
    }

    struct DocumentQuery: Sendable {
        let path: String
        let languageID: String
        let text: String
        let workspaceRoot: String
        let position: EditorPosition
    }

    private static let candidateServersByGroup: [String: [(executable: String, arguments: [String])]] = [
        "swift": [
            ("sourcekit-lsp", [])
        ],
        "zig": [
            ("zls", [])
        ],
        "rust": [
            ("rust-analyzer", [])
        ],
        "go": [
            ("gopls", [])
        ],
        "typescript": [
            ("typescript-language-server", ["--stdio"]),
            ("vtsls", ["--stdio"])
        ],
        "python": [
            ("pyright-langserver", ["--stdio"]),
            ("basedpyright-langserver", ["--stdio"]),
            ("ty", ["server"])
        ],
        "clangd": [
            ("clangd", [])
        ]
    ]

    private let injectedCommands: [String: EditorLSPServerCommand]
    private let idleTimeout: TimeInterval
    private let reaperInterval: TimeInterval
    private var diagnosticsHandler: (@Sendable (String, [EditorDiagnostic]) -> Void)?

    private var resolvedLoginEnvironment: [String: String]?
    private var loginEnvironmentTask: Task<[String: String], Never>?
    private var resolvedCommandCache: [String: EditorLSPServerCommand?] = [:]

    private var activeSessions: [ServerKey: LSPServerSession] = [:]
    private var pendingStartTasks: [ServerKey: Task<LSPServerSession?, Never>] = [:]
    private var reaperTask: Task<Void, Never>?
    private var isShuttingDownAll = false

    init(
        serverCommands: [String: EditorLSPServerCommand] = [:],
        idleTimeout: TimeInterval = 300,
        reaperInterval: TimeInterval = 30,
        diagnosticsHandler: (@Sendable (String, [EditorDiagnostic]) -> Void)? = nil
    ) {
        var normalized: [String: EditorLSPServerCommand] = [:]
        for (key, value) in serverCommands {
            let lower = key.lowercased()
            normalized[lower] = value
            if let group = EditorLanguageID.lspServerGroup(for: lower) {
                normalized[group] = value
            }
        }
        self.injectedCommands = normalized
        self.idleTimeout = max(0.05, idleTimeout)
        self.reaperInterval = max(0.05, reaperInterval)
        self.diagnosticsHandler = diagnosticsHandler
    }

    func setDiagnosticsHandler(_ handler: (@Sendable (String, [EditorDiagnostic]) -> Void)?) {
        self.diagnosticsHandler = handler
    }

    var activeServerCount: Int {
        activeSessions.values.filter { $0.isAlive }.count
    }

    func activeServerPIDs() -> [pid_t] {
        activeSessions.values.compactMap { $0.isAlive ? $0.processIdentifier : nil }
    }

    // MARK: - Document Lifecycle

    func didOpen(_ request: OpenDocumentRequest) async {
        guard let session = await session(
            workspaceRoot: request.workspaceRoot,
            languageID: request.languageID,
            spawnIfNeeded: true
        ) else {
            return
        }
        await session.didOpen(path: request.path, languageID: request.languageID, text: request.text)
    }

    func didChange(path: String, languageID: String, text: String, workspaceRoot: String) async {
        guard let session = await session(
            workspaceRoot: workspaceRoot,
            languageID: languageID,
            spawnIfNeeded: false
        ) else {
            return
        }
        await session.didChange(path: path, languageID: languageID, text: text)
    }

    func didSave(path: String, languageID: String, text: String, workspaceRoot: String) async {
        guard let session = await session(
            workspaceRoot: workspaceRoot,
            languageID: languageID,
            spawnIfNeeded: false
        ) else {
            return
        }
        await session.didSave(path: path, text: text)
    }

    func didClose(path: String, languageID: String, workspaceRoot: String) async {
        guard let session = await session(
            workspaceRoot: workspaceRoot,
            languageID: languageID,
            spawnIfNeeded: false
        ) else {
            return
        }
        await session.didClose(path: path)
    }

    // MARK: - LSP Queries

    func hover(_ query: DocumentQuery) async -> EditorHoverInfo? {
        guard let session = await session(
            workspaceRoot: query.workspaceRoot,
            languageID: query.languageID,
            spawnIfNeeded: true
        ) else {
            return nil
        }
        await session.ensureOpen(path: query.path, languageID: query.languageID, text: query.text)
        return await session.hover(path: query.path, position: query.position)
    }

    func definitions(_ query: DocumentQuery) async -> [EditorDefinitionLocation] {
        guard let session = await session(
            workspaceRoot: query.workspaceRoot,
            languageID: query.languageID,
            spawnIfNeeded: true
        ) else {
            return []
        }
        await session.ensureOpen(path: query.path, languageID: query.languageID, text: query.text)
        return await session.definitions(path: query.path, position: query.position)
    }

    func references(_ query: DocumentQuery) async -> [EditorDefinitionLocation] {
        guard let session = await session(
            workspaceRoot: query.workspaceRoot,
            languageID: query.languageID,
            spawnIfNeeded: true
        ) else {
            return []
        }
        await session.ensureOpen(path: query.path, languageID: query.languageID, text: query.text)
        return await session.references(path: query.path, position: query.position)
    }

    func documentSymbols(
        path: String,
        languageID: String,
        text: String,
        workspaceRoot: String
    ) async -> [EditorDocumentSymbol] {
        guard let session = await session(
            workspaceRoot: workspaceRoot,
            languageID: languageID,
            spawnIfNeeded: true
        ) else {
            return []
        }
        await session.ensureOpen(path: path, languageID: languageID, text: text)
        return await session.documentSymbols(path: path)
    }

    func completions(
        _ query: DocumentQuery,
        triggerCharacter: String? = nil
    ) async -> [CompletionItem] {
        guard let session = await session(
            workspaceRoot: query.workspaceRoot,
            languageID: query.languageID,
            spawnIfNeeded: true
        ) else {
            return []
        }
        await session.ensureOpen(path: query.path, languageID: query.languageID, text: query.text)
        return await session.completions(
            path: query.path,
            position: query.position,
            triggerCharacter: triggerCharacter
        )
    }

    // MARK: - Idle Reaper & Shutdown

    func reapIdleServers(now: Date = Date()) async {
        var idleSessions: [LSPServerSession] = []
        for (key, session) in activeSessions {
            if !session.isAlive {
                activeSessions.removeValue(forKey: key)
                continue
            }
            let elapsed = now.timeIntervalSince(session.lastActivityDate)
            if elapsed >= idleTimeout {
                activeSessions.removeValue(forKey: key)
                idleSessions.append(session)
            }
        }
        if activeSessions.isEmpty {
            reaperTask?.cancel()
            reaperTask = nil
        }
        for session in idleSessions {
            await session.shutdown()
        }
    }

    func shutdownAll() async {
        isShuttingDownAll = true
        defer { isShuttingDownAll = false }

        reaperTask?.cancel()
        reaperTask = nil

        let inFlight = Array(pendingStartTasks.values)
        pendingStartTasks.removeAll()
        for task in inFlight {
            task.cancel()
        }

        let sessions = Array(activeSessions.values)
        activeSessions.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask {
                    await session.shutdown()
                }
            }
        }
    }

    // MARK: - Session Management & Server Auto-Discovery

    private func session(
        workspaceRoot: String,
        languageID: String,
        spawnIfNeeded: Bool
    ) async -> LSPServerSession? {
        guard !isShuttingDownAll, workspaceRoot.hasPrefix("/") else { return nil }
        let normalizedLang = EditorLanguageID.normalizeHint(languageID)
        let serverGroup = EditorLanguageID.lspServerGroup(for: normalizedLang)
            ?? (injectedCommands[normalizedLang] != nil ? normalizedLang : nil)
        guard let serverGroup else { return nil }

        let canonicalRoot = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        let key = ServerKey(workspaceRoot: canonicalRoot, serverGroup: serverGroup)

        if let existing = activeSessions[key] {
            if existing.isAlive {
                existing.touchActivity()
                return existing
            }
            activeSessions.removeValue(forKey: key)
        }

        guard spawnIfNeeded else { return nil }

        if let pending = pendingStartTasks[key] {
            return await pending.value
        }

        let startTask = Task<LSPServerSession?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.spawnAndInitializeSession(
                key: key,
                languageID: normalizedLang
            )
        }
        pendingStartTasks[key] = startTask
        let created = await startTask.value
        pendingStartTasks.removeValue(forKey: key)

        if let created, created.isAlive, !isShuttingDownAll {
            activeSessions[key] = created
            ensureReaperRunning()
            return created
        } else if let created {
            await created.shutdown()
        }
        return nil
    }

    private func ensureReaperRunning() {
        guard reaperTask == nil else { return }
        let interval = reaperInterval
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(Int(interval * 1_000)))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.reapIdleServers(now: Date())
            }
        }
    }

    private func spawnAndInitializeSession(
        key: ServerKey,
        languageID: String
    ) async -> LSPServerSession? {
        guard let command = await resolveServerCommand(
            serverGroup: key.serverGroup,
            languageID: languageID
        ) else {
            return nil
        }

        let baseEnv = await loginEnvironment()
        var mergedEnv = baseEnv
        if let customEnv = command.environment {
            for (k, v) in customEnv {
                mergedEnv[k] = v
            }
        }

        let diagCallback = diagnosticsHandler
        let session = LSPServerSession(
            workspaceRoot: key.workspaceRoot,
            command: command,
            environment: mergedEnv,
            onDiagnostics: { path, diagnostics in
                diagCallback?(path, diagnostics)
            }
        )
        do {
            try await session.startAndInitialize()
            return session
        } catch {
            await session.shutdown()
            return nil
        }
    }

    func resolveServerCommand(
        serverGroup: String,
        languageID: String
    ) async -> EditorLSPServerCommand? {
        if let injected = injectedCommands[languageID] ?? injectedCommands[serverGroup] {
            return injected
        }
        if let cached = resolvedCommandCache[serverGroup] {
            return cached
        }

        let env = await loginEnvironment()
        let pathValue = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let candidates = Self.candidateServersByGroup[serverGroup] ?? []

        let discovered: EditorLSPServerCommand? = await Task.detached(priority: .utility) {
            for candidate in candidates {
                if let executablePath = Self.findExecutable(named: candidate.executable, inPATH: pathValue) {
                    return EditorLSPServerCommand(
                        executable: executablePath,
                        arguments: candidate.arguments
                    )
                }
            }
            if serverGroup == "swift" {
                if let xcrunSwift = Self.findSourceKitLSPViaXcrun(environment: env) {
                    return EditorLSPServerCommand(executable: xcrunSwift, arguments: [])
                }
            }
            return nil
        }.value

        resolvedCommandCache[serverGroup] = discovered
        return discovered
    }

    private func loginEnvironment() async -> [String: String] {
        if let cached = resolvedLoginEnvironment {
            return cached
        }
        if let task = loginEnvironmentTask {
            return await task.value
        }
        let task = Task<[String: String], Never>.detached(priority: .utility) {
            Self.resolveUserLoginEnvironment()
        }
        loginEnvironmentTask = task
        let env = await task.value
        resolvedLoginEnvironment = env
        loginEnvironmentTask = nil
        return env
    }

    nonisolated private static func resolveUserLoginEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let startMarker = "__OMG_LSP_PATH_START__"
        let endMarker = "__OMG_LSP_PATH_END__"

        if FileManager.default.isExecutableFile(atPath: shell),
           let result = try? runBlockingCommand(
               executablePath: shell,
               arguments: ["-lic", "printf '\(startMarker)%s\(endMarker)' \"$PATH\""],
               environment: env,
               timeout: 3.0
           ),
           let startRange = result.range(of: startMarker),
           let endRange = result.range(of: endMarker, range: startRange.upperBound..<result.endIndex) {
            let extractedPath = String(result[startRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !extractedPath.isEmpty {
                env["PATH"] = extractedPath
                return env
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.bun/bin"
        ]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
        return env
    }

    nonisolated private static func runBlockingCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try? stdout.fileHandleForWriting.close()

        let waitResult = exited.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGTERM)
                usleep(80_000)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            try? stdout.fileHandleForReading.close()
            return ""
        }
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        try? stdout.fileHandleForReading.close()
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated static func findExecutable(named binary: String, inPATH pathEnv: String) -> String? {
        if binary.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
        }
        let fm = FileManager.default
        for rawDir in pathEnv.split(separator: ":") where !rawDir.isEmpty {
            let candidate = URL(fileURLWithPath: String(rawDir))
                .appendingPathComponent(binary)
                .path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir),
               !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func findSourceKitLSPViaXcrun(environment: [String: String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"),
              let output = try? runBlockingCommand(
                  executablePath: "/usr/bin/xcrun",
                  arguments: ["--find", "sourcekit-lsp"],
                  environment: environment,
                  timeout: 2.0
              ) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: trimmed) else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Single Stdio LSP Server Session

private final class LSPServerSession: @unchecked Sendable {
    private struct SyncedDocument {
        let languageID: String
        var version: Int
        var text: String
    }

    let workspaceRoot: String
    private let command: EditorLSPServerCommand
    private let environment: [String: String]
    private let onDiagnostics: @Sendable (String, [EditorDiagnostic]) -> Void

    private let ioQueue = DispatchQueue(label: "com.ohmyghostty.editor.lsp.io", qos: .utility)
    private let lock = NSLock()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var framer = LSPMessageFramer()

    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var openDocuments: [String: SyncedDocument] = [:]
    private var lastActivityStorage = Date()
    private var closed = false

    init(
        workspaceRoot: String,
        command: EditorLSPServerCommand,
        environment: [String: String],
        onDiagnostics: @escaping @Sendable (String, [EditorDiagnostic]) -> Void
    ) {
        self.workspaceRoot = workspaceRoot
        self.command = command
        self.environment = environment
        self.onDiagnostics = onDiagnostics
    }

    var lastActivityDate: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastActivityStorage
    }

    var isAlive: Bool {
        lock.lock()
        let proc = process
        let isClosed = closed
        lock.unlock()
        guard !isClosed, let proc else { return false }
        return proc.isRunning
    }

    var processIdentifier: pid_t? {
        lock.lock()
        let proc = process
        lock.unlock()
        return proc?.isRunning == true ? proc?.processIdentifier : nil
    }

    func touchActivity() {
        lock.lock()
        lastActivityStorage = Date()
        lock.unlock()
    }

    func startAndInitialize() async throws {
        try launchProcess()
        let rootURI = Self.fileURI(forPath: workspaceRoot)
        let folderName = (workspaceRoot as NSString).lastPathComponent
        let initParams: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURI,
            "rootPath": workspaceRoot,
            "workspaceFolders": [
                ["uri": rootURI, "name": folderName.isEmpty ? "workspace" : folderName]
            ],
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "dynamicRegistration": false,
                        "willSave": false,
                        "willSaveWaitUntil": false,
                        "didSave": true
                    ],
                    "hover": [
                        "contentFormat": ["markdown", "plaintext"]
                    ],
                    "definition": [
                        "linkSupport": true
                    ],
                    "references": [:],
                    "documentSymbol": [
                        "hierarchicalDocumentSymbolSupport": true
                    ],
                    "completion": [
                        "completionItem": [
                            "snippetSupport": false,
                            "documentationFormat": ["markdown", "plaintext"]
                        ]
                    ],
                    "publishDiagnostics": [
                        "relatedInformation": true
                    ]
                ],
                "workspace": [
                    "workspaceFolders": true
                ]
            ]
        ]

        _ = try await sendRequest(method: "initialize", params: initParams, timeout: 10.0)
        sendNotification(method: "initialized", params: [:])
        touchActivity()
    }

    // MARK: - Document Sync

    func ensureOpen(path: String, languageID: String, text: String) async {
        let uri = Self.fileURI(forPath: path)
        let existing = lock.withLock { openDocuments[uri] }

        if let existing {
            if existing.text != text {
                await didChange(path: path, languageID: languageID, text: text)
            }
        } else {
            await didOpen(path: path, languageID: languageID, text: text)
        }
    }

    func didOpen(path: String, languageID: String, text: String) async {
        touchActivity()
        let uri = Self.fileURI(forPath: path)
        let existingText: String? = lock.withLock {
            if let existing = openDocuments[uri] {
                return existing.text
            }
            openDocuments[uri] = SyncedDocument(languageID: languageID, version: 1, text: text)
            return nil
        }
        if let existingText {
            if existingText != text {
                await didChange(path: path, languageID: languageID, text: text)
            }
            return
        }

        sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": uri,
                    "languageId": languageID,
                    "version": 1,
                    "text": text
                ]
            ]
        )
    }

    func didChange(path: String, languageID: String, text: String) async {
        touchActivity()
        let uri = Self.fileURI(forPath: path)
        let updatedVersion: Int? = lock.withLock {
            guard var doc = openDocuments[uri] else { return nil }
            doc.version += 1
            doc.text = text
            openDocuments[uri] = doc
            return doc.version
        }
        guard let version = updatedVersion else {
            await didOpen(path: path, languageID: languageID, text: text)
            return
        }

        sendNotification(
            method: "textDocument/didChange",
            params: [
                "textDocument": [
                    "uri": uri,
                    "version": version
                ],
                "contentChanges": [
                    ["text": text]
                ]
            ]
        )
    }

    func didSave(path: String, text: String) async {
        touchActivity()
        let uri = Self.fileURI(forPath: path)
        sendNotification(
            method: "textDocument/didSave",
            params: [
                "textDocument": ["uri": uri],
                "text": text
            ]
        )
    }

    func didClose(path: String) async {
        touchActivity()
        let uri = Self.fileURI(forPath: path)
        let removed = lock.withLock { openDocuments.removeValue(forKey: uri) }
        guard removed != nil else { return }

        sendNotification(
            method: "textDocument/didClose",
            params: [
                "textDocument": ["uri": uri]
            ]
        )
    }

    // MARK: - Feature Queries

    func hover(path: String, position: EditorPosition) async -> EditorHoverInfo? {
        touchActivity()
        let params: [String: Any] = [
            "textDocument": ["uri": Self.fileURI(forPath: path)],
            "position": Self.lspPosition(from: position)
        ]
        guard let msg = try? await sendRequest(method: "textDocument/hover", params: params, timeout: 4.0),
              let result = msg["result"] as? [String: Any] else {
            return nil
        }
        guard let contents = result["contents"] else { return nil }
        let markdown = Self.extractHoverMarkdown(contents).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        let range = (result["range"] as? [String: Any]).flatMap(Self.parseLSPRange)
        return EditorHoverInfo(markdown: markdown, range: range)
    }

    func definitions(path: String, position: EditorPosition) async -> [EditorDefinitionLocation] {
        touchActivity()
        let params: [String: Any] = [
            "textDocument": ["uri": Self.fileURI(forPath: path)],
            "position": Self.lspPosition(from: position)
        ]
        guard let msg = try? await sendRequest(method: "textDocument/definition", params: params, timeout: 4.0),
              let result = msg["result"] else {
            return []
        }
        return Self.parseLocations(from: result)
    }

    func references(path: String, position: EditorPosition) async -> [EditorDefinitionLocation] {
        touchActivity()
        let params: [String: Any] = [
            "textDocument": ["uri": Self.fileURI(forPath: path)],
            "position": Self.lspPosition(from: position),
            "context": ["includeDeclaration": true]
        ]
        guard let msg = try? await sendRequest(method: "textDocument/references", params: params, timeout: 5.0),
              let result = msg["result"] else {
            return []
        }
        return Self.parseLocations(from: result)
    }

    func documentSymbols(path: String) async -> [EditorDocumentSymbol] {
        touchActivity()
        let params: [String: Any] = [
            "textDocument": ["uri": Self.fileURI(forPath: path)]
        ]
        guard let msg = try? await sendRequest(method: "textDocument/documentSymbol", params: params, timeout: 4.0),
              let items = msg["result"] as? [[String: Any]] else {
            return []
        }
        return Self.parseDocumentSymbols(items)
    }

    func completions(
        path: String,
        position: EditorPosition,
        triggerCharacter: String?
    ) async -> [CompletionItem] {
        touchActivity()
        var contextDict: [String: Any] = ["triggerKind": triggerCharacter == nil ? 1 : 2]
        if let triggerCharacter, !triggerCharacter.isEmpty {
            contextDict["triggerCharacter"] = triggerCharacter
        }
        let params: [String: Any] = [
            "textDocument": ["uri": Self.fileURI(forPath: path)],
            "position": Self.lspPosition(from: position),
            "context": contextDict
        ]
        guard let msg = try? await sendRequest(method: "textDocument/completion", params: params, timeout: 3.5),
              let result = msg["result"] else {
            return []
        }
        return Self.parseCompletionItems(from: result)
    }

    // MARK: - Graceful Shutdown + SIGTERM/SIGKILL Fallback

    func shutdown() async {
        let shouldSendShutdown = lock.withLock {
            !closed && process?.isRunning == true
        }

        if shouldSendShutdown {
            _ = try? await sendRequest(method: "shutdown", params: nil, timeout: 1.5)
            sendNotification(method: "exit", params: nil)
            try? await Task.sleep(for: .milliseconds(120))
        }

        forceTeardown()
    }

    // MARK: - Process & JSON-RPC Transport

    private func launchProcess() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command.executable)
        proc.arguments = command.arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        proc.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let inWriteHandle = stdinPipe.fileHandleForWriting
        let outReadHandle = stdoutPipe.fileHandleForReading
        let errReadHandle = stderrPipe.fileHandleForReading
        _ = fcntl(inWriteHandle.fileDescriptor, F_SETNOSIGPIPE, 1)

        proc.terminationHandler = { [weak self] _ in
            self?.handleProcessTermination()
        }

        do {
            try proc.run()
        } catch {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw EditorLSPError.launchFailed(error.localizedDescription)
        }

        // Parent closes child-side pipe ends immediately so EOF propagates cleanly.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        lock.lock()
        self.process = proc
        self.stdinHandle = inWriteHandle
        self.stdoutHandle = outReadHandle
        self.stderrHandle = errReadHandle
        lock.unlock()

        outReadHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.handleProcessTermination()
                return
            }
            self?.ioQueue.async { [weak self] in
                self?.consumeStdoutChunk(data)
            }
        }

        // Continuously drain stderr so verbose servers never block on a full 64KB pipe buffer.
        errReadHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        } else {
            payload["params"] = NSNull()
        }
        writeFrame(payload)
    }

    private func sendRequest(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let requestID: Int = try {
            lock.lock()
            defer { lock.unlock() }
            guard !closed, process?.isRunning == true else {
                throw EditorLSPError.connectionClosed
            }
            let id = nextRequestID
            nextRequestID += 1
            return id
        }()

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method
        ]
        if let params {
            payload["params"] = params
        } else {
            payload["params"] = NSNull()
        }

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
            } catch {
                return
            }
            self?.failPendingRequest(id: requestID, error: EditorLSPError.requestTimedOut)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                lock.lock()
                if closed {
                    lock.unlock()
                    continuation.resume(throwing: EditorLSPError.connectionClosed)
                    return
                }
                pendingRequests[requestID] = continuation
                lock.unlock()
                writeFrame(payload)
            }
        } onCancel: { [weak self] in
            self?.failPendingRequest(id: requestID, error: CancellationError())
        }
    }

    private func writeFrame(_ jsonObject: [String: Any]) {
        guard let framed = try? LSPMessageFramer.encode(jsonObject) else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handle = self.closed ? nil : self.stdinHandle
            self.lock.unlock()
            guard let handle else { return }
            try? handle.write(contentsOf: framed)
        }
    }

    private func consumeStdoutChunk(_ chunk: Data) {
        let frames: [Data]
        do {
            frames = try framer.append(chunk)
        } catch {
            forceTeardown()
            return
        }

        for frame in frames {
            guard let obj = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
                continue
            }
            dispatchInboundMessage(obj)
        }
    }

    private func dispatchInboundMessage(_ message: [String: Any]) {
        let method = message["method"] as? String
        let rawID = message["id"]

        // 1. Server -> Client Request (has both `id` and `method`): reply immediately so server never stalls.
        if let method, let rawID, !(rawID is NSNull) {
            let resultValue: Any
            if method == "workspace/configuration",
               let params = message["params"] as? [String: Any],
               let items = params["items"] as? [Any] {
                resultValue = items.map { _ in NSNull() }
            } else {
                resultValue = NSNull()
            }
            writeFrame([
                "jsonrpc": "2.0",
                "id": rawID,
                "result": resultValue
            ])
            return
        }

        // 2. Response to one of our requests (`id` without `method`).
        if let id = Self.parseRequestID(rawID) {
            lock.lock()
            let waiter = pendingRequests.removeValue(forKey: id)
            lock.unlock()
            guard let waiter else { return }

            if let errDict = message["error"] as? [String: Any] {
                let code = (errDict["code"] as? Int) ?? -1
                let errMessage = (errDict["message"] as? String) ?? "LSP error"
                waiter.resume(throwing: EditorLSPError.responseError(code: code, message: errMessage))
            } else {
                waiter.resume(returning: message)
            }
            return
        }

        // 3. Server -> Client Notification (`method` without `id`).
        if method == "textDocument/publishDiagnostics",
           let params = message["params"] as? [String: Any],
           let uri = params["uri"] as? String,
           let filePath = Self.filePath(fromURI: uri) {
            let rawDiags = (params["diagnostics"] as? [[String: Any]]) ?? []
            let parsed = rawDiags.compactMap(Self.parseDiagnostic)
            onDiagnostics(filePath, parsed)
        }
    }

    private func failPendingRequest(id: Int, error: Error) {
        lock.lock()
        let waiter = pendingRequests.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    private func handleProcessTermination() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let waiters = Array(pendingRequests.values)
        pendingRequests.removeAll()
        openDocuments.removeAll()
        let inHandle = stdinHandle
        let outHandle = stdoutHandle
        let errHandle = stderrHandle
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        lock.unlock()

        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        try? inHandle?.close()
        try? outHandle?.close()
        try? errHandle?.close()

        for waiter in waiters {
            waiter.resume(throwing: EditorLSPError.connectionClosed)
        }
    }

    private func forceTeardown() {
        lock.lock()
        let proc = process
        lock.unlock()

        handleProcessTermination()

        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        if pid > 0 {
            Darwin.kill(pid, SIGTERM)
            ioQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                if proc.isRunning {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: - LSP Payload Translators

    private static func parseRequestID(_ raw: Any?) -> Int? {
        if let intID = raw as? Int { return intID }
        if let numID = raw as? NSNumber { return numID.intValue }
        if let strID = raw as? String { return Int(strID) }
        return nil
    }

    private static func fileURI(forPath path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    private static func filePath(fromURI uri: String) -> String? {
        if let url = URL(string: uri), url.isFileURL {
            return url.path
        }
        if uri.hasPrefix("file://") {
            let stripped = String(uri.dropFirst("file://".count))
            return stripped.removingPercentEncoding ?? stripped
        }
        return nil
    }

    private static func lspPosition(from position: EditorPosition) -> [String: Int] {
        [
            "line": position.zeroBasedLine,
            "character": position.zeroBasedColumn
        ]
    }

    private static func parseLSPRange(_ dict: [String: Any]) -> EditorRange? {
        guard let startDict = dict["start"] as? [String: Any],
              let endDict = dict["end"] as? [String: Any],
              let startLine = startDict["line"] as? Int,
              let startChar = startDict["character"] as? Int,
              let endLine = endDict["line"] as? Int,
              let endChar = endDict["character"] as? Int else {
            return nil
        }
        return EditorRange(
            start: .fromZeroBased(line: startLine, character: startChar),
            end: .fromZeroBased(line: endLine, character: endChar)
        )
    }

    private static func parseDiagnostic(_ dict: [String: Any]) -> EditorDiagnostic? {
        guard let message = dict["message"] as? String,
              let rangeDict = dict["range"] as? [String: Any],
              let range = parseLSPRange(rangeDict) else {
            return nil
        }
        let severity = EditorDiagnostic.Severity.fromLSP(dict["severity"] as? Int)
        let source = dict["source"] as? String
        return EditorDiagnostic(severity: severity, message: message, source: source, range: range)
    }

    private static func extractHoverMarkdown(_ contents: Any) -> String {
        if let str = contents as? String {
            return str
        }
        if let dict = contents as? [String: Any] {
            if let value = dict["value"] as? String {
                if let language = dict["language"] as? String, !language.isEmpty {
                    return "```\(language)\n\(value)\n```"
                }
                return value
            }
        }
        if let array = contents as? [Any] {
            return array
                .map { extractHoverMarkdown($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        return ""
    }

    private static func parseLocations(from raw: Any) -> [EditorDefinitionLocation] {
        if let single = raw as? [String: Any] {
            return parseSingleLocation(single).map { [$0] } ?? []
        }
        guard let list = raw as? [[String: Any]] else { return [] }
        var locations: [EditorDefinitionLocation] = []
        var seen = Set<EditorDefinitionLocation>()
        for item in list {
            if let parsed = parseSingleLocation(item), seen.insert(parsed).inserted {
                locations.append(parsed)
            }
        }
        return locations
    }

    private static func parseSingleLocation(_ dict: [String: Any]) -> EditorDefinitionLocation? {
        // `Location`: `{ uri, range }`
        if let uri = dict["uri"] as? String,
           let path = filePath(fromURI: uri),
           let rangeDict = dict["range"] as? [String: Any],
           let range = parseLSPRange(rangeDict) {
            return EditorDefinitionLocation(path: path, range: range, preview: nil)
        }
        // `LocationLink`: `{ targetUri, targetSelectionRange, targetRange }`
        if let targetURI = dict["targetUri"] as? String,
           let path = filePath(fromURI: targetURI) {
            let rangeDict = (dict["targetSelectionRange"] as? [String: Any])
                ?? (dict["targetRange"] as? [String: Any])
            if let rangeDict, let range = parseLSPRange(rangeDict) {
                return EditorDefinitionLocation(path: path, range: range, preview: nil)
            }
        }
        return nil
    }

    private static func parseDocumentSymbols(_ items: [[String: Any]]) -> [EditorDocumentSymbol] {
        var flattened: [EditorDocumentSymbol] = []
        func visit(_ dict: [String: Any]) {
            guard let name = dict["name"] as? String, !name.isEmpty else { return }
            let kindInt = (dict["kind"] as? Int) ?? 13
            let kind = EditorDocumentSymbol.SymbolKind.fromLSP(kindInt)

            // Hierarchical `DocumentSymbol`
            if let rangeDict = dict["range"] as? [String: Any],
               let range = parseLSPRange(rangeDict) {
                let selRange = (dict["selectionRange"] as? [String: Any]).flatMap(parseLSPRange) ?? range
                let detail = dict["detail"] as? String
                flattened.append(
                    EditorDocumentSymbol(
                        name: name,
                        detail: detail,
                        kind: kind,
                        range: range,
                        selectionRange: selRange
                    )
                )
                if let children = dict["children"] as? [[String: Any]] {
                    for child in children {
                        visit(child)
                    }
                }
                return
            }

            // Legacy `SymbolInformation`
            if let loc = dict["location"] as? [String: Any],
               let rangeDict = loc["range"] as? [String: Any],
               let range = parseLSPRange(rangeDict) {
                let detail = dict["containerName"] as? String
                flattened.append(
                    EditorDocumentSymbol(
                        name: name,
                        detail: detail,
                        kind: kind,
                        range: range,
                        selectionRange: range
                    )
                )
            }
        }

        for item in items {
            visit(item)
        }
        return flattened
    }

    private static func parseCompletionItems(from raw: Any) -> [CompletionItem] {
        let rawItems: [[String: Any]]
        if let list = raw as? [[String: Any]] {
            rawItems = list
        } else if let dict = raw as? [String: Any],
                  let items = dict["items"] as? [[String: Any]] {
            rawItems = items
        } else {
            return []
        }

        var items: [CompletionItem] = []
        items.reserveCapacity(min(rawItems.count, 60))
        for (idx, rawItem) in rawItems.prefix(100).enumerated() {
            guard let label = rawItem["label"] as? String, !label.isEmpty else { continue }
            let textEditText = (rawItem["textEdit"] as? [String: Any])?["newText"] as? String
            let rawInsert = textEditText ?? (rawItem["insertText"] as? String) ?? label
            let cleanInsert = stripSnippetTabstops(rawInsert)
            let kindCode = (rawItem["kind"] as? Int) ?? 1
            let kind = mapLSPCompletionKind(kindCode)
            let detail = rawItem["detail"] as? String
            let score = max(200.0 - Double(idx) * 0.5, 160.0)
            items.append(
                CompletionItem(
                    label: label,
                    insertText: cleanInsert.isEmpty ? label : cleanInsert,
                    kind: kind,
                    detail: detail,
                    score: score
                )
            )
        }
        return items
    }

    private static func stripSnippetTabstops(_ text: String) -> String {
        guard text.contains("$") else { return text }
        // Convert `${1:placeholder}` -> `placeholder` and remove `$0`, `$1`, etc.
        let withPlaceholders = text.replacingOccurrences(
            of: #"\$\{\d+:([^}]*)\}"#,
            with: "$1",
            options: .regularExpression
        )
        return withPlaceholders.replacingOccurrences(
            of: #"\$\{\d+\}|\$\d+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func mapLSPCompletionKind(_ code: Int) -> CompletionItemKind {
        switch code {
        case 2, 3, 4: // Method, Function, Constructor
            return .function
        case 5, 10: // Field, Property
            return .property
        case 6, 21: // Variable, Constant
            return .variable
        case 7, 8, 9, 13, 22, 25: // Class, Interface, Module, Enum, Struct, TypeParameter
            return .type
        case 14: // Keyword
            return .keyword
        case 15: // Snippet
            return .snippet
        default:
            return .text
        }
    }
}

// MARK: - Unified Facade (`EditorIntelligenceCoordinator`)

/// Context describing an open document for code intelligence queries.
/// Enforces strict SSH safety: when `isLocal == false`, neither local LSP servers nor local
/// filesystem directory walks are ever invoked.
struct EditorIntelligenceDocumentContext: Equatable, Sendable {
    let path: String
    let languageID: String
    let workspaceRoot: String?
    let isLocal: Bool

    init(
        path: String,
        languageHint: String? = nil,
        workspaceRoot: String? = nil,
        isLocal: Bool = true
    ) {
        self.path = path
        self.languageID = EditorLanguageID.detect(path: path, explicitHint: languageHint)
        self.isLocal = isLocal
        self.workspaceRoot = isLocal ? workspaceRoot : nil
    }

    @MainActor
    init(document: EditorDocument, languageHint: String? = nil) {
        let local = document.id.endpoint == .local
        let root = local ? document.filesystem.descriptor.workingDirectory : nil
        self.init(
            path: document.path,
            languageHint: languageHint,
            workspaceRoot: root,
            isLocal: local
        )
    }

    fileprivate var effectiveLocalRoot: String? {
        guard isLocal else { return nil }
        if let workspaceRoot, workspaceRoot.hasPrefix("/") {
            return workspaceRoot
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}

/// Unified intelligence coordinator combining `EditorLSPManager` (when a local language server is
/// installed) with instant zero-process fallback & merging via `EditorSymbolIndex` and `EditorCompletionEngine`.
@MainActor
final class EditorIntelligenceCoordinator {
    var onDiagnostics: ((String, [EditorDiagnostic]) -> Void)?

    let lspManager: EditorLSPManager
    let symbolIndex: EditorSymbolIndex
    let completionEngine: EditorCompletionEngine

    init(
        lspManager: EditorLSPManager? = nil,
        symbolIndex: EditorSymbolIndex = EditorSymbolIndex(),
        completionEngine: EditorCompletionEngine? = nil
    ) {
        let resolvedLSP = lspManager ?? EditorLSPManager()
        self.lspManager = resolvedLSP
        self.symbolIndex = symbolIndex
        self.completionEngine = completionEngine ?? EditorCompletionEngine()

        Task { [weak self] in
            await resolvedLSP.setDiagnosticsHandler { [weak self] path, diagnostics in
                Task { @MainActor [weak self] in
                    self?.onDiagnostics?(path, diagnostics)
                }
            }
        }
    }

    // MARK: - Document Lifecycle Sync

    func documentDidOpen(_ context: EditorIntelligenceDocumentContext, text: String) async {
        await symbolIndex.updateOpenDocument(
            path: context.path,
            text: text,
            languageID: context.languageID
        )
        if let localRoot = context.effectiveLocalRoot {
            await lspManager.didOpen(
                .init(
                    path: context.path,
                    languageID: context.languageID,
                    text: text,
                    workspaceRoot: localRoot
                )
            )
        }
    }

    func documentDidChange(_ context: EditorIntelligenceDocumentContext, text: String) async {
        await symbolIndex.updateOpenDocument(
            path: context.path,
            text: text,
            languageID: context.languageID
        )
        if let localRoot = context.effectiveLocalRoot {
            await lspManager.didChange(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot
            )
        }
    }

    func documentDidSave(_ context: EditorIntelligenceDocumentContext, text: String) async {
        await symbolIndex.updateOpenDocument(
            path: context.path,
            text: text,
            languageID: context.languageID
        )
        if let localRoot = context.effectiveLocalRoot {
            await lspManager.didSave(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot
            )
        }
    }

    func documentDidClose(_ context: EditorIntelligenceDocumentContext) async {
        await symbolIndex.removeOpenDocument(path: context.path)
        if let localRoot = context.effectiveLocalRoot {
            await lspManager.didClose(
                path: context.path,
                languageID: context.languageID,
                workspaceRoot: localRoot
            )
        }
        onDiagnostics?(context.path, [])
    }

    func shutdown() async {
        await symbolIndex.clearOpenDocuments()
        await lspManager.shutdownAll()
    }

    // MARK: - Unified Intelligence Queries

    func hover(
        for context: EditorIntelligenceDocumentContext,
        text: String,
        at position: EditorPosition
    ) async -> EditorHoverInfo? {
        if let localRoot = context.effectiveLocalRoot {
            let query = EditorLSPManager.DocumentQuery(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot,
                position: position
            )
            if let lspHover = await lspManager.hover(query) {
                return lspHover
            }
        }

        guard let wordHit = EditorSymbolIndex.wordAtPosition(in: text, position: position) else {
            return nil
        }
        guard let fallback = await symbolIndex.hoverInfo(
            symbol: wordHit.word,
            currentPath: context.path,
            currentText: text,
            workspaceRoot: context.effectiveLocalRoot
        ) else {
            return nil
        }
        return EditorHoverInfo(markdown: fallback.markdown, range: fallback.range ?? wordHit.range)
    }

    func definitions(
        for context: EditorIntelligenceDocumentContext,
        text: String,
        at position: EditorPosition
    ) async -> [EditorDefinitionLocation] {
        if let localRoot = context.effectiveLocalRoot {
            let query = EditorLSPManager.DocumentQuery(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot,
                position: position
            )
            let lspDefs = await lspManager.definitions(query)
            if !lspDefs.isEmpty {
                return lspDefs
            }
        }

        guard let wordHit = EditorSymbolIndex.wordAtPosition(in: text, position: position) else {
            return []
        }
        return await symbolIndex.findDefinitions(
            symbol: wordHit.word,
            currentPath: context.path,
            currentText: text,
            workspaceRoot: context.effectiveLocalRoot
        )
    }

    func references(
        for context: EditorIntelligenceDocumentContext,
        text: String,
        at position: EditorPosition
    ) async -> [EditorDefinitionLocation] {
        if let localRoot = context.effectiveLocalRoot {
            let query = EditorLSPManager.DocumentQuery(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot,
                position: position
            )
            let lspRefs = await lspManager.references(query)
            if !lspRefs.isEmpty {
                return lspRefs
            }
        }

        guard let wordHit = EditorSymbolIndex.wordAtPosition(in: text, position: position) else {
            return []
        }
        return await symbolIndex.findReferences(
            symbol: wordHit.word,
            currentPath: context.path,
            currentText: text,
            workspaceRoot: context.effectiveLocalRoot
        )
    }

    func documentSymbols(
        for context: EditorIntelligenceDocumentContext,
        text: String
    ) async -> [EditorDocumentSymbol] {
        if let localRoot = context.effectiveLocalRoot {
            let lspSymbols = await lspManager.documentSymbols(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot
            )
            if !lspSymbols.isEmpty {
                return lspSymbols
            }
        }
        return await symbolIndex.documentSymbols(
            path: context.path,
            text: text,
            languageID: context.languageID
        )
    }

    func completions(
        for context: EditorIntelligenceDocumentContext,
        text: String,
        at position: EditorPosition,
        triggerCharacter: String? = nil
    ) async -> [CompletionItem] {
        var merged: [CompletionItem] = []
        var seenLabels = Set<String>()

        func appendUnique(_ items: [CompletionItem]) {
            for item in items where seenLabels.insert(item.label).inserted {
                merged.append(item)
            }
        }

        // 1. Primary: Local LSP server completions when available.
        if let localRoot = context.effectiveLocalRoot {
            let query = EditorLSPManager.DocumentQuery(
                path: context.path,
                languageID: context.languageID,
                text: text,
                workspaceRoot: localRoot,
                position: position
            )
            let lspItems = await lspManager.completions(query, triggerCharacter: triggerCharacter)
            appendUnique(lspItems)
        }

        // 2. Secondary: Cross-file workspace symbol completions + buffer/keyword completions.
        let cursorSnapshot = Self.buildCompletionContext(
            text: text,
            position: position,
            languageID: context.languageID,
            path: context.path,
            isLocal: context.isLocal
        )
        if !cursorSnapshot.prefix.isEmpty {
            let symbolItems = await symbolIndex.workspaceCompletions(
                prefix: cursorSnapshot.prefix,
                currentPath: context.path,
                workspaceRoot: context.effectiveLocalRoot,
                limit: 20
            )
            appendUnique(symbolItems)
        }

        let fallbackItems = await completionEngine.completions(for: cursorSnapshot)
        appendUnique(fallbackItems)

        merged.sort {
            $0.score == $1.score ? $0.label < $1.label : $0.score > $1.score
        }
        return Array(merged.prefix(40))
    }

    // MARK: - Cursor Offset & Prefix Helper

    nonisolated private static func buildCompletionContext(
        text: String,
        position: EditorPosition,
        languageID: String,
        path: String,
        isLocal: Bool
    ) -> CompletionContext {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let targetLineIdx = min(max(0, position.line - 1), max(0, lines.count - 1))

        var utf16Offset = 0
        if targetLineIdx > 0 {
            for i in 0..<targetLineIdx {
                utf16Offset += lines[i].utf16.count + 1 // +1 for `\n`
            }
        }

        let lineText = lines.isEmpty ? "" : String(lines[targetLineIdx])
        let lineUTF16 = Array(lineText.utf16)
        let columnInLine = min(max(0, position.column - 1), lineUTF16.count)
        utf16Offset += columnInLine

        var prefixStart = columnInLine
        while prefixStart > 0 {
            let unit = lineUTF16[prefixStart - 1]
            let isIdent = (unit >= 48 && unit <= 57)
                || (unit >= 65 && unit <= 90)
                || (unit >= 97 && unit <= 122)
                || unit == 95
                || unit == 36
            if isIdent {
                prefixStart -= 1
            } else {
                break
            }
        }
        let prefix = String(decoding: Array(lineUTF16[prefixStart..<columnInLine]), as: UTF16.self)

        return CompletionContext(
            documentText: text,
            cursorOffset: utf16Offset,
            prefix: prefix,
            lineText: lineText,
            language: languageID,
            fileURL: isLocal && path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
        )
    }
}
