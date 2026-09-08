import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitInspectorLayoutTests {
    @Test func historyFitsMinimumInspectorWidthWithLongRefs() async throws {
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let commit = GitHistoryCommit(id: GitCommitID("1234567890"), parentIDs: [], authorName: "Contributor",
                                      authorEmail: "author@example.com", authoredAt: Date(timeIntervalSince1970: 0),
                                      subject: "A long commit subject that must truncate within the sidebar",
                                      refDecorations: [
                                        .init(name: "feature/very-long-current-branch", kind: .currentBranch),
                                        .init(name: "v1.2.3", kind: .tag),
                                        .init(name: "origin/main", kind: .remoteBranch),
                                      ])
        var content = InspectorGitContent(repository: repository, branch: "feature/very-long-current-branch",
                                          status: .ready(repository: repository, branch: "main", headCommitID: commit.id),
                                          history: .init(commits: [commit]))
        content.workingTree.branches = [
            .init(name: "feature/very-long-current-branch", commit: commit.id, isCurrent: true,
                  isRemote: false, upstream: "origin/main", tracking: "[ahead 12, behind 3]"),
        ]
        for width in [220.0, 360.0] {
            let view = NSHostingView(rootView: InspectorGitView(content: content, perform: { _ in }))
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            window.setContentSize(NSSize(width: width, height: 500))
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let table = try #require(descendant(NSTableView.self, in: view))
            #expect(table.bounds.width <= width)
            #expect(table.tableColumns[0].width <= width)
            #expect(table.numberOfRows == 1)
            if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-history-\(Int(width)).png"))
            }
            window.close()
        }
    }

    @Test func sourceComparisonUsesReadOnlyEditorAndLineTint() async throws {
        let source = """
        import Foundation

        struct Commit {
            let subject: String
            let count = 42
        }
        """
        let view = NSHostingView(rootView: CodeEditorView(text: .constant(source),
            fileURL: URL(fileURLWithPath: "/example.swift"), diffLines: [4: true], isEditable: false, terminalTheme: .oneDark)
            .frame(width: 640, height: 300).background(Color(NSColor.textBackgroundColor)))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let editor = try #require(descendant(TextView.self, in: view))
        #expect(editor.string == source)
        #expect(!editor.isEditable)
        let numberOffset = (source as NSString).range(of: "42").location
        for _ in 0..<40 {
            let color = editor.textStorage.attribute(.foregroundColor, at: numberOffset, effectiveRange: nil) as? NSColor
            if color != nil && color != editor.textColor { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let numberColor = editor.textStorage.attribute(.foregroundColor, at: numberOffset, effectiveRange: nil) as? NSColor
        #expect(numberColor != nil && numberColor != editor.textColor)
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-editor.png"))
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.compactMap { descendant(type, in: $0) }.first
    }
}
