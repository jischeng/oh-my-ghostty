import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct EditorIntelligenceTests {
    // MARK: - Types & Language Mapping

    @Test
    func intelligenceModelsRoundTripAndMapToMonacoBridge() throws {
        let pos = EditorPosition.fromZeroBased(line: 0, character: 4)
        #expect(pos == EditorPosition(line: 1, column: 5))
        #expect(pos.zeroBasedLine == 0)
        #expect(pos.zeroBasedColumn == 4)

        let range = EditorRange(startLine: 10, startColumn: 3, endLine: 12, endColumn: 8)
        #expect(range.textLocation == EditorTextLocation(startLine: 10, column: 3, endLine: 12))

        let diag = EditorDiagnostic(
            severity: .fromLSP(1),
            message: "Cannot find 'foo' in scope",
            source: "sourcekit-lsp",
            range: range
        )
        #expect(diag.severity == .error)
        #expect(diag.severity.monacoSeverity == 8)
        let encoded = try JSONEncoder().encode(diag)
        let decoded = try JSONDecoder().decode(EditorDiagnostic.self, from: encoded)
        #expect(decoded == diag)

        #expect(EditorLanguageID.detect(path: "/repo/src/main.zig") == "zig")
        #expect(EditorLanguageID.detect(path: "/repo/App.tsx") == "typescriptreact")
        #expect(EditorLanguageID.lspServerGroup(for: "typescriptreact") == "typescript")
        #expect(EditorLanguageID.lspServerGroup(for: "javascript") == "typescript")
        #expect(EditorLanguageID.lspServerGroup(for: "cpp") == "clangd")
        #expect(EditorLanguageID.lspServerGroup(for: "c") == "clangd")
    }

    // MARK: - Git Gutter Unified Diff Parser & Local Git Integration

    @Test
    func gitGutterParserHandlesAddedModifiedDeletedAndSingleLineHunks() {
        let sampleDiff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1234567..89abcdef 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -2,0 +3,2 @@ struct App {
        +    let addedOne = 1
        +    let addedTwo = 2
        @@ -7 +9 @@ struct App {
        -    let oldVal = false
        +    let oldVal = true
        @@ -12,3 +13,0 @@ struct App {
        -    func removedA() {}
        -    func removedB() {}
        -    func removedC() {}
        @@ -20,2 +19,3 @@ struct App {
        -    let x = 1
        -    let y = 2
        +    let x = 10
        +    let y = 20
        +    let z = 30
        """

        let gutter = EditorGitGutterService.parseUnifiedDiff(sampleDiff)
        #expect(gutter[3] == .added)
        #expect(gutter[4] == .added)
        #expect(gutter[9] == .modified)
        #expect(gutter[13] == .deleted)
        #expect(gutter[19] == .modified)
        #expect(gutter[20] == .modified)
        #expect(gutter[21] == .modified)
        #expect(gutter[1] == nil)

        let payload = EditorGitGutterService.bridgePayload(from: gutter)
        #expect(payload["3"] == "added")
        #expect(payload["9"] == "modified")
        #expect(payload["13"] == "deleted")

        // Top-of-file deletion (`+0,0`) anchors cleanly on line 1.
        let topDeleteDiff = "@@ -1,2 +0,0 @@\n-first\n-second\n"
        #expect(EditorGitGutterService.parseUnifiedDiff(topDeleteDiff) == [1: .deleted])
        #expect(EditorGitGutterService.parseUnifiedDiff("").isEmpty)
    }

    @Test
    func gitGutterServiceComputesRealLocalWorkingTreeDiffAndExecutorDiff() async throws {
        let repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-gutter-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let gitExec = LocalGitExecutor()
        _ = try await gitExec.execute(arguments: ["init"], workingDirectory: repoDir.path)
        _ = try await gitExec.execute(arguments: ["config", "user.email", "test@omg.local"], workingDirectory: repoDir.path)
        _ = try await gitExec.execute(arguments: ["config", "user.name", "OMG Test"], workingDirectory: repoDir.path)

        let fileURL = repoDir.appendingPathComponent("main.swift")
        let initial = "line1\nline2\nline3\nline4\n"
        try Data(initial.utf8).write(to: fileURL)
        _ = try await gitExec.execute(arguments: ["add", "main.swift"], workingDirectory: repoDir.path)
        _ = try await gitExec.execute(arguments: ["commit", "-m", "initial"], workingDirectory: repoDir.path)

        let service = EditorGitGutterService()
        let cleanGutter = await service.diffLines(forFileAt: fileURL.path, workingDirectory: repoDir.path)
        #expect(cleanGutter.isEmpty)

        // Modify line 2, delete line 4, and append line 5.
        let edited = "line1\nline2_modified\nline3\n"
        try Data(edited.utf8).write(to: fileURL)

        let localGutter = await service.diffLines(forFileAt: fileURL.path, workingDirectory: repoDir.path)
        #expect(localGutter[2] == .modified)
        #expect(localGutter[3] == .deleted)

        // Verify SSH-compatible GitExecutor overload feeds into the exact same parser.
        let mockSSHExecutor = StubDiffGitExecutor(
            diffOutput: "@@ -10,0 +11,2 @@\n+newA\n+newB\n"
        )
        let remoteGutter = await service.diffLines(
            forFileAt: "/remote/repo/src/lib.rs",
            repositoryRoot: "/remote/repo",
            executor: mockSSHExecutor
        )
        #expect(remoteGutter == [11: .added, 12: .added])
    }

    // MARK: - Symbol Extraction & Bounded Workspace Index

    @Test
    func symbolExtractorCoversMultiLanguageDeclarationsAndMarkdownHeadings() {
        let swiftSource = """
        import Foundation
        /*
        func ignoredInsideBlockComment() {}
        */
        /// Coordinates workspace tabs.
        @MainActor
        public final class WorkspaceCoordinator {
            public protocol Delegate {}
            enum State { case ready }
            struct Configuration {}
            public func activateTab(index: Int) {}
        }
        """
        let swiftSymbols = EditorSymbolIndex.extractSymbols(from: swiftSource, languageID: "swift")
        let swiftNames = swiftSymbols.map(\.name)
        #expect(swiftNames == ["WorkspaceCoordinator", "Delegate", "State", "Configuration", "activateTab"])
        #expect(!swiftNames.contains("ignoredInsideBlockComment"))

        let rustAndZig = """
        pub const MAX_ITEMS: usize = 64;
        pub trait Renderable {}
        pub struct Surface {}
        impl Display for Surface {
            pub fn draw(&self) {}
        }
        """
        let rustSymbols = EditorSymbolIndex.extractSymbols(from: rustAndZig, languageID: "rust")
        #expect(rustSymbols.map(\.name) == ["MAX_ITEMS", "Renderable", "Surface", "Surface", "draw"])

        let zigSource = """
        pub const Renderer = struct {
            pub fn renderFrame() void {}
        };
        pub const ColorMode = enum { dark, light };
        """
        let zigSymbols = EditorSymbolIndex.extractSymbols(from: zigSource, languageID: "zig")
        #expect(zigSymbols.map(\.name) == ["Renderer", "renderFrame", "ColorMode"])
        #expect(zigSymbols.first?.kind == .struct)
        #expect(zigSymbols.last?.kind == .enum)

        let goSource = """
        package server
        type Handler interface {}
        type HTTPServer struct {}
        func (s *HTTPServer) Listen() error { return nil }
        func NewHTTPServer() *HTTPServer { return nil }
        """
        let goSymbols = EditorSymbolIndex.extractSymbols(from: goSource, languageID: "go")
        #expect(goSymbols.map(\.name) == ["Handler", "HTTPServer", "Listen", "NewHTTPServer"])

        let pythonAndTS = """
        class Pipeline:
            def __init__(self):
                pass
            async def execute_step(self):
                pass
        """
        let pySymbols = EditorSymbolIndex.extractSymbols(from: pythonAndTS, languageID: "python")
        #expect(pySymbols.map(\.name) == ["Pipeline", "__init__", "execute_step"])

        let tsSource = """
        export interface EditorOptions {}
        export type ThemeName = "dark" | "light";
        export const createBridge = async () => {};
        export function mountEditor() {}
        """
        let tsSymbols = EditorSymbolIndex.extractSymbols(from: tsSource, languageID: "typescript")
        #expect(tsSymbols.map(\.name) == ["EditorOptions", "ThemeName", "createBridge", "mountEditor"])

        let markdown = """
        # Architecture Overview

        ```bash
        # shell comment inside fence must not become a heading!
        echo hello
        ```

        ## Intelligence Layer ###
        ### File Watcher
        """
        let mdSymbols = EditorSymbolIndex.extractSymbols(from: markdown, languageID: "markdown")
        #expect(mdSymbols.map(\.name) == ["Architecture Overview", "Intelligence Layer", "File Watcher"])
        #expect(mdSymbols.map(\.detail) == ["H1", "H2", "H3"])
    }

    @Test
    func workspaceSymbolIndexResolvesCrossFileDefinitionsAndSkipsExcludedPaths() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-symbol-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let srcDir = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        let engineFile = srcDir.appendingPathComponent("Engine.swift")
        try Data("""
        /// High-speed token stream engine.
        struct TokenStreamEngine {
            func tokenizeLine() {}
        }
        """.utf8).write(to: engineFile)

        let callerFile = srcDir.appendingPathComponent("Caller.swift")
        let callerText = """
        func run() {
            let engine = TokenStreamEngine()
        }
        """
        try Data(callerText.utf8).write(to: callerFile)

        // Populate skipped directories (`node_modules`, `.git`, `zig-cache`, `zig-out`, `build-debug`, `.build`, `target`)
        for skipped in [".git", "node_modules", "zig-cache", "zig-out", "build-debug", ".build", "target"] {
            let skippedDir = workspace.appendingPathComponent(skipped, isDirectory: true)
            try FileManager.default.createDirectory(at: skippedDir, withIntermediateDirectories: true)
            try Data("struct IgnoredSymbolInSkippedDir {}\n".utf8)
                .write(to: skippedDir.appendingPathComponent("Trap.swift"))
        }

        // Binary file with `.swift` extension and >512KB oversized file must also be skipped.
        try Data([0x00, 0x01, 0x02, 0x66, 0x75, 0x6E, 0x63]).write(to: srcDir.appendingPathComponent("Binary.swift"))
        let hugeText = "struct OversizedSymbol {}\n" + String(repeating: "// padding\n", count: 60_000)
        try Data(hugeText.utf8).write(to: srcDir.appendingPathComponent("Oversized.swift"))

        let index = EditorSymbolIndex()

        let defs = await index.findDefinitions(
            symbol: "TokenStreamEngine",
            currentPath: callerFile.path,
            currentText: callerText,
            workspaceRoot: workspace.path
        )
        #expect(defs.count == 1)
        #expect(defs.first?.path == engineFile.path.resolvingSymlinksIfNeeded(matching: defs.first?.path))
        #expect(defs.first?.range.startLine == 2)
        #expect(defs.first?.preview?.contains("struct TokenStreamEngine") == true)

        // Ignored & oversized symbols must never appear.
        let skippedDefs = await index.findDefinitions(
            symbol: "IgnoredSymbolInSkippedDir",
            currentPath: callerFile.path,
            currentText: callerText,
            workspaceRoot: workspace.path
        )
        #expect(skippedDefs.isEmpty)

        let hugeDefs = await index.findDefinitions(
            symbol: "OversizedSymbol",
            currentPath: callerFile.path,
            currentText: callerText,
            workspaceRoot: workspace.path
        )
        #expect(hugeDefs.isEmpty)

        // Hover fallback includes doc comment & signature block.
        let hover = await index.hoverInfo(
            symbol: "TokenStreamEngine",
            currentPath: callerFile.path,
            currentText: callerText,
            workspaceRoot: workspace.path
        )
        #expect(hover?.markdown.contains("struct TokenStreamEngine") == true)
        #expect(hover?.markdown.contains("High-speed token stream engine.") == true)

        // Cross-file workspace symbol completion.
        let completions = await index.workspaceCompletions(
            prefix: "TokenStr",
            currentPath: callerFile.path,
            workspaceRoot: workspace.path
        )
        #expect(completions.contains { $0.label == "TokenStreamEngine" && $0.kind == .type })

        // SSH mode (`workspaceRoot: nil`) never scans local disk, only open buffers!
        let sshIndex = EditorSymbolIndex()
        await sshIndex.updateOpenDocument(
            path: "/remote/ssh/Helper.py",
            text: "def compute_remote_hash():\n    return 42\n",
            languageID: "python"
        )
        let sshDiskLeakCheck = await sshIndex.findDefinitions(
            symbol: "TokenStreamEngine",
            currentPath: callerFile.path,
            currentText: "x = compute_remote_hash()\n",
            workspaceRoot: nil
        )
        #expect(sshDiskLeakCheck.isEmpty)

        let sshOpenTabDefs = await sshIndex.findDefinitions(
            symbol: "compute_remote_hash",
            currentPath: "/remote/ssh/Main.py",
            currentText: "x = compute_remote_hash()\n",
            workspaceRoot: nil
        )
        #expect(sshOpenTabDefs.count == 1)
        #expect(sshOpenTabDefs.first?.path == "/remote/ssh/Helper.py")
    }

    // MARK: - JSON-RPC Framing & Real Mock Python3 Stdio LSP Server

    @Test
    func lspMessageFramerHandlesFragmentedMultibyteUTF8AndConcatenatedFrames() throws {
        var framer = LSPMessageFramer()
        let firstFrame = try LSPMessageFramer.encode([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["markdown": "Hello 🚀 世界 — UTF-8 byte framing!"]
        ])
        let secondFrame = try LSPMessageFramer.encode([
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": [:]
        ])

        var combined = Data()
        combined.append(firstFrame)
        combined.append(secondFrame)

        // Feed in 7-byte slices to split right across `\r\n\r\n` and multi-byte emoji sequences.
        var decodedObjects: [[String: Any]] = []
        var offset = 0
        while offset < combined.count {
            let end = min(offset + 7, combined.count)
            let chunk = combined.subdata(in: offset..<end)
            let frames = try framer.append(chunk)
            for payload in frames {
                let obj = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                decodedObjects.append(obj)
            }
            offset = end
        }

        #expect(decodedObjects.count == 2)
        let resultDict = decodedObjects.first?["result"] as? [String: Any]
        #expect(resultDict?["markdown"] as? String == "Hello 🚀 世界 — UTF-8 byte framing!")
        #expect(decodedObjects.last?["method"] as? String == "initialized")
    }

    @Test @MainActor
    func coordinatorAndLSPManagerRoundTripWithRealPython3StdioServerAndIdleReaper() async throws {
        let pythonPath = try #require(Self.resolveRealPython3Executable())

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-mock-lsp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let serverScriptURL = tempDir.appendingPathComponent("mock_lsp_server.py")
        let shutdownMarkerURL = tempDir.appendingPathComponent("shutdown_received.txt")
        try Data(Self.mockPythonLSPServerScript.utf8).write(to: serverScriptURL)

        let sourceURL = tempDir.appendingPathComponent("demo.py")
        let targetDefURL = tempDir.appendingPathComponent("models.py")
        let sourceText = """
        from models import HyperEngine

        def run_task():
            engine = HyperEngine()
            return engine
        """
        try Data(sourceText.utf8).write(to: sourceURL)
        try Data("class HyperEngine:\n    pass\n".utf8).write(to: targetDefURL)

        let customCmd = EditorLSPServerCommand(
            executable: pythonPath,
            arguments: ["-u", serverScriptURL.path],
            environment: ["OMG_MOCK_SHUTDOWN_FILE": shutdownMarkerURL.path]
        )

        let lspManager = EditorLSPManager(
            serverCommands: ["python": customCmd],
            idleTimeout: 0.35,
            reaperInterval: 0.10
        )
        let coordinator = EditorIntelligenceCoordinator(lspManager: lspManager)

        var receivedDiagnostics: [String: [EditorDiagnostic]] = [:]
        coordinator.onDiagnostics = { path, diags in
            receivedDiagnostics[path] = diags
        }

        let docContext = EditorIntelligenceDocumentContext(
            path: sourceURL.path,
            languageHint: "python",
            workspaceRoot: tempDir.path,
            isLocal: true
        )

        // 1. SSH document must NEVER spawn local LSP server!
        let sshContext = EditorIntelligenceDocumentContext(
            path: "/remote/app.py",
            languageHint: "python",
            workspaceRoot: "/remote",
            isLocal: false
        )
        await coordinator.documentDidOpen(sshContext, text: "def remote_only():\n    pass\n")
        #expect(await lspManager.activeServerCount == 0)
        let sshSymbols = await coordinator.documentSymbols(for: sshContext, text: "def remote_only():\n    pass\n")
        #expect(sshSymbols.map(\.name) == ["remote_only"])

        // 2. Local `didOpen` spawns server lazily, completes `initialize` -> `initialized`,
        //    answers server->client `window/workDoneProgress/create`, and receives `publishDiagnostics`!
        await coordinator.documentDidOpen(docContext, text: sourceText)
        #expect(await lspManager.activeServerCount == 1)
        let firstPID = try #require(await lspManager.activeServerPIDs().first)

        let gotDiags = await waitForMainCondition(timeoutMs: 2_500) {
            receivedDiagnostics[sourceURL.resolvingSymlinksInPath().path]?.count == 1
                || receivedDiagnostics[sourceURL.path]?.count == 1
        }
        #expect(gotDiags)
        let diagList = receivedDiagnostics[sourceURL.resolvingSymlinksInPath().path]
            ?? receivedDiagnostics[sourceURL.path] ?? []
        #expect(diagList.first?.severity == .warning)
        #expect(diagList.first?.message == "Mock lint: unused return value")
        #expect(diagList.first?.range == EditorRange(startLine: 4, startColumn: 5, endLine: 4, endColumn: 11))

        // Opening a second Python file in the same workspace reuses the SINGLE running server PID!
        let secondContext = EditorIntelligenceDocumentContext(
            path: targetDefURL.path,
            languageHint: "python",
            workspaceRoot: tempDir.path,
            isLocal: true
        )
        await coordinator.documentDidOpen(secondContext, text: "class HyperEngine:\n    pass\n")
        #expect(await lspManager.activeServerCount == 1)
        #expect(await lspManager.activeServerPIDs() == [firstPID])

        // 3. `textDocument/hover`
        let hover = await coordinator.hover(
            for: docContext,
            text: sourceText,
            at: EditorPosition(line: 4, column: 15)
        )
        #expect(hover?.markdown.contains("HyperEngine(mode: str = 'fast')") == true)
        #expect(hover?.range == EditorRange(startLine: 4, startColumn: 14, endLine: 4, endColumn: 25))

        // 4. `textDocument/definition` & `textDocument/references`
        let defs = await coordinator.definitions(
            for: docContext,
            text: sourceText,
            at: EditorPosition(line: 4, column: 15)
        )
        #expect(defs.count == 1)
        #expect(URL(fileURLWithPath: defs[0].path).resolvingSymlinksInPath().path
            == targetDefURL.resolvingSymlinksInPath().path)
        #expect(defs[0].range == EditorRange(startLine: 1, startColumn: 7, endLine: 1, endColumn: 18))

        let refs = await coordinator.references(
            for: docContext,
            text: sourceText,
            at: EditorPosition(line: 4, column: 15)
        )
        #expect(refs.count == 2)

        // 5. `textDocument/documentSymbol`
        let symbols = await coordinator.documentSymbols(for: docContext, text: sourceText)
        #expect(symbols.map(\.name) == ["run_task", "engine"])

        // 6. `textDocument/completion` merged with buffer/keyword completions
        let completions = await coordinator.completions(
            for: docContext,
            text: sourceText,
            at: EditorPosition(line: 5, column: 16),
            triggerCharacter: "."
        )
        #expect(completions.contains { $0.label == "accelerate" && $0.kind == .function })

        // 7. `didChange`, `didSave`, `didClose`
        await coordinator.documentDidChange(docContext, text: sourceText + "\n# updated\n")
        await coordinator.documentDidSave(docContext, text: sourceText + "\n# updated\n")
        await coordinator.documentDidClose(secondContext)

        // 8. Automatic Idle Reaper sends `shutdown` + `exit` after 350ms of inactivity!
        let reaped = await waitForAsyncCondition(timeoutMs: 3_000) {
            await lspManager.activeServerCount == 0
        }
        #expect(reaped)

        let wroteShutdownMarker = await waitForMainCondition(timeoutMs: 1_500) {
            FileManager.default.fileExists(atPath: shutdownMarkerURL.path)
        }
        #expect(wroteShutdownMarker)

        await coordinator.shutdown()
    }

    // MARK: - Helpers

    @MainActor
    private func waitForMainCondition(
        timeoutMs: Int,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
            elapsed += 25
        }
        return condition()
    }

    private func waitForAsyncCondition(
        timeoutMs: Int,
        condition: () async -> Bool
    ) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
            elapsed += 25
        }
        return await condition()
    }

    /// Resolves a real Python 3 binary while skipping the `/usr/bin/python3` Apple GUI installer shim,
    /// mirroring `dist/macos/dev-tool.sh`.
    private static func resolveRealPython3Executable() -> String? {
        let fm = FileManager.default
        var appleShimInode: ino_t?
        var shimStat = Darwin.stat()
        if stat("/usr/bin/python3", &shimStat) == 0 {
            appleShimInode = shimStat.st_ino
        }

        func isUsablePython(_ candidate: String) -> Bool {
            var info = Darwin.stat()
            guard stat(candidate, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  fm.isExecutableFile(atPath: candidate) else {
                return false
            }
            if let appleShimInode, info.st_ino == appleShimInode {
                return false
            }
            return true
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ] + envPath.split(separator: ":").map(String.init) + [
            "/Library/Developer/CommandLineTools/usr/bin",
            "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/Current/bin",
            "/Applications/Xcode.app/Contents/Developer/usr/bin",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        ]

        for dir in searchDirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("python3")
            if isUsablePython(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static let mockPythonLSPServerScript = #"""
    import json
    import os
    import sys
    import urllib.parse

    def read_message():
        headers = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            decoded = line.decode("ascii", errors="replace").strip()
            if ":" in decoded:
                k, v = decoded.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        length = int(headers.get("content-length", "0"))
        if length <= 0:
            return None
        body = b""
        while len(body) < length:
            chunk = sys.stdin.buffer.read(length - len(body))
            if not chunk:
                return None
            body += chunk
        return json.loads(body.decode("utf-8"))

    def send_message(payload):
        raw = json.dumps(payload).encode("utf-8")
        header = f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii")
        sys.stdout.buffer.write(header + raw)
        sys.stdout.buffer.flush()

    root_uri = ""

    while True:
        msg = read_message()
        if msg is None:
            break
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}

        if method == "initialize":
            root_uri = params.get("rootUri", "")
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "capabilities": {
                        "textDocumentSync": 1,
                        "hoverProvider": True,
                        "definitionProvider": True,
                        "referencesProvider": True,
                        "documentSymbolProvider": True,
                        "completionProvider": {"triggerCharacters": ["."]}
                    }
                }
            })
            # Exercise server -> client request handling to ensure client never deadlocks!
            send_message({
                "jsonrpc": "2.0",
                "id": 9001,
                "method": "window/workDoneProgress/create",
                "params": {"token": "indexing"}
            })
        elif method == "textDocument/didOpen":
            doc = params.get("textDocument", {})
            uri = doc.get("uri", "")
            send_message({
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": uri,
                    "diagnostics": [
                        {
                            "range": {
                                "start": {"line": 3, "character": 4},
                                "end": {"line": 3, "character": 10}
                            },
                            "severity": 2,
                            "source": "mock-pylsp",
                            "message": "Mock lint: unused return value"
                        }
                    ]
                }
            })
        elif method == "textDocument/hover":
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "contents": {
                        "kind": "markdown",
                        "value": "```python\nHyperEngine(mode: str = 'fast')\n```"
                    },
                    "range": {
                        "start": {"line": 3, "character": 13},
                        "end": {"line": 3, "character": 24}
                    }
                }
            })
        elif method == "textDocument/definition":
            models_uri = root_uri.rstrip("/") + "/models.py"
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": [
                    {
                        "uri": models_uri,
                        "range": {
                            "start": {"line": 0, "character": 6},
                            "end": {"line": 0, "character": 17}
                        }
                    }
                ]
            })
        elif method == "textDocument/references":
            doc_uri = params.get("textDocument", {}).get("uri", "")
            models_uri = root_uri.rstrip("/") + "/models.py"
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": [
                    {
                        "uri": models_uri,
                        "range": {
                            "start": {"line": 0, "character": 6},
                            "end": {"line": 0, "character": 17}
                        }
                    },
                    {
                        "uri": doc_uri,
                        "range": {
                            "start": {"line": 3, "character": 13},
                            "end": {"line": 3, "character": 24}
                        }
                    }
                ]
            })
        elif method == "textDocument/documentSymbol":
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": [
                    {
                        "name": "run_task",
                        "detail": "() -> HyperEngine",
                        "kind": 12,
                        "range": {
                            "start": {"line": 2, "character": 0},
                            "end": {"line": 4, "character": 17}
                        },
                        "selectionRange": {
                            "start": {"line": 2, "character": 4},
                            "end": {"line": 2, "character": 12}
                        },
                        "children": [
                            {
                                "name": "engine",
                                "kind": 13,
                                "range": {
                                    "start": {"line": 3, "character": 4},
                                    "end": {"line": 3, "character": 10}
                                },
                                "selectionRange": {
                                    "start": {"line": 3, "character": 4},
                                    "end": {"line": 3, "character": 10}
                                }
                            }
                        ]
                    }
                ]
            })
        elif method == "textDocument/completion":
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "isIncomplete": False,
                    "items": [
                        {
                            "label": "accelerate",
                            "kind": 2,
                            "detail": "() -> None",
                            "insertText": "accelerate(${1:factor})"
                        }
                    ]
                }
            })
        elif method == "shutdown":
            marker = os.environ.get("OMG_MOCK_SHUTDOWN_FILE")
            if marker:
                with open(marker, "w", encoding="utf-8") as f:
                    f.write("shutdown_ok\n")
            send_message({"jsonrpc": "2.0", "id": msg_id, "result": None})
        elif method == "exit":
            sys.exit(0)
    """#
}

private struct StubDiffGitExecutor: GitExecutor {
    let diffOutput: String

    func execute(
        arguments: [String],
        workingDirectory: String,
        stdin: Data?,
        maxOutputBytes: Int?
    ) async throws -> GitExecutionResult {
        GitExecutionResult(
            exitCode: 0,
            stdout: Data(diffOutput.utf8),
            stderr: Data()
        )
    }
}

private extension String {
    func resolvingSymlinksIfNeeded(matching other: String?) -> String {
        guard let other else { return self }
        if self == other { return self }
        let resolvedSelf = URL(fileURLWithPath: self).resolvingSymlinksInPath().path
        let resolvedOther = URL(fileURLWithPath: other).resolvingSymlinksInPath().path
        return resolvedSelf == resolvedOther ? other : self
    }
}
