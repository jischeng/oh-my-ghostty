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

    @Test func gitEditorDiffViewSyncsPierreModesAskAgentAndTearsDownCleanly() async throws {
        let defaults = UserDefaults.standard
        let savedReview = defaults.object(forKey: "git.diff.review")
        let savedMode = defaults.object(forKey: "git.diff.viewMode")
        let savedWrap = defaults.object(forKey: "git.diff.wordWrap")
        defaults.set(true, forKey: "git.diff.review")
        defaults.set(GitL10n.text("Side by Side"), forKey: "git.diff.viewMode")
        defaults.set(true, forKey: "git.diff.wordWrap")
        defer {
            defaults.set(savedReview, forKey: "git.diff.review")
            defaults.set(savedMode, forKey: "git.diff.viewMode")
            defaults.set(savedWrap, forKey: "git.diff.wordWrap")
        }

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-pierre-diff-\(UUID().uuidString)")
        let srcDir = repoRoot.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let beforeLines = (1...30).map { "let item\($0) = \($0)" }
        var afterLines = beforeLines
        afterLines[4] = "let item5 = 500 // first hunk"
        afterLines[22] = "let item23 = 2300 // second hunk"
        let before = beforeLines.joined(separator: "\n") + "\n"
        let after = afterLines.joined(separator: "\n") + "\n"
        let demoFile = srcDir.appendingPathComponent("Demo.swift")
        try Data(before.utf8).write(to: demoFile)
        for args in [["init", "--quiet"], ["add", "."]] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repoRoot.path)
            try #require(res.isSuccess)
        }
        try Data(after.utf8).write(to: demoFile)

        let repository = GitRepositoryIdentity(
            worktreePath: repoRoot.path,
            gitDirPath: repoRoot.path + "/.git",
            commonGitDirPath: repoRoot.path + "/.git"
        )
        let request = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Sources/Demo.swift", status: "M")
        )

        var capturedAskAgent: EditorAskAgentRequest?
        let controller = MonacoWorkbenchController()
        let view = GitEditorDiffView(
            request: request,
            theme: .oneDark,
            actions: GitDiffEditorActions(
                askAgent: { capturedAskAgent = $0 }
            ),
            externalController: controller,
            close: {}
        )
        .frame(width: 820, height: 480)

        let mounted = EditorTestSupport.host(view, size: NSSize(width: 820, height: 480))
        mounted.1.makeKeyAndOrderFront(nil)
        defer {
            controller.tearDown()
            EditorTestSupport.unmount(mounted)
        }

        let webView = try await EditorTestSupport.waitForMonacoReady(in: mounted.0.view)
        for _ in 0..<120 {
            if controller.activeDiff != nil, controller.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(!webView.isOpaque)
        #expect((webView.underPageBackgroundColor?.alphaComponent ?? 1) == 0)
        #expect(EditorTestSupport.findAll(MonacoEditorWebView.self, in: mounted.0.view).count == 1)

        // 1. Initial Review + Side by Side + Word Wrap state & live Pierre Shadow DOM
        let initial = try #require(controller.activeDiff)
        #expect(initial.path == "Sources/Demo.swift")
        #expect(initial.review == true)
        #expect(initial.inline == false)
        #expect(initial.wordWrap == true)
        #expect(initial.patchOnly == false)
        #expect(initial.originalText == before)
        #expect(initial.modifiedText == after)
        #expect(initial.patch.contains("+let item5 = 500"))

        let initialDOMRaw = try await controller.evaluateJavaScriptForTesting("""
        (() => {
          const el = document.querySelector('#diff-root diffs-container');
          const sr = el?.shadowRoot;
          return {
            mode: window.omgEditor?.getState?.()?.mode ?? '',
            separators: sr ? sr.querySelectorAll('[data-separator="line-info"]').length : -1,
            addLines: sr ? sr.querySelectorAll('code[data-additions] [data-line]').length : -1,
            hasDeletionsCol: Boolean(sr?.querySelector('code[data-deletions]')),
            hasUnifiedCol: Boolean(sr?.querySelector('code[data-unified]')),
            overflow: sr?.querySelector('pre[data-diff]')?.getAttribute('data-overflow') ?? '',
            syntaxSpans: sr ? sr.querySelectorAll('span[style*="--omg-syntax-"]').length : 0,
            diffBg: document.getElementById('diff-root')?.style.getPropertyValue('--diffs-bg') ?? ''
          };
        })()
        """)
        let initialDOM = try #require(initialDOMRaw as? [String: Any])
        #expect(initialDOM["mode"] as? String == "diff")
        #expect((initialDOM["separators"] as? Int ?? 0) >= 2, "Review mode must collapse unchanged context into hunk separators")
        let collapsedAddLines = try #require(initialDOM["addLines"] as? Int)
        #expect(collapsedAddLines > 0 && collapsedAddLines < 30)
        #expect(initialDOM["hasDeletionsCol"] as? Bool == true)
        #expect(initialDOM["hasUnifiedCol"] as? Bool == false)
        #expect(initialDOM["overflow"] as? String == "wrap")
        #expect((initialDOM["syntaxSpans"] as? Int ?? 0) > 0, "Offline @pierre/highlights must emit syntax token spans")
        #expect(initialDOM["diffBg"] as? String == "transparent")

        // Clicking an expand button inside a hunk separator expands unmodified context lines
        let expandedCountRaw = try await controller.evaluateJavaScriptForTesting("""
        (() => {
          const sr = document.querySelector('#diff-root diffs-container')?.shadowRoot;
          const btn = sr?.querySelector('[data-expand-button]');
          btn?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
          return sr ? sr.querySelectorAll('code[data-additions] [data-line]').length : -1;
        })()
        """)
        #expect((expandedCountRaw as? Int ?? 0) > collapsedAddLines)

        // 2. Toggle Review -> Full Source, Side by Side -> Inline, Word Wrap -> false on the same WebView
        defaults.set(false, forKey: "git.diff.review")
        defaults.set(GitL10n.text("Inline"), forKey: "git.diff.viewMode")
        defaults.set(false, forKey: "git.diff.wordWrap")
        for _ in 0..<60 {
            if controller.activeDiff?.review == false,
               controller.activeDiff?.inline == true,
               controller.activeDiff?.wordWrap == false {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.activeDiff?.review == false)
        #expect(controller.activeDiff?.inline == true)
        #expect(controller.activeDiff?.wordWrap == false)
        #expect(EditorTestSupport.find(MonacoEditorWebView.self, in: mounted.0.view) === webView)

        let toggledDOMRaw = try await controller.evaluateJavaScriptForTesting("""
        (() => {
          const sr = document.querySelector('#diff-root diffs-container')?.shadowRoot;
          return {
            separators: sr ? sr.querySelectorAll('[data-separator="line-info"]').length : -1,
            unifiedLines: sr ? sr.querySelectorAll('code[data-unified] [data-line]').length : -1,
            hasDeletionsCol: Boolean(sr?.querySelector('code[data-deletions]')),
            overflow: sr?.querySelector('pre[data-diff]')?.getAttribute('data-overflow') ?? ''
          };
        })()
        """)
        let toggledDOM = try #require(toggledDOMRaw as? [String: Any])
        #expect(toggledDOM["separators"] as? Int == 0, "Full Source mode must render zero collapsed separators")
        #expect((toggledDOM["unifiedLines"] as? Int ?? 0) >= 30, "Full Source Inline mode must render all lines")
        #expect(toggledDOM["hasDeletionsCol"] as? Bool == false)
        #expect(toggledDOM["overflow"] as? String == "scroll")

        // 3. Change navigation via toolbar buttons updates Pierre active change line
        let nextBtn = try #require(
            EditorTestSupport.findAll(NativeActionControl.self, in: mounted.0.view)
                .first { $0.toolTip == GitL10n.text("Next change") }
        )
        let prevBtn = try #require(
            EditorTestSupport.findAll(NativeActionControl.self, in: mounted.0.view)
                .first { $0.toolTip == GitL10n.text("Previous change") }
        )
        #expect(nextBtn.isEnabled && prevBtn.isEnabled)
        nextBtn.performClick(nil)
        nextBtn.performClick(nil)
        for _ in 0..<40 {
            let activeLine = try? await controller.evaluateJavaScriptForTesting(
                "document.querySelector('#diff-root diffs-container')?.shadowRoot?.querySelector('[data-line][data-editor-active-line]')?.getAttribute('data-line') ?? ''"
            ) as? String
            if activeLine == "23" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let navDOMRaw = try await controller.evaluateJavaScriptForTesting("""
        (() => {
          const sr = document.querySelector('#diff-root diffs-container')?.shadowRoot;
          const st = window.omgEditor?.getDiffState?.() ?? {};
          return {
            currentChangeIndex: st.currentChangeIndex ?? -1,
            currentLineNumber: st.currentLineNumber ?? -1,
            activeLine: sr?.querySelector('[data-line][data-editor-active-line]')?.getAttribute('data-line') ?? ''
          };
        })()
        """)
        let navDOM = try #require(navDOMRaw as? [String: Any])
        #expect(navDOM["currentChangeIndex"] as? Int == 1)
        #expect(navDOM["currentLineNumber"] as? Int == 23)
        #expect(navDOM["activeLine"] as? String == "23")
        prevBtn.performClick(nil)

        // 4. End-to-end Ask Agent from live Pierre WKWebView selection + prompt input
        _ = try await controller.evaluateJavaScriptForTesting("""
        (() => {
          window.omgEditor.selectDiffLines({ startLine: 5, endLine: 5, side: 'additions', openAskAgent: true });
          const input = document.querySelector('#omg-ask-agent-bar .omg-ask-agent-input');
          input.value = 'Verify hunk semantics';
          input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
          return true;
        })()
        """)
        for _ in 0..<40 {
            if capturedAskAgent != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ask = try #require(capturedAskAgent)
        #expect(ask.path == demoFile.path)
        #expect(ask.startLine == 5 && ask.endLine == 5)
        #expect(ask.comment == "Verify hunk semantics")
        let formatted = ask.formattedPrompt(workingDirectory: repoRoot.path)
        #expect(formatted.contains("@Sources/Demo.swift#L5 Verify hunk semantics"))
        #expect(formatted.contains("```swift\nlet item5 = 500 // first hunk\n```"))

        // 5. Owned GitEditorDiffView tears down its WKWebView on unmount
        let standaloneMount = EditorTestSupport.host(
            GitEditorDiffView(request: request, theme: .oneDark, close: {}).frame(width: 600, height: 360),
            size: NSSize(width: 600, height: 360)
        )
        standaloneMount.1.orderFront(nil)
        let standaloneWeb = try await EditorTestSupport.waitForMonacoReady(in: standaloneMount.0.view)
        weak var weakWebView = standaloneWeb
        EditorTestSupport.unmount(standaloneMount)
        for _ in 0..<40 {
            if weakWebView?.superview == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(weakWebView?.superview == nil)
    }

    @Test func gitEditorDiffViewRendersPatchOnlyFallbackInPierreOverGlass() async throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-pierre-patch-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let before = (1...12).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        var afterLines = (1...12).map { "let line\($0) = \($0)" }
        afterLines[3] = "let line4 = 4096 // patch-only render"
        let after = afterLines.joined(separator: "\n") + "\n"
        let targetFile = repoRoot.appendingPathComponent("Oversized.swift")
        try Data(before.utf8).write(to: targetFile)
        for args in [["init", "--quiet"], ["add", "."]] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repoRoot.path)
            try #require(res.isSuccess)
        }
        try Data(after.utf8).write(to: targetFile)

        let repository = GitRepositoryIdentity(
            worktreePath: repoRoot.path,
            gitDirPath: repoRoot.path + "/.git",
            commonGitDirPath: repoRoot.path + "/.git"
        )
        let request = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Oversized.swift", status: "M")
        )
        let controller = MonacoWorkbenchController()
        let mounted = EditorTestSupport.host(
            GitEditorDiffView(
                request: request,
                theme: .oneDark,
                service: GitDiffService(sourceByteLimit: 32),
                externalController: controller,
                close: {}
            )
            .frame(width: 760, height: 420),
            size: NSSize(width: 760, height: 420)
        )
        mounted.1.orderFront(nil)
        defer {
            controller.tearDown()
            EditorTestSupport.unmount(mounted)
        }

        let webView = try await EditorTestSupport.waitForMonacoReady(in: mounted.0.view)
        for _ in 0..<120 {
            if controller.activeDiff?.patchOnly == true, controller.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!webView.isOpaque)
        #expect((webView.underPageBackgroundColor?.alphaComponent ?? 1) == 0)

        let domRaw = try await controller.evaluateJavaScriptForTesting("""
        (() => {
          const sr = document.querySelector('#diff-root diffs-container')?.shadowRoot;
          const st = window.omgEditor?.getDiffState?.() ?? {};
          return {
            patchOnly: Boolean(st.patchOnly),
            isPartial: Boolean(st.isPartial),
            changeCount: st.changeCount ?? 0,
            syntaxSpans: sr ? sr.querySelectorAll('span[style*="--omg-syntax-"]').length : 0,
            text: sr?.textContent ?? '',
            diffBg: document.getElementById('diff-root')?.style.getPropertyValue('--diffs-bg') ?? ''
          };
        })()
        """)
        let dom = try #require(domRaw as? [String: Any])
        #expect(dom["patchOnly"] as? Bool == true)
        #expect(dom["isPartial"] as? Bool == true)
        #expect((dom["changeCount"] as? Int ?? 0) >= 1)
        #expect((dom["syntaxSpans"] as? Int ?? 0) > 0)
        #expect((dom["text"] as? String)?.contains("4096") == true)
        #expect(dom["diffBg"] as? String == "transparent")
    }

    @Test func editorWorkspaceAndGitInspectorStayZeroWebViewUntilFirstOpenAndReapAfterIdle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-lazy-reap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codeFile = root.appendingPathComponent("Main.swift")
        try Data("let ready = true\n".utf8).write(to: codeFile)

        let repository = GitRepositoryIdentity(
            worktreePath: root.path,
            gitDirPath: root.path + "/.git",
            commonGitDirPath: root.path + "/.git"
        )
        let inspectorContent = InspectorGitContent(
            repository: repository,
            branch: "main",
            status: .ready(repository: repository, branch: "main", headCommitID: .init("abc1234")),
            activeTab: .changes
        )
        let inspectorMount = EditorTestSupport.host(
            InspectorGitView(content: inspectorContent, perform: { _ in })
                .frame(width: 300, height: 480),
            size: NSSize(width: 300, height: 480)
        )
        inspectorMount.1.orderFront(nil)
        defer { EditorTestSupport.unmount(inspectorMount) }

        let workspace = EditorWorkspace(idleReapDelay: .milliseconds(80))
        defer { workspace.cancelAndClear() }

        // Zero eager WebView allocation when workspace is idle and Git Inspector is open.
        try await Task.sleep(for: .milliseconds(100))
        #expect(workspace.workbenchController.webView == nil)
        #expect(workspace.diffWorkbenchController.webView == nil)
        #expect(EditorTestSupport.findAll(MonacoEditorWebView.self, in: inspectorMount.0.view).isEmpty)

        // First Git Diff open lazily allocates diffWorkbenchController.webView; code workbench stays nil.
        let requestA = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Alpha.swift", status: "M")
        )
        let requestB = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Beta.swift", status: "M")
        )
        workspace.openGitDiff(requestA)
        let firstDiffWebView = try #require(workspace.diffWorkbenchController.webView)
        #expect(workspace.workbenchController.webView == nil)

        // Second Git Diff open reuses the exact same warm WKWebView.
        workspace.openGitDiff(requestB)
        #expect(workspace.diffWorkbenchController.webView === firstDiffWebView)

        // Closing one diff while another remains open must NOT reap the pooled WebView.
        workspace.closeGitDiff(requestB)
        try await Task.sleep(for: .milliseconds(120))
        #expect(workspace.diffWorkbenchController.webView === firstDiffWebView)

        // Closing the last diff keeps the WebView warm briefly; reopening before idleReapDelay cancels reaping.
        workspace.closeGitDiff(requestA)
        #expect(workspace.gitDiffs.isEmpty)
        #expect(workspace.diffWorkbenchController.webView === firstDiffWebView)
        #expect(!workspace.diffWorkbenchController.isActive)

        try await Task.sleep(for: .milliseconds(25))
        let requestC = GitEditorDiffRequest(
            repository: repository,
            target: .staged,
            file: .init(path: "Gamma.swift", status: "A")
        )
        workspace.openGitDiff(requestC)
        #expect(workspace.diffWorkbenchController.webView === firstDiffWebView)

        // Closing all diffs and waiting past idleReapDelay tears down diffWorkbenchController.webView.
        workspace.closeGitDiff(requestC)
        #expect(workspace.diffWorkbenchController.webView === firstDiffWebView)
        for _ in 0..<40 {
            if workspace.diffWorkbenchController.webView == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.diffWorkbenchController.webView == nil)

        // Opening another diff after idle reaping cleanly boots a fresh WKWebView.
        let requestD = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Delta.swift", status: "M")
        )
        workspace.openGitDiff(requestD)
        let rebootedDiffWebView = try #require(workspace.diffWorkbenchController.webView)
        #expect(rebootedDiffWebView !== firstDiffWebView)
        workspace.closeGitDiff(requestD)

        // Code workbench follows the same empty-reaper contract once its last document closes.
        let fs = LocalWorkspaceFilesystem(workingDirectory: root.path)
        workspace.open(path: codeFile.path, filesystem: fs)
        for _ in 0..<60 {
            if !workspace.isLoading, workspace.selectedDocument != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let doc = try #require(workspace.selectedDocument)
        let codeWebView = workspace.workbenchController.ensureWebView()
        await workspace.close(doc, window: nil)
        #expect(workspace.documents.isEmpty)
        #expect(workspace.workbenchController.webView === codeWebView)
        for _ in 0..<40 {
            if workspace.workbenchController.webView == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.workbenchController.webView == nil)
    }

    @Test func pooledDiffTabsInContentDeckShareSingleWebViewWithoutInactiveTabTheft() async throws {
        let defaults = UserDefaults.standard
        let savedReview = defaults.object(forKey: "git.diff.review")
        let savedMode = defaults.object(forKey: "git.diff.viewMode")
        let savedWrap = defaults.object(forKey: "git.diff.wordWrap")
        defaults.set(true, forKey: "git.diff.review")
        defaults.set(GitL10n.text("Side by Side"), forKey: "git.diff.viewMode")
        defaults.set(true, forKey: "git.diff.wordWrap")
        defer {
            defaults.set(savedReview, forKey: "git.diff.review")
            defaults.set(savedMode, forKey: "git.diff.viewMode")
            defaults.set(savedWrap, forKey: "git.diff.wordWrap")
        }

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-pooled-diff-deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        try Data("let alpha = 1\n".utf8).write(to: repoRoot.appendingPathComponent("Alpha.swift"))
        try Data("let beta = 1\n".utf8).write(to: repoRoot.appendingPathComponent("Beta.swift"))
        for args in [["init", "--quiet"], ["add", "."]] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repoRoot.path)
            try #require(res.isSuccess)
        }
        try Data("let alpha = 2\n".utf8).write(to: repoRoot.appendingPathComponent("Alpha.swift"))
        try Data("let beta = 2\n".utf8).write(to: repoRoot.appendingPathComponent("Beta.swift"))

        let repository = GitRepositoryIdentity(
            worktreePath: repoRoot.path,
            gitDirPath: repoRoot.path + "/.git",
            commonGitDirPath: repoRoot.path + "/.git"
        )
        let requestA = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Alpha.swift", status: "M")
        )
        let requestB = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Beta.swift", status: "M")
        )

        let sharedWorkbench = MonacoWorkbenchController()
        let deck = EditorContentDeckController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = deck
        window.setContentSize(NSSize(width: 820, height: 460))
        window.makeKeyAndOrderFront(nil)
        defer {
            sharedWorkbench.tearDown()
            window.contentViewController = nil
            window.orderOut(nil)
            window.close()
        }

        func makeItems(selectedID: UUID) -> [EditorContentItem] {
            [requestA, requestB].map { req in
                EditorContentItem(
                    id: .diff(req.id),
                    content: AnyView(
                        GitEditorDiffView(
                            request: req,
                            theme: .oneDark,
                            isActive: req.id == selectedID,
                            externalController: sharedWorkbench,
                            close: {}
                        )
                    )
                )
            }
        }

        // 1. Mount and activate Tab A.
        deck.update(items: makeItems(selectedID: requestA.id), selectedID: .diff(requestA.id))
        deck.view.layoutSubtreeIfNeeded()
        let webView = try await EditorTestSupport.waitForMonacoReady(in: deck.view)
        for _ in 0..<120 {
            if sharedWorkbench.activeDiff?.path == "Alpha.swift", sharedWorkbench.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let hostA = try #require(deck.hosts[.diff(requestA.id)])
        #expect(sharedWorkbench.activeDiff?.path == "Alpha.swift")
        #expect(sharedWorkbench.isActive)
        #expect(EditorTestSupport.findAll(MonacoEditorWebView.self, in: deck.view).count == 1)
        #expect(webView.isDescendant(of: hostA))

        // 2. Switch to Tab B: must reuse the exact same WKWebView and move it into hostB.
        deck.update(items: makeItems(selectedID: requestB.id), selectedID: .diff(requestB.id))
        deck.view.layoutSubtreeIfNeeded()
        for _ in 0..<120 {
            if sharedWorkbench.activeDiff?.path == "Beta.swift" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let hostB = try #require(deck.hosts[.diff(requestB.id)])
        #expect(sharedWorkbench.webView === webView)
        #expect(sharedWorkbench.activeDiff?.path == "Beta.swift")
        #expect(sharedWorkbench.isActive)
        #expect(EditorTestSupport.findAll(MonacoEditorWebView.self, in: deck.view).count == 1)
        #expect(webView.isDescendant(of: hostB))
        #expect(!webView.isDescendant(of: hostA))

        // 3. Mutate @AppStorage while Tab A is hidden & inactive: Tab A must NOT steal webView or activeDiff.
        defaults.set(GitL10n.text("Inline"), forKey: "git.diff.viewMode")
        for _ in 0..<60 {
            if sharedWorkbench.activeDiff?.inline == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sharedWorkbench.activeDiff?.path == "Beta.swift")
        #expect(sharedWorkbench.activeDiff?.inline == true)
        #expect(webView.isDescendant(of: hostB))
        #expect(!webView.isDescendant(of: hostA))

        // 4. Switch back to Tab A: immediately swaps cached Alpha.swift back into the pooled WebView.
        deck.update(items: makeItems(selectedID: requestA.id), selectedID: .diff(requestA.id))
        deck.view.layoutSubtreeIfNeeded()
        for _ in 0..<60 {
            if sharedWorkbench.activeDiff?.path == "Alpha.swift", webView.isDescendant(of: hostA) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sharedWorkbench.webView === webView)
        #expect(sharedWorkbench.activeDiff?.path == "Alpha.swift")
        #expect(sharedWorkbench.activeDiff?.inline == true)
        #expect(sharedWorkbench.isActive)
        #expect(EditorTestSupport.findAll(MonacoEditorWebView.self, in: deck.view).count == 1)
        #expect(webView.isDescendant(of: hostA))
        #expect(!webView.isDescendant(of: hostB))
    }
}
