import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

@Suite(.serialized) @MainActor
struct MonacoWorkbenchTests {
    @Test func pooledWorkbenchSwapsMultipleModelsAndPreservesCursorOnExternalSync() async throws {
        let controller = MonacoWorkbenchController()
        let mounted = EditorTestSupport.host(
            MonacoWorkbenchSurface(controller: controller).frame(width: 720, height: 460),
            size: NSSize(width: 720, height: 460)
        )
        mounted.1.makeKeyAndOrderFront(nil)
        defer {
            controller.tearDown()
            EditorTestSupport.unmount(mounted)
        }

        let webView = try await EditorTestSupport.waitForMonacoReady(in: mounted.0.view)
        #expect(!webView.configuration.websiteDataStore.isPersistent)

        let uriA = "omg-model://local/workspace/Alpha.swift"
        let uriB = "omg-model://local/workspace/Beta.zig"
        let uriC = "omg-model://ssh-prod/remote/Gamma.py"

        controller.openOrUpdateModel(
            uri: uriA,
            path: "/workspace/Alpha.swift",
            text: "line 1\nline 2\nline 3\nline 4\n",
            languageHint: "swift"
        )
        controller.openOrUpdateModel(
            uri: uriB,
            path: "/workspace/Beta.zig",
            text: "const std = @import(\"std\");\n",
            languageHint: "zig"
        )
        controller.openOrUpdateModel(
            uri: uriC,
            path: "/remote/Gamma.py",
            text: "def run():\n    return 1\n",
            languageHint: "python"
        )
        #expect(controller.openModels.count == 3)

        controller.activateModel(
            uri: uriA,
            readOnly: false,
            wordWrap: false,
            tabSize: 4,
            insertSpaces: true,
            keymapProfile: .idea
        )
        for _ in 0..<80 {
            let active = (try? await webView.evaluateJavaScript("window.omgEditor.getState().activeUri")) as? String
            if active == uriA { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        // Place cursor on line 3, column 5 in uriA, switch to uriB, and switch back to uriA.
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const ed = window.omgEditor._internal.editor;
            ed.setPosition({ lineNumber: 3, column: 5 });
            return ed.getPosition();
        })()
        """)
        controller.activateModel(
            uri: uriB,
            readOnly: false,
            wordWrap: false,
            tabSize: 4,
            insertSpaces: true,
            keymapProfile: .vscode
        )
        controller.activateModel(
            uri: uriA,
            readOnly: false,
            wordWrap: false,
            tabSize: 4,
            insertSpaces: true,
            keymapProfile: .idea
        )
        try await Task.sleep(for: .milliseconds(60))

        let restoredLine = try await webView.evaluateJavaScript(
            "window.omgEditor._internal.editor.getPosition().lineNumber"
        ) as? Int
        #expect(restoredLine == 3, "Switching between pooled models must restore per-tab view state")

        // External sync with preserveView: true updates surrounding lines while keeping cursor in place.
        controller.openOrUpdateModel(
            uri: uriA,
            path: "/workspace/Alpha.swift",
            text: "line 1\nline 2\nline 3\nline 4\nline 5 appended externally\n",
            languageHint: "swift",
            preserveView: true
        )
        for _ in 0..<60 {
            let count = (try? await webView.evaluateJavaScript(
                "window.omgEditor._internal.editor.getModel().getLineCount()"
            )) as? Int
            if count == 6 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let lineAfterExternalSync = try await webView.evaluateJavaScript(
            "window.omgEditor._internal.editor.getPosition().lineNumber"
        ) as? Int
        #expect(lineAfterExternalSync == 3, "preserveView: true must keep cursor position when an external agent appends code")

        controller.closeModel(uri: uriB)
        #expect(controller.openModels.count == 2)
        let openCountInJS = try await webView.evaluateJavaScript(
            "window.omgEditor.getState().openUris.length"
        ) as? Int
        #expect(openCountInJS == 2)
    }

    @Test func urlSchemeHandlerRejectsPathTraversalOutsideBundleRoot() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("omg-bundle-\(UUID().uuidString)")
        let secretOutside = tempRoot.deletingLastPathComponent().appendingPathComponent("omg-secret-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>ok</body></html>".utf8)
            .write(to: tempRoot.appendingPathComponent("index.html"))
        try Data("TOP_SECRET".utf8).write(to: secretOutside)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
            try? FileManager.default.removeItem(at: secretOutside)
        }

        final class MockSchemeTask: NSObject, WKURLSchemeTask {
            let request: URLRequest
            var receivedData = Data()
            var failedError: Error?
            var finished = false

            init(url: URL) {
                self.request = URLRequest(url: url)
            }

            func didReceive(_ response: URLResponse) {}
            func didReceive(_ data: Data) { receivedData.append(data) }
            func didFinish() { finished = true }
            func didFailWithError(_ error: Error) { failedError = error }
        }

        let handler = MonacoEditorResources(customRootURL: tempRoot)
        let dummyWebView = WKWebView(frame: .zero)

        let validTask = MockSchemeTask(url: URL(string: "omg-editor://bundle/index.html")!)
        handler.webView(dummyWebView, start: validTask)
        #expect(validTask.finished)
        #expect(validTask.failedError == nil)

        let traversalURL = URL(string: "omg-editor://bundle/../\(secretOutside.lastPathComponent)")!
        let traversalTask = MockSchemeTask(url: traversalURL)
        handler.webView(dummyWebView, start: traversalTask)
        #expect(traversalTask.failedError != nil)
        #expect(traversalTask.receivedData.isEmpty)
    }

    @Test func externalDiskUpdateAutoSyncsCleanDocumentsAndSurfacesConflictWhenDirty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-ext-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("agent_target.swift")
        try Data("let v = 1\n".utf8).write(to: file)

        let fs = LocalWorkspaceFilesystem(workingDirectory: dir.path)
        let doc = try await EditorDocument.open(path: file.path, filesystem: fs)
        doc.suspendAutoSave()
        let initialGeneration = doc.contentGeneration
        let initialSyncRev = doc.externalSyncRevision

        // 1. Clean document auto-updates in place without bumping contentGeneration.
        let diskV2 = Data("let v = 2\n".utf8)
        try diskV2.write(to: file, options: .atomic)
        doc.applyExternalDiskUpdate(data: diskV2, decoded: try EditorDocument.decodeData(diskV2))
        #expect(doc.text == "let v = 2\n")
        #expect(!doc.isDirty)
        #expect(!doc.hasExternalDiskConflict)
        #expect(doc.contentGeneration == initialGeneration)
        #expect(doc.externalSyncRevision == initialSyncRev + 1)

        // 2. Dirty document preserves local edits and raises hasExternalDiskConflict.
        doc.text = "let v = 999 // local edit\n"
        #expect(doc.isDirty)

        let diskV3 = Data("let v = 3 // external agent write\n".utf8)
        try diskV3.write(to: file, options: .atomic)
        doc.applyExternalDiskUpdate(data: diskV3, decoded: try EditorDocument.decodeData(diskV3))
        #expect(doc.hasExternalDiskConflict)
        #expect(doc.text == "let v = 999 // local edit\n")

        // 3. Keeping local edits adopts diskV3 as baseline so save() overwrites cleanly without .fileChanged failure.
        doc.keepLocalEditsAfterConflict()
        #expect(!doc.hasExternalDiskConflict)
        #expect(doc.isDirty)
        try await doc.save()
        #expect(!doc.isDirty)
        let savedOnDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(savedOnDisk == "let v = 999 // local edit\n")
    }

    @Test func workspaceFileWatcherSyncsExternalAtomicWriteIntoOpenCleanDocument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-ws-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("watched.swift")
        try Data("func before() {}\n".utf8).write(to: file)

        let workspace = EditorWorkspace(fileWatcherDebounce: 0.04)
        defer { workspace.cancelAndClear() }

        let fs = LocalWorkspaceFilesystem(workingDirectory: dir.path)
        workspace.open(path: file.path, filesystem: fs)
        for _ in 0..<80 {
            if !workspace.isLoading, workspace.selectedDocument != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let doc = try #require(workspace.selectedDocument)
        try await Task.sleep(for: .milliseconds(80))

        // Simulate Claude Code / vim atomic rename over watched.swift.
        try Data("func afterAgentEdit() {}\n".utf8).write(to: file, options: .atomic)

        for _ in 0..<100 {
            if doc.text == "func afterAgentEdit() {}\n" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(doc.text == "func afterAgentEdit() {}\n")
        #expect(!doc.isDirty)
        #expect(!doc.hasExternalDiskConflict)
    }

    @Test func askAgentFormatsContextualPromptAndRoutesOutboundMessage() {
        let request = EditorAskAgentRequest(
            path: "/Users/dev/project/macos/Sources/Features/Editor/MonacoWorkbenchView.swift",
            startLine: 42,
            endLine: 48,
            selectedText: "func activateModel() {\n    // ...\n}\n",
            comment: "Check thread safety on model swap"
        )
        let prompt = request.formattedPrompt(workingDirectory: "/Users/dev/project")
        #expect(prompt.contains("@macos/Sources/Features/Editor/MonacoWorkbenchView.swift#L42-L48 Check thread safety on model swap"))
        #expect(prompt.contains("```swift\nfunc activateModel() {\n    // ...\n}\n```"))

        let controller = MonacoWorkbenchController()
        defer { controller.tearDown() }
        var captured: EditorAskAgentRequest?
        controller.onAskAgent = { captured = $0 }
        controller.handleOutboundMessage(type: "askAgent", body: [
            "path": "/Users/dev/project/src/main.zig",
            "startLine": 10,
            "endLine": 10,
            "selectedText": "pub fn main() void {}",
            "comment": "Explain entrypoint"
        ])
        #expect(captured?.path == "/Users/dev/project/src/main.zig")
        #expect(captured?.formattedPrompt(workingDirectory: "/Users/dev/project").hasPrefix("@src/main.zig#L10 Explain entrypoint") == true)
    }

    @Test func quickOpenSearchSkipsIgnoredDirectoriesAndRanksFuzzyMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omg-quick-open-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("macos/Sources/Editor")
        let gitDir = root.appendingPathComponent(".git/objects")
        let nodeModules = root.appendingPathComponent("node_modules/pkg")
        let zigOut = root.appendingPathComponent("zig-out/bin")
        for d in [srcDir, gitDir, nodeModules, zigOut] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: srcDir.appendingPathComponent("MonacoWorkbenchView.swift"))
        try Data().write(to: srcDir.appendingPathComponent("EditorWorkspaceHost.swift"))
        try Data().write(to: gitDir.appendingPathComponent("MonacoWorkbenchView.swift"))
        try Data().write(to: nodeModules.appendingPathComponent("MonacoWorkbenchView.js"))
        try Data().write(to: zigOut.appendingPathComponent("MonacoWorkbenchView"))

        let collected = EditorQuickOpenSearch.collectLocalFiles(rootDirectory: root.path)
        #expect(collected.count == 2, "Quick Open must skip .git, node_modules, and zig-* directories")

        let ranked = EditorQuickOpenSearch.rank(
            files: collected,
            query: "mwv",
            rootDirectory: root.path
        )
        #expect(ranked.first?.name == "MonacoWorkbenchView.swift")
    }

    @Test func workspaceIntelligenceBridgeResolvesSymbolsDefinitionsHoverAndCompletions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-intel-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("Types.swift")
        let fileB = dir.appendingPathComponent("Caller.swift")
        try Data("""
        /// Shared configuration payload for workbench tests.
        struct WorkbenchConfigPayload {
            let maxTabs: Int
        }
        """.utf8).write(to: fileA)
        try Data("""
        func makeConfig() -> WorkbenchConfigPayload {
            WorkbenchConfigPayload(maxTabs: 8)
        }
        """.utf8).write(to: fileB)

        let workspace = EditorWorkspace()
        defer { workspace.cancelAndClear() }

        let fs = LocalWorkspaceFilesystem(workingDirectory: dir.path)
        workspace.open(path: fileB.path, filesystem: fs)
        for _ in 0..<80 {
            if !workspace.isLoading, workspace.selectedDocument != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let docB = try #require(workspace.selectedDocument)
        let lspHandler = try #require(workspace.workbenchController.onLSPRequest)

        // 1. Document symbols in Caller.swift
        let symbolsRaw = await lspHandler("documentSymbol", docB.id.monacoURI, docB.path, 1, 1, nil)
        let symbols = try #require(symbolsRaw as? [[String: Any]])
        #expect(symbols.contains { ($0["name"] as? String) == "makeConfig" })

        // 2. Cross-file Go to Definition on `WorkbenchConfigPayload` (line 1, col 25) -> Types.swift
        let defsRaw = await lspHandler("definition", docB.id.monacoURI, docB.path, 1, 25, nil)
        let defs = try #require(defsRaw as? [[String: Any]])
        #expect(defs.contains { ($0["path"] as? String)?.hasSuffix("/Types.swift") == true })

        // 3. Hover on `WorkbenchConfigPayload` returns doc comment markdown
        let hoverRaw = await lspHandler("hover", docB.id.monacoURI, docB.path, 1, 25, nil)
        let hover = try #require(hoverRaw as? [String: Any])
        #expect((hover["markdown"] as? String)?.contains("WorkbenchConfigPayload") == true)

        // 4. Completion for `Workb` prefix
        let compRaw = await lspHandler("completion", docB.id.monacoURI, docB.path, 2, 10, nil)
        let comps = try #require(compRaw as? [[String: Any]])
        #expect(comps.contains { ($0["label"] as? String) == "WorkbenchConfigPayload" })
    }
}
