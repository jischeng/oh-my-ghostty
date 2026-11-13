import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

struct GitDiffTextRendererTests {
    @Test func numbersOnlyHunkLinesAndColorsPlusMinusContent() {
        let diff = """
        diff --git a/file.txt b/file.txt
        index 1234567..7654321 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,2 +1,3 @@
        -old
        +++literal-add
         context
        ---literal-delete
        """

        let rendered = GitDiffTextRenderer.render(diff).string
        let lines = rendered.components(separatedBy: "\n")
        #expect(lines.count == 9)
        #expect(prefix(of: lines[0]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[1]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[2]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[3]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[4]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[5]).contains("1"))
        #expect(prefix(of: lines[6]).contains("1"))
        #expect(prefix(of: lines[7]).contains("2"))
        #expect(prefix(of: lines[8]).contains("3"))
        #expect(lines[6].contains("+++literal-add"))
        #expect(lines[8].contains("---literal-delete"))
    }

    @MainActor
    @Test func fallbackPatchRendersInTransparentPierreWebViewInsteadOfOpaqueTextView() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-patch-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("base\n".utf8).write(to: root.appendingPathComponent("large.swift"))
        for args in [["init", "--quiet"], ["add", "large.swift"]] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: root.path)
            try #require(res.isSuccess)
        }
        try Data(String(repeating: "let largeLine = 1\n", count: 80).utf8)
            .write(to: root.appendingPathComponent("large.swift"))

        let repository = GitRepositoryIdentity(
            worktreePath: root.path,
            gitDirPath: root.path + "/.git",
            commonGitDirPath: root.path + "/.git"
        )
        let request = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "large.swift", status: "M")
        )
        let workbench = MonacoWorkbenchController()
        defer { workbench.tearDown() }

        let view = NSHostingView(
            rootView: GitEditorDiffView(
                request: request,
                theme: .oneDark,
                service: GitDiffService(sourceByteLimit: 64),
                externalController: workbench,
                close: {}
            )
            .frame(width: 720, height: 420)
        )
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        for _ in 0..<120 {
            if workbench.activeDiff != nil, workbench.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        view.layoutSubtreeIfNeeded()

        let snapshot = try #require(workbench.activeDiff)
        #expect(snapshot.patchOnly)
        #expect(snapshot.originalText.isEmpty)
        #expect(snapshot.modifiedText.isEmpty)
        #expect(snapshot.patch.contains("+let largeLine = 1"))

        let webView = try #require(workbench.webView)
        #expect(!webView.isOpaque)
        #expect((webView.underPageBackgroundColor?.alphaComponent ?? 1) == 0)

        func textViews(in node: NSView) -> [NSTextView] {
            if let tv = node as? NSTextView { return [tv] }
            return node.subviews.flatMap(textViews)
        }
        #expect(textViews(in: view).isEmpty, "Patch fallback must render in Pierre WebView, not an opaque NSTextView")
    }

    private func prefix(of line: String) -> String {
        String(line.split(separator: "│", maxSplits: 1).first ?? "")
    }
}
