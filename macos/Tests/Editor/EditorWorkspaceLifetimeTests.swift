import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct EditorWorkspaceLifetimeTests {
    @Test(arguments: ["txt", "md"])
    func diffPreservesTheNativeDocumentEditorAndUndo(fileExtension: String) async throws {
        let presentation = InspectorPresentationStore.shared.snapshot
        defer { InspectorPresentationStore.shared.replace(with: presentation) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document." + fileExtension)
        let original = (0..<200).map { "line \($0)\n" }.joined()
        try Data(original.utf8).write(to: file)
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
        let host = NSHostingView(rootView: EditorWorkspaceHost(controller: controller, surfaceView: surface) { Color.clear })
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 800, height: 600))
        window.makeKeyAndOrderFront(nil)
        let workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: surface.id)
        workspace.open(path: file.path, filesystem: LocalWorkspaceFilesystem(workingDirectory: root.path))
        for _ in 0..<100 {
            if !workspace.isLoading && find(TextView.self, in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let document = try #require(workspace.selectedDocument)
        document.suspendAutoSave()
        let editor = try #require(find(TextView.self, in: host))
        if fileExtension == "md" {
            let modes = try #require(find(NSSegmentedControl.self, in: host))
            modes.selectedSegment = 0
            if let action = modes.action { modes.sendAction(action, to: modes.target) }
        }
        try await Task.sleep(for: .milliseconds(150))
        try #require(editor.isEditable)
        window.makeFirstResponder(editor)
        editor._undoManager?.clearStack()
        editor.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("edited\n")
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.text == "edited\n" + original && document.isDirty)
        let selected = (editor.string as NSString).range(of: "line 80")
        editor.selectionManager.setSelectedRange(selected)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        let line = try #require(editor.layoutManager.textLineForOffset(selected.location))
        clip.scroll(to: NSPoint(x: 0, y: line.yPos))
        editor.enclosingScrollView?.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(100))
        let origin = clip.bounds.origin
        workspace.openGitDiff(.init(repository: .init(worktreePath: root.path, gitDirPath: root.path + "/.git",
                                                      commonGitDirPath: root.path + "/.git"), target: .staged, file: nil))
        try await Task.sleep(for: .milliseconds(150))
        #expect(find(TextView.self, in: host) === editor)
        #expect(!editor.isEditable && document.isDirty)
        workspace.selectedID = document.id
        try await Task.sleep(for: .milliseconds(150))
        #expect(find(TextView.self, in: host) === editor)
        #expect(editor.isEditable)
        #expect(editor.selectionManager.textSelections.first?.range == selected)
        #expect(abs(clip.bounds.minY - origin.y) <= 1)
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.string == original && document.text == original)
        if fileExtension == "md" { #expect(find(NSSegmentedControl.self, in: host)?.selectedSegment == 0) }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.compactMap { find(type, in: $0) }.first
    }
}
