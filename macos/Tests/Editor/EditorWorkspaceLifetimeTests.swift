import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct EditorWorkspaceLifetimeTests {
    @Test(arguments: ["txt", "md"])
    func diffAndTabSwitchingReuseOneSharedMonacoWebViewAndPreserveEdits(fileExtension: String) async throws {
        let presentation = InspectorPresentationStore.shared.snapshot
        defer { InspectorPresentationStore.shared.replace(with: presentation) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("document." + fileExtension)
        let original = (0..<80).map { "line \($0)\n" }.joined()
        try Data(original.utf8).write(to: file)

        let secondFile = root.appendingPathComponent("second.swift")
        try Data("struct SecondFile {}\n".utf8).write(to: secondFile)

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = root.path
        configuration.command = "/bin/sh"
        let controller = TerminalController(app, withBaseConfig: configuration)
        let surface = try #require(controller.surfaceTree.first)
        let window = try #require(controller.window)
        defer {
            EditorWorkspaceStore.shared.remove(tabID: controller.tabSessionID)
            window.contentView = nil
            window.delegate = nil
            window.close()
        }

        let host = NSHostingView(
            rootView: EditorWorkspaceHost(controller: controller, surfaceView: surface) { Color.clear }
        )
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 800, height: 600))
        window.makeKeyAndOrderFront(nil)

        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        let workspace = EditorWorkspaceStore.shared.workspace(
            for: controller.tabSessionID,
            surfaceID: surface.id
        )
        workspace.open(path: file.path, filesystem: filesystem)
        for _ in 0..<150 {
            if !workspace.isLoading, workspace.selectedDocument != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let document = try #require(workspace.selectedDocument)
        document.suspendAutoSave()

        if fileExtension == "md" {
            let modes = try #require(EditorTestSupport.find(NSSegmentedControl.self, in: host))
            modes.selectedSegment = 0
            if let action = modes.action { modes.sendAction(action, to: modes.target) }
        }

        let webView = try await EditorTestSupport.waitForMonacoReady(in: host)
        for _ in 0..<100 {
            let activeURI = (try? await webView.evaluateJavaScript("window.omgEditor?.getState?.()?.activeUri")) as? String
            if activeURI == document.id.monacoURI { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        // Apply a user edit inside Monaco so undo stack and dirty state are populated.
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const ed = window.omgEditor._internal.editor;
            const monaco = window.omgEditor._internal.monaco;
            ed.focus();
            ed.executeEdits('test-user', [{
                range: new monaco.Range(1, 1, 1, 1),
                text: 'edited\\n'
            }]);
            ed.setScrollTop(240);
            return ed.getValue();
        })()
        """)
        for _ in 0..<80 {
            if document.isDirty && document.text.hasPrefix("edited\n") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(document.text == "edited\n" + original && document.isDirty)

        // Opening a second tab in the same workspace must reuse the exact same WKWebView instance.
        workspace.open(path: secondFile.path, filesystem: filesystem)
        for _ in 0..<100 {
            if !workspace.isLoading, workspace.selectedDocument?.path == secondFile.path { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let allWebViews = EditorTestSupport.findAll(MonacoEditorWebView.self, in: host)
        #expect(allWebViews.count == 1, "All tabs in a workspace must share a single pooled MonacoEditorWebView")
        #expect(allWebViews.first === webView)

        // Switching to a Git diff deck card and back must also preserve the pooled WKWebView and undo stack.
        workspace.openGitDiff(.init(
            repository: .init(
                worktreePath: root.path,
                gitDirPath: root.path + "/.git",
                commonGitDirPath: root.path + "/.git"
            ),
            target: .staged,
            file: nil
        ))
        try await Task.sleep(for: .milliseconds(120))
        #expect(EditorTestSupport.find(MonacoEditorWebView.self, in: host) === webView)
        #expect(document.isDirty)

        workspace.selectedID = document.id
        for _ in 0..<100 {
            let activeURI = (try? await webView.evaluateJavaScript("window.omgEditor?.getState?.()?.activeUri")) as? String
            if activeURI == document.id.monacoURI { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(EditorTestSupport.find(MonacoEditorWebView.self, in: host) === webView)

        _ = try await webView.evaluateJavaScript("""
        (() => {
            const ed = window.omgEditor._internal.editor;
            ed.trigger('test', 'undo', null);
            return ed.getValue();
        })()
        """)
        for _ in 0..<80 {
            if document.text == original { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(document.text == original && !document.isDirty)
        if fileExtension == "md" {
            #expect(EditorTestSupport.find(NSSegmentedControl.self, in: host)?.selectedSegment == 0)
        }
    }
}
