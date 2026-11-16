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

        let trustStore = EditorWorkspaceTrustStore(
            fileURL: tempDir.appendingPathComponent(".omg-trust.json")
        )
        trustStore.trust(workspaceRoot: tempDir.path)

        let lspManager = EditorLSPManager(
            serverCommands: ["python": customCmd],
            idleTimeout: 0.35,
            emptyWorkspaceIdleTimeout: 0.35,
            reaperInterval: 0.10,
            trustStore: trustStore
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

    @Test
    @MainActor
    func untrustedWorkspaceStaysInRestrictedModeUntilTrustedAndPersistsPrivatePermissions() async throws {
        guard let pythonPath = Self.resolveRealPython3Executable() else {
            Issue.record("Python 3 executable not found on test machine")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lsp-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let serverScriptURL = tempDir.appendingPathComponent("mock_py_lsp.py")
        try Data(Self.mockPythonLSPServerScript.utf8).write(to: serverScriptURL)
        let sourceURL = tempDir.appendingPathComponent("restricted.py")
        let sourceText = "def guarded_entry():\n    return 42\n"
        try Data(sourceText.utf8).write(to: sourceURL)

        let trustFileURL = tempDir.appendingPathComponent("trust/editor-workspace-trust.json")
        let trustStore = EditorWorkspaceTrustStore(fileURL: trustFileURL)
        #expect(!trustStore.isTrusted(workspaceRoot: tempDir.path))

        let customCmd = EditorLSPServerCommand(
            executable: pythonPath,
            arguments: ["-u", serverScriptURL.path]
        )
        let lspManager = EditorLSPManager(
            serverCommands: ["python": customCmd],
            idleTimeout: 2.0,
            reaperInterval: 0.10,
            trustStore: trustStore
        )
        let coordinator = EditorIntelligenceCoordinator(lspManager: lspManager)

        let workspace = EditorWorkspace(intelligenceCoordinator: coordinator)
        workspace.open(
            path: sourceURL.path,
            filesystem: LocalWorkspaceFilesystem(workingDirectory: tempDir.path)
        )
        defer {
            workspace.cancelAndClear()
            Task { await coordinator.shutdown() }
        }

        let opened = await waitForMainCondition(timeoutMs: 2_000) {
            workspace.documents.count == 1
        }
        #expect(opened)

        // Wait briefly for initial open-document wiring; untrusted workspace MUST stay in Restricted Mode.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(workspace.untrustedLocalWorkspaceRoot != nil)
        #expect(await lspManager.activeServerCount == 0)

        // Local symbol extraction still works in Restricted Mode without spawning LSP.
        let docContext = EditorIntelligenceDocumentContext(
            path: sourceURL.path,
            languageHint: "python",
            workspaceRoot: tempDir.path,
            isLocal: true
        )
        let fallbackSymbols = await coordinator.documentSymbols(for: docContext, text: sourceText)
        #expect(fallbackSymbols.map(\.name) == ["guarded_entry"])
        #expect(await lspManager.activeServerCount == 0)

        // Granting trust persists 0600 trust record and immediately starts LSP for open documents!
        workspace.trustWorkspace(root: tempDir.path)
        #expect(workspace.untrustedLocalWorkspaceRoot == nil)
        #expect(trustStore.isTrusted(workspaceRoot: tempDir.path))
        #expect(trustStore.isTrusted(workspaceRoot: tempDir.appendingPathComponent("subdir/nested").path))

        let trustPerms = try FileManager.default.attributesOfItem(atPath: trustFileURL.path)[.posixPermissions] as? NSNumber
        #expect(trustPerms?.intValue == 0o600)

        let reloadedTrustStore = EditorWorkspaceTrustStore(fileURL: trustFileURL)
        #expect(reloadedTrustStore.isTrusted(workspaceRoot: tempDir.path))

        let startedLSP = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 1
        }
        #expect(startedLSP)

        await coordinator.shutdown()
    }

    @Test
    func lspEnvironmentScrubberRemovesSecretsWhilePreservingToolchains() async throws {
        let rawEnv: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": "/Users/tester",
            "USER": "tester",
            "TMPDIR": "/tmp",
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "SDKROOT": "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            "CARGO_HOME": "/Users/tester/.cargo",
            "RUSTUP_HOME": "/Users/tester/.rustup",
            "GOPATH": "/Users/tester/go",
            "NVM_DIR": "/Users/tester/.nvm",
            "OPENAI_API_KEY": "sk-secret",
            "ANTHROPIC_API_KEY": "sk-ant-secret",
            "GITHUB_TOKEN": "ghp_secret",
            "AWS_SESSION_TOKEN": "aws-session-secret",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "CUSTOM_SERVICE_API_KEY": "custom-key",
            "INTERNAL_SECRET_VALUE": "internal-secret",
            "GITLAB_PRIVATE_TOKEN": "glpat-secret",
            "DATABASE_PASSWORD": "db-password",
        ]

        let scrubbed = EditorLSPManager.scrubSensitiveEnvironment(rawEnv)
        for preserved in [
            "PATH", "HOME", "USER", "TMPDIR", "SHELL", "LANG",
            "SDKROOT", "DEVELOPER_DIR", "CARGO_HOME", "RUSTUP_HOME", "GOPATH", "NVM_DIR",
        ] {
            #expect(scrubbed[preserved] == rawEnv[preserved])
        }
        for removed in [
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN",
            "AWS_SESSION_TOKEN", "AWS_SECRET_ACCESS_KEY", "CUSTOM_SERVICE_API_KEY",
            "INTERNAL_SECRET_VALUE", "GITLAB_PRIVATE_TOKEN", "DATABASE_PASSWORD",
        ] {
            #expect(scrubbed[removed] == nil)
        }

        // Verify live LSP subprocess environment never receives scrubbed credentials.
        guard let pythonPath = Self.resolveRealPython3Executable() else { return }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lsp-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let envDumpURL = tempDir.appendingPathComponent("child_env.json")
        let envDumpScript = Self.mockPythonLSPServerScript.replacingOccurrences(
            of: "root_uri = \"\"",
            with: """
            root_uri = ""
            with open(\(String(reflecting: envDumpURL.path)), "w", encoding="utf-8") as _ef:
                json.dump(dict(os.environ), _ef)
            """
        )
        let scriptURL = tempDir.appendingPathComponent("env_lsp.py")
        try Data(envDumpScript.utf8).write(to: scriptURL)
        let sourceURL = tempDir.appendingPathComponent("check.py")
        try Data("x = 1\n".utf8).write(to: sourceURL)

        let trustStore = EditorWorkspaceTrustStore(fileURL: tempDir.appendingPathComponent("trust.json"))
        trustStore.trust(workspaceRoot: tempDir.path)

        var injectedBase = ProcessInfo.processInfo.environment
        injectedBase["OPENAI_API_KEY"] = "sk-live-leak-test"
        injectedBase["GITHUB_TOKEN"] = "ghp-live-leak-test"
        injectedBase["AWS_SESSION_TOKEN"] = "aws-live-leak-test"
        injectedBase["CARGO_HOME"] = "/tmp/preserved-cargo-home"

        let lspManager = EditorLSPManager(
            serverCommands: ["python": EditorLSPServerCommand(executable: pythonPath, arguments: ["-u", scriptURL.path])],
            idleTimeout: 1.0,
            reaperInterval: 0.1,
            trustStore: trustStore,
            baseEnvironmentOverride: injectedBase
        )
        defer { Task { await lspManager.shutdownAll() } }

        await lspManager.didOpen(.init(
            path: sourceURL.path,
            languageID: "python",
            text: "x = 1\n",
            workspaceRoot: tempDir.path
        ))
        let dumped = await waitForMainCondition(timeoutMs: 2_500) {
            FileManager.default.fileExists(atPath: envDumpURL.path)
        }
        #expect(dumped)
        let childEnv = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: envDumpURL))
        #expect(childEnv["OPENAI_API_KEY"] == nil)
        #expect(childEnv["GITHUB_TOKEN"] == nil)
        #expect(childEnv["AWS_SESSION_TOKEN"] == nil)
        #expect(childEnv["CARGO_HOME"] == "/tmp/preserved-cargo-home")
        await lspManager.shutdownAll()
    }

    @Test
    func globalLRUCapEvictsOldestIdleServerAndShortensZeroDocumentTeardown() async throws {
        guard let pythonPath = Self.resolveRealPython3Executable() else {
            Issue.record("Python 3 executable not found on test machine")
            return
        }

        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lsp-lru-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let scriptURL = baseDir.appendingPathComponent("lru_lsp.py")
        try Data(Self.mockPythonLSPServerScript.utf8).write(to: scriptURL)

        let trustStore = EditorWorkspaceTrustStore(fileURL: baseDir.appendingPathComponent("trust.json"))
        var roots: [URL] = []
        for idx in 1...4 {
            let ws = baseDir.appendingPathComponent("ws\(idx)", isDirectory: true)
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            try Data("x = \(idx)\n".utf8).write(to: ws.appendingPathComponent("mod.py"))
            trustStore.trust(workspaceRoot: ws.path)
            roots.append(ws)
        }

        let lspManager = EditorLSPManager(
            serverCommands: ["python": EditorLSPServerCommand(executable: pythonPath, arguments: ["-u", scriptURL.path])],
            idleTimeout: 30.0,
            emptyWorkspaceIdleTimeout: 0.20,
            reaperInterval: 0.05,
            maxActiveServers: 3,
            trustStore: trustStore
        )

        // Start 3 servers across ws1, ws2, ws3.
        for idx in 0..<3 {
            await lspManager.didOpen(.init(
                path: roots[idx].appendingPathComponent("mod.py").path,
                languageID: "python",
                text: "x = \(idx)\n",
                workspaceRoot: roots[idx].path
            ))
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(await lspManager.activeServerCount == 3)

        // Close ws2's open document so ws2 becomes idle (0 open documents), then open ws4 ->
        // LRU cap (max 3) immediately evicts the idle ws2 session before spawning ws4!
        await lspManager.didClose(
            path: roots[1].appendingPathComponent("mod.py").path,
            languageID: "python",
            workspaceRoot: roots[1].path
        )
        await lspManager.didOpen(.init(
            path: roots[3].appendingPathComponent("mod.py").path,
            languageID: "python",
            text: "x = 4\n",
            workspaceRoot: roots[3].path
        ))
        #expect(await lspManager.activeServerCount == 3)

        // Close remaining open documents -> shortened `emptyWorkspaceIdleTimeout` (0.20s, not 30s!)
        // reaps all zero-document language servers promptly!
        for idx in [0, 2, 3] {
            await lspManager.didClose(
                path: roots[idx].appendingPathComponent("mod.py").path,
                languageID: "python",
                workspaceRoot: roots[idx].path
            )
        }
        let reapedPromptly = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 0
        }
        #expect(reapedPromptly)
        await lspManager.shutdownAll()
    }

    @Test
    @MainActor
    func outOfTreeOpenAndBroadContainerPathsNeverBypassWorkspaceTrust() async throws {
        guard let pythonPath = Self.resolveRealPython3Executable() else {
            Issue.record("Python 3 executable not found on test machine")
            return
        }

        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lsp-outoftree-\(UUID().uuidString)", isDirectory: true)
        let trustedRepo = baseDir.appendingPathComponent("trusted-repo", isDirectory: true)
        let untrustedRepo = baseDir.appendingPathComponent("untrusted-poc", isDirectory: true)
        let untrustedSrc = untrustedRepo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untrustedSrc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: untrustedRepo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let standaloneFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-standalone-\(UUID().uuidString).py")
        let siblingStandaloneFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-sibling-\(UUID().uuidString).py")
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: standaloneFile)
            try? FileManager.default.removeItem(at: siblingStandaloneFile)
        }

        let scriptURL = baseDir.appendingPathComponent("mock_lsp.py")
        try Data(Self.mockPythonLSPServerScript.utf8).write(to: scriptURL)

        let trustedFile = trustedRepo.appendingPathComponent("safe.py")
        let untrustedFile = untrustedSrc.appendingPathComponent("exploit.py")
        let symlinkInsideTrusted = trustedRepo.appendingPathComponent("escaped_link.py")
        try Data("x = 1\n".utf8).write(to: trustedFile)
        try Data("import os\n".utf8).write(to: untrustedFile)
        try FileManager.default.createSymbolicLink(at: symlinkInsideTrusted, withDestinationURL: untrustedFile)
        try Data("standalone = 1\n".utf8).write(to: standaloneFile)
        try Data("sibling = 2\n".utf8).write(to: siblingStandaloneFile)

        let trustStore = EditorWorkspaceTrustStore(fileURL: baseDir.appendingPathComponent("trust.json"))
        #expect(trustStore.trust(workspaceRoot: trustedRepo.path))

        // Broad containers ($HOME, /Users/alice, ~/Downloads, /tmp, NSTemporaryDirectory) are never trustable.
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        for broad in [
            "/",
            "/Users",
            "/Users/alice",
            "/Users/alice/Downloads",
            "/tmp",
            homePath,
            (homePath as NSString).appendingPathComponent("Downloads"),
            FileManager.default.temporaryDirectory.path,
        ] {
            #expect(!trustStore.trust(workspaceRoot: broad))
            #expect(!trustStore.isTrusted(workspaceRoot: broad))
        }

        let lspManager = EditorLSPManager(
            serverCommands: ["python": EditorLSPServerCommand(executable: pythonPath, arguments: ["-u", scriptURL.path])],
            idleTimeout: 5.0,
            emptyWorkspaceIdleTimeout: 0.2,
            reaperInterval: 0.05,
            trustStore: trustStore
        )
        let coordinator = EditorIntelligenceCoordinator(lspManager: lspManager)
        let workspace = EditorWorkspace(intelligenceCoordinator: coordinator, fileWatcherDebounce: 0.04)
        defer {
            workspace.cancelAndClear()
            Task { await lspManager.shutdownAll() }
        }

        // 1. Opening an out-of-tree file using a trusted terminal CWD filesystem must NOT inherit trustedRepo's trust.
        let trustedCWDFilesystem = LocalWorkspaceFilesystem(workingDirectory: trustedRepo.path)
        workspace.open(path: untrustedFile.path, filesystem: trustedCWDFilesystem)
        let openedOutOfTree = await waitForMainCondition(timeoutMs: 2_000) {
            !workspace.isLoading && workspace.selectedDocument?.path == untrustedFile.path
        }
        #expect(openedOutOfTree)
        let canonicalUntrustedRepo = try #require(EditorWorkspaceTrustStore.canonicalPath(untrustedRepo.path))
        #expect(workspace.untrustedLocalWorkspaceRoot == canonicalUntrustedRepo)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await lspManager.activeServerCount == 0)

        // 2. Opening a symlink inside trustedRepo that resolves outside trustedRepo also stays in Restricted Mode.
        workspace.open(path: symlinkInsideTrusted.path, filesystem: trustedCWDFilesystem)
        let openedSymlink = await waitForMainCondition(timeoutMs: 2_000) {
            !workspace.isLoading && workspace.selectedDocument?.path == symlinkInsideTrusted.path
        }
        #expect(openedSymlink)
        #expect(workspace.untrustedLocalWorkspaceRoot == canonicalUntrustedRepo)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await lspManager.activeServerCount == 0)

        // 3. Standalone file directly inside a broad container scopes to the exact file, never trusting siblings.
        let standaloneCtx = EditorIntelligenceDocumentContext(
            path: standaloneFile.path,
            languageHint: "python",
            workspaceRoot: trustedRepo.path,
            isLocal: true
        )
        let canonicalStandalone = try #require(EditorWorkspaceTrustStore.canonicalPath(standaloneFile.path))
        #expect(standaloneCtx.effectiveLocalRoot == canonicalStandalone)
        #expect(standaloneCtx.effectiveSymbolSearchRoot == nil)
        #expect(!trustStore.isTrusted(workspaceRoot: canonicalStandalone))
        #expect(trustStore.trust(workspaceRoot: canonicalStandalone))
        #expect(trustStore.isTrusted(workspaceRoot: canonicalStandalone))
        #expect(!trustStore.isTrusted(workspaceRoot: siblingStandaloneFile.path))

        await coordinator.documentDidOpen(standaloneCtx, text: "standalone = 1\n")
        let standaloneSpawned = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 1
        }
        #expect(standaloneSpawned)
        await lspManager.shutdownAll()
    }

    @Test
    @MainActor
    func autoIdleCollapseReapSuspendsLSPAndExternalEditsDoNotLeakOpenCount() async throws {
        guard let pythonPath = Self.resolveRealPython3Executable() else {
            Issue.record("Python 3 executable not found on test machine")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lsp-autoreap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("mock_lsp.py")
        try Data(Self.mockPythonLSPServerScript.utf8).write(to: scriptURL)
        let fileURL = tempDir.appendingPathComponent("watched.py")
        try Data("value = 1\n".utf8).write(to: fileURL)

        let trustStore = EditorWorkspaceTrustStore(fileURL: tempDir.appendingPathComponent("trust.json"))
        trustStore.trust(workspaceRoot: tempDir.path)

        let lspManager = EditorLSPManager(
            serverCommands: ["python": EditorLSPServerCommand(executable: pythonPath, arguments: ["-u", scriptURL.path])],
            idleTimeout: 30.0,
            emptyWorkspaceIdleTimeout: 0.12,
            reaperInterval: 0.04,
            trustStore: trustStore
        )
        let coordinator = EditorIntelligenceCoordinator(lspManager: lspManager)
        let workspace = EditorWorkspace(
            intelligenceCoordinator: coordinator,
            fileWatcherDebounce: 0.03,
            idleReapDelay: .milliseconds(80)
        )
        defer {
            workspace.cancelAndClear()
            Task { await lspManager.shutdownAll() }
        }

        let fs = LocalWorkspaceFilesystem(workingDirectory: tempDir.path)
        workspace.open(path: fileURL.path, filesystem: fs)
        let opened = await waitForMainCondition(timeoutMs: 2_000) {
            !workspace.isLoading && workspace.selectedDocument != nil
        }
        #expect(opened)
        let doc = try #require(workspace.selectedDocument)

        let serverStarted = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 1
        }
        #expect(serverStarted)

        // 1. Hide workspace and rely solely on automatic `idleReapDelay` (no manual `reclaimIdleWorkbenchNow()`).
        workspace.isVisible = false
        let autoReaped = await waitForAsyncCondition(timeoutMs: 3_000) {
            await lspManager.activeServerCount == 0
        }
        #expect(autoReaped)
        #expect(workspace.intelligenceBridge.hasSuspendedDocuments)

        // 2. External file edit while hidden updates the clean document buffer WITHOUT waking LSP or bumping openCount.
        try Data("value = 2\n".utf8).write(to: fileURL, options: .atomic)
        let syncedWhileHidden = await waitForMainCondition(timeoutMs: 2_000) {
            doc.text == "value = 2\n"
        }
        #expect(syncedWhileHidden)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await lspManager.activeServerCount == 0)

        // 3. Uncollapsing re-opens the document once (`openCount == 1`), so closing the tab drops openCount to 0.
        workspace.isVisible = true
        let reopened = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 1
        }
        #expect(reopened)

        workspace.remove(doc)
        let closedCleanly = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 0
        }
        #expect(closedCleanly)
        await lspManager.shutdownAll()
    }

    @Test
    @MainActor
    func uncollapseDuringInFlightHiddenSuspendAbortsClosePreservesDiagnosticsAndRecoversSymbolIndex() async throws {
        guard let pythonPath = Self.resolveRealPython3Executable() else {
            Issue.record("Python 3 executable not found on test machine")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lsp-uncollapse-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("mock_lsp.py")
        try Data(Self.mockPythonLSPServerScript.utf8).write(to: scriptURL)

        let firstURL = tempDir.appendingPathComponent("first.py")
        let secondURL = tempDir.appendingPathComponent("second.py")
        try Data("x = 1\n".utf8).write(to: firstURL)
        try Data("y = 2\n".utf8).write(to: secondURL)

        let trustStore = EditorWorkspaceTrustStore(fileURL: tempDir.appendingPathComponent("trust.json"))
        #expect(trustStore.trust(workspaceRoot: tempDir.path))

        let lspManager = EditorLSPManager(
            serverCommands: ["python": EditorLSPServerCommand(executable: pythonPath, arguments: ["-u", scriptURL.path])],
            idleTimeout: 30.0,
            emptyWorkspaceIdleTimeout: 0.12,
            reaperInterval: 0.04,
            trustStore: trustStore
        )
        let symbolIndex = EditorSymbolIndex()
        let coordinator = EditorIntelligenceCoordinator(lspManager: lspManager, symbolIndex: symbolIndex)
        let workspace = EditorWorkspace(
            intelligenceCoordinator: coordinator,
            fileWatcherDebounce: 0.03,
            idleReapDelay: .milliseconds(25)
        )
        defer {
            workspace.cancelAndClear()
            Task { await lspManager.shutdownAll() }
        }

        var diagnosticsByPath: [String: [EditorDiagnostic]] = [:]
        var emptyDiagnosticWipes: [String] = []
        let bridgeOnDiagnostics = coordinator.onDiagnostics
        coordinator.onDiagnostics = { path, diags in
            diagnosticsByPath[path] = diags
            if diags.isEmpty {
                emptyDiagnosticWipes.append(path)
            }
            bridgeOnDiagnostics?(path, diags)
        }

        let fs = LocalWorkspaceFilesystem(workingDirectory: tempDir.path)
        workspace.open(path: firstURL.path, filesystem: fs)
        let openedFirst = await waitForMainCondition(timeoutMs: 2_000) {
            !workspace.isLoading && workspace.documents.count == 1
        }
        #expect(openedFirst)
        let firstDoc = try #require(workspace.documents.first)
        firstDoc.suspendAutoSave()

        workspace.open(path: secondURL.path, filesystem: fs)
        let openedSecond = await waitForMainCondition(timeoutMs: 2_000) {
            !workspace.isLoading && workspace.documents.count == 2
        }
        #expect(openedSecond)
        let secondDoc = try #require(workspace.documents.last)
        secondDoc.suspendAutoSave()

        // Wait until mock LSP publishes initial diagnostics for both open documents.
        let gotInitialDiagnostics = await waitForMainCondition(timeoutMs: 3_000) {
            !(diagnosticsByPath[firstDoc.path] ?? []).isEmpty
                && !(diagnosticsByPath[secondDoc.path] ?? []).isEmpty
        }
        #expect(gotInitialDiagnostics)
        #expect(await lspManager.activeServerCount == 1)

        // Populate unsaved in-memory symbols on both documents (resolvable ONLY via symbolIndex openDocuments).
        firstDoc.text = "class UnsavedSymbolAlpha:\n    pass\n"
        secondDoc.text = "class UnsavedSymbolBeta:\n    pass\n"
        await symbolIndex.updateOpenDocument(path: firstDoc.path, text: firstDoc.text, languageID: "python")
        await symbolIndex.updateOpenDocument(path: secondDoc.path, text: secondDoc.text, languageID: "python")
        emptyDiagnosticWipes.removeAll()

        // Case 1: Uncollapse while `reclaimIdleWorkbenchNow()` is suspended mid-`suspendDocumentsForHiddenReclaim()`.
        let genBeforeReclaim = workspace.intelligenceBridge.reclaimGeneration
        workspace.isVisible = false
        let manualReclaimTask = Task { @MainActor in
            await workspace.reclaimIdleWorkbenchNow()
        }
        while !workspace.intelligenceBridge.hasSuspendedDocuments {
            await Task.yield()
        }
        let genDuringSuspend = workspace.intelligenceBridge.reclaimGeneration
        #expect(genDuringSuspend > genBeforeReclaim)

        // Uncollapse right while `suspendDocumentsForHiddenReclaim()` is in-flight!
        workspace.isVisible = true
        let manualReclaimed = await manualReclaimTask.value
        #expect(!manualReclaimed)
        #expect(workspace.intelligenceBridge.reclaimGeneration > genDuringSuspend)
        #expect(!workspace.intelligenceBridge.hasSuspendedDocuments)
        #expect(emptyDiagnosticWipes.isEmpty)
        #expect(!(diagnosticsByPath[firstDoc.path] ?? []).isEmpty)
        #expect(!(diagnosticsByPath[secondDoc.path] ?? []).isEmpty)

        // Allow rehydration tasks to settle and verify both unsaved open-document symbols remain indexed.
        let recoveredManual = await waitForAsyncCondition(timeoutMs: 2_000) {
            let alpha = await symbolIndex.findDefinitions(
                symbol: "UnsavedSymbolAlpha",
                currentPath: secondDoc.path,
                currentText: secondDoc.text,
                workspaceRoot: tempDir.path
            )
            let beta = await symbolIndex.findDefinitions(
                symbol: "UnsavedSymbolBeta",
                currentPath: firstDoc.path,
                currentText: firstDoc.text,
                workspaceRoot: tempDir.path
            )
            return !alpha.isEmpty && !beta.isEmpty
        }
        #expect(recoveredManual)

        // Case 2: Uncollapse while scheduled `workbenchReapTask` is mid-`suspendDocumentsForHiddenReclaim()`,
        // verifying `cancelWorkbenchReap()` cancels the still-assigned `workbenchReapTask`.
        emptyDiagnosticWipes.removeAll()
        let genBeforeScheduled = workspace.intelligenceBridge.reclaimGeneration
        workspace.isVisible = false
        let enteredScheduledSuspend = await waitForMainCondition(timeoutMs: 2_000) {
            workspace.intelligenceBridge.reclaimGeneration > genBeforeScheduled
        }
        #expect(enteredScheduledSuspend)
        workspace.isVisible = true
        try? await Task.sleep(for: .milliseconds(80))

        #expect(!workspace.intelligenceBridge.hasSuspendedDocuments)
        #expect(emptyDiagnosticWipes.isEmpty)
        let recoveredScheduled = await waitForAsyncCondition(timeoutMs: 2_000) {
            let alpha = await symbolIndex.findDefinitions(
                symbol: "UnsavedSymbolAlpha",
                currentPath: secondDoc.path,
                currentText: secondDoc.text,
                workspaceRoot: tempDir.path
            )
            let beta = await symbolIndex.findDefinitions(
                symbol: "UnsavedSymbolBeta",
                currentPath: firstDoc.path,
                currentText: firstDoc.text,
                workspaceRoot: tempDir.path
            )
            return !alpha.isEmpty && !beta.isEmpty
        }
        #expect(recoveredScheduled)
        #expect(await lspManager.activeServerCount == 1)

        // Removing both open documents must drop openCount cleanly to 0 (no leaked openCount).
        workspace.remove(firstDoc)
        workspace.remove(secondDoc)
        let reapedAfterRemove = await waitForAsyncCondition(timeoutMs: 2_500) {
            await lspManager.activeServerCount == 0
        }
        #expect(reapedAfterRemove)
        await lspManager.shutdownAll()
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
