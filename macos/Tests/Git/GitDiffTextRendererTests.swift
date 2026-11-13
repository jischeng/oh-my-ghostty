import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

struct GitDiffTextRendererTests {
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

    @MainActor
    @Test func swiftDiffContainingBinaryMarkerLiteralsRendersInPierreWhileRealBinaryUsesPlaceholder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-binary-literal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = """
        enum GitDiffTextRenderer {
            static func isMetadata(_ line: String) -> Bool {
                line.hasPrefix("Binary files ")
            }
        }
        """ + "\n"
        let after = """
        enum GitDiffTextRenderer {
            static func isMetadata(_ line: String) -> Bool {
                // GIT binary patch
                false
            }
        }
        """ + "\n"

        let swiftFile = root.appendingPathComponent("GitDiffTextView.swift")
        let binaryFile = root.appendingPathComponent("icon.png")
        try Data(before.utf8).write(to: swiftFile)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: binaryFile)
        for args in [
            ["init", "--quiet"],
            ["config", "user.name", "Diff Test"],
            ["config", "user.email", "diff@example.com"],
            ["add", "."],
            ["commit", "-m", "initial", "--quiet"],
        ] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: root.path)
            try #require(res.isSuccess)
        }
        try Data(after.utf8).write(to: swiftFile)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE]).write(to: binaryFile)

        let repository = GitRepositoryIdentity(
            worktreePath: root.path,
            gitDirPath: root.path + "/.git",
            commonGitDirPath: root.path + "/.git"
        )
        var selectedPath: String?
        let workbench = MonacoWorkbenchController()
        defer { workbench.tearDown() }

        let view = NSHostingView(
            rootView: GitEditorDiffView(
                request: GitEditorDiffRequest(
                    repository: repository,
                    target: .unstaged,
                    file: .init(path: "GitDiffTextView.swift", status: "M")
                ),
                theme: .oneDark,
                actions: GitDiffEditorActions(selectFile: { selectedPath = $0?.path }),
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
            if workbench.activeDiff?.path == "GitDiffTextView.swift", workbench.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        view.layoutSubtreeIfNeeded()

        let snapshot = try #require(workbench.activeDiff)
        #expect(snapshot.path == "GitDiffTextView.swift")
        #expect(!snapshot.patchOnly)
        #expect(snapshot.originalText == before)
        #expect(snapshot.modifiedText == after)
        #expect(snapshot.patch.contains("-        line.hasPrefix(\"Binary files \")"))
        #expect(snapshot.patch.contains("+        // GIT binary patch"))
        #expect(workbench.isActive)

        // Switching to the real binary file deactivates the Pierre surface and shows the placeholder.
        func buttons(in node: NSView) -> [NativeActionControl] {
            (node as? NativeActionControl).map { [$0] } ?? node.subviews.flatMap(buttons)
        }
        let nextFile = try #require(buttons(in: view).first { $0.toolTip == GitL10n.text("Next file") })
        let refresh = try #require(buttons(in: view).first { $0.toolTip == GitL10n.text("Refresh diff") })
        nextFile.performClick(nil)
        for _ in 0..<120 {
            view.layoutSubtreeIfNeeded()
            if selectedPath == "icon.png", refresh.isEnabled { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(selectedPath == "icon.png")
        #expect(refresh.isEnabled)
        #expect(!workbench.isActive)
        #expect(workbench.activeDiff?.path == "GitDiffTextView.swift")

        // Opening a binary diff on a cold workbench must NOT allocate a WKWebView at all.
        let coldBinaryWorkbench = MonacoWorkbenchController()
        defer { coldBinaryWorkbench.tearDown() }
        let binaryView = NSHostingView(
            rootView: GitEditorDiffView(
                request: GitEditorDiffRequest(
                    repository: repository,
                    target: .unstaged,
                    file: .init(path: "icon.png", status: "M")
                ),
                theme: .oneDark,
                externalController: coldBinaryWorkbench,
                close: {}
            )
            .frame(width: 720, height: 420)
        )
        window.contentView = binaryView
        for _ in 0..<40 {
            binaryView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(coldBinaryWorkbench.webView == nil)
    }
}
