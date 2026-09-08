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
            window.contentView = nil
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
        defer { window.contentView = nil; window.close() }
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

    @Test func branchSelectionDoesNotNavigateUntilDoubleClickAndMenuHasWriteActions() async throws {
        let branch = GitBranchInfo(name: "main", commit: GitCommitID("abc"), isCurrent: true,
                                   isRemote: false, upstream: "origin/main", tracking: "")
        var actions: [InspectorGitAction] = []
        let view = NSHostingView(rootView: GitBranchTree(branches: [branch], isBusy: false) { actions.append($0) }
            .frame(width: 240, height: 260))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let tree = try #require(descendant(NSOutlineView.self, in: view))
        tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(actions.isEmpty)
        let coordinator = try #require(tree.target as? GitBranchTree.Coordinator)
        coordinator.openHistory()
        #expect(actions == [.browseBranch(branch.id)])
        let menu = try #require(tree.menu)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == "New Branch from Here…" })
        #expect(menu.items.contains { $0.title == "Push…" })
        #expect(menu.items.contains { $0.title == "Set Upstream…" })
        #expect(menu.items.first(where: { $0.title == "Switch Branch" })?.isEnabled == false)
    }

    @Test func linkedDiffScrollsBothDirectionsBySourceLinesAndCanBeDisabled() async throws {
        let beforeLines = (0..<200).map { "line \($0)" }
        var afterLines = beforeLines
        afterLines.insert(contentsOf: ["inserted one", "inserted two"], at: 21)
        let before = beforeLines.joined(separator: "\n") + "\n"
        let after = afterLines.joined(separator: "\n") + "\n"
        let link = GitDiffScrollLink()
        link.presentation = GitDiffPresentation(before: before, after: after,
                                                        patch: "@@ -21,0 +22,2 @@\n+inserted one\n+inserted two\n")
        func root(_ identity: String) -> some View {
            HStack(spacing: 0) {
                GitDiffLinkedEditor(text: before, path: "/before.txt", highlights: [:], isActive: true,
                                    theme: .oneDark, link: link, side: 0, close: {}).id(identity + "-left")
                GitDiffLinkedEditor(text: after, path: "/after.txt", highlights: [:], isActive: true,
                                    theme: .oneDark, link: link, side: 1, close: {}).id(identity + "-right")
            }.frame(width: 900, height: 300)
        }
        let view = NSHostingView(rootView: root("first"))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(250))
        func editors(_ view: NSView) -> [TextView] {
            if let text = view as? TextView { return [text] }
            return view.subviews.flatMap(editors)
        }
        let values = editors(view)
        #expect(values.count == 2)
        let left = try #require(values.first)
        let right = try #require(values.last)
        func scroll(_ text: TextView, to index: Int) throws {
            let line = try #require(text.layoutManager.textLineForIndex(index))
            let clip = try #require(text.enclosingScrollView?.contentView)
            clip.scroll(to: NSPoint(x: 0, y: line.yPos))
            text.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        func expectPosition(_ text: TextView, at index: Int) throws {
            let line = try #require(text.layoutManager.textLineForIndex(index))
            let origin = try #require(text.enclosingScrollView?.contentView.bounds.minY)
            // NSClipView rounds scroll origins to backing pixels. A fractional
            // sliver of the preceding line must not count as a whole-line error.
            #expect(abs(origin - line.yPos) <= 1)
        }
        try scroll(left, to: 80)
        try expectPosition(right, at: 82)
        try scroll(right, to: 120)
        try expectPosition(left, at: 118)
        link.enabled = false
        let previous = right.enclosingScrollView?.contentView.bounds.origin
        try scroll(left, to: 30)
        #expect(right.enclosingScrollView?.contentView.bounds.origin == previous)
        link.enabled = true
        view.rootView = root("replacement")
        try await Task.sleep(for: .milliseconds(200))
        let replacements = editors(view)
        let nextLeft = try #require(replacements.first)
        let nextRight = try #require(replacements.last)
        #expect(nextLeft !== left && nextRight !== right)
        try scroll(nextLeft, to: 60)
        try expectPosition(nextRight, at: 62)
        try scroll(nextRight, to: 100)
        try expectPosition(nextLeft, at: 98)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.compactMap { descendant(type, in: $0) }.first
    }
}
