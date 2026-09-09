import AppKit
import SwiftUI
import Testing
import CodeEditTextView
@testable import Ghostty

@MainActor
struct GitHistoryInteractionTests {
    private func commit(_ id: String, refs: [GitRefDecoration] = []) -> GitHistoryCommit {
        GitHistoryCommit(id: GitCommitID(id), parentIDs: [], authorName: "Author", authorEmail: "a@example.com",
                         authoredAt: Date(timeIntervalSince1970: 0), subject: "Commit " + id, refDecorations: refs)
    }
    private func hostWindow<V: View>(_ root: V, width: CGFloat = 260, height: CGFloat = 450) -> NSWindow {
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        if let value = view as? T { return value }
        return view?.subviews.compactMap { find(type, in: $0) }.first
    }

    @Test func decorationsPutMainAndBranchesBeforeTagsAndWrap() {
        let refs: [GitRefDecoration] = [
            .init(name: "v1", kind: .tag), .init(name: "feature", kind: .currentBranch),
            .init(name: "origin/main", kind: .remoteBranch), .init(name: "main", kind: .localBranch),
            .init(name: "develop", kind: .localBranch),
        ]
        #expect(GitRefDecoration.orderedForDisplay(refs).map(\.name) == ["main", "origin/main", "feature", "develop", "v1"])
        let narrow = GitRefBadgesView.height(for: refs, width: 130)
        let wide = GitRefBadgesView.height(for: refs, width: 600)
        #expect(narrow > wide)
        let frames = GitRefBadgesView.frames(widths: [300, 60, 60], availableWidth: 130)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.maxX <= 130 })
        #expect(frames[1].minY > frames[0].minY)
        #expect(GitGraphCellView.preferredWidth(laneCount: 1) <= 20)
    }

    @Test func expandedRowsOnlyOpenDiffWhenAFileIsClickedAndHeadIsIndependentOfSelection() async throws {
        let first = commit("aaa")
        let head = commit("bbb")
        let file = GitDiffFile(path: "Sources/File.swift", status: "M")
        let details = GitCommitExpansion(metadata: GitCommitMetadata(commitID: first.id, authorName: "Author",
            authorEmail: "a@example.com", authoredAt: "2026-09-08", parents: [], message: "Full message\n\nCommit body"), files: [file])
        var toggled: [GitCommitID] = []
        var opened: [GitDiffFile] = []
        let root = GitHistoryTable(commits: [first, head], selectedCommitID: first.id, headCommitID: head.id,
            expandedCommits: [first.id: details], onSelect: { _ in }, onOpen: { toggled.append($0) },
            onShowInTerminal: { _ in }, onOpenFile: { id, file in
                #expect(id == first.id)
                opened.append(file)
            })
        let window = hostWindow(root)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let table = try #require(find(NSTableView.self, in: window.contentView))
        #expect(table.numberOfRows == 4)
        #expect(table.effectiveStyle == .plain)
        let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
        coordinator.activateRow(0, doubleClick: false)
        #expect(opened.isEmpty && toggled.isEmpty)
        coordinator.activateRow(0, doubleClick: true)
        #expect(toggled == [first.id] && opened.isEmpty)
        coordinator.activateRow(2, doubleClick: false)
        #expect(opened == [file])
        let firstCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let headCell = table.view(atColumn: 0, row: 3, makeIfNecessary: true)
        let firstGraph = try #require(find(GitGraphCellView.self, in: firstCell))
        let headGraph = try #require(find(GitGraphCellView.self, in: headCell))
        #expect(!firstGraph.isHead && headGraph.isHead)
        #expect(firstGraph.frame.width > 0 && firstGraph.frame.width <= 31)
        let metadata = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        let detailLabel = try #require(find(NSTextField.self, in: metadata))
        #expect(detailLabel.stringValue.contains("Commit body"))
        let requiredHeight = try #require(detailLabel.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: detailLabel.bounds.width, height: .greatestFiniteMagnitude)).height)
        #expect(detailLabel.bounds.height >= requiredHeight)
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render"), let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-expanded.png"))
        }
    }

    @Test func scrollingToBottomRequestsOnePageAndDoesNotLoopWhileLoadingOrOnError() async throws {
        var requested = 0
        var root = GitHistoryTable(commits: (0..<100).map { commit(String($0)) }, selectedCommitID: nil,
                                   hasMore: true, onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in },
                                   onLoadMore: { requested += 1 })
        let window = hostWindow(root, height: 250)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let table = try #require(find(NSTableView.self, in: window.contentView))
        let scroll = try #require(table.enclosingScrollView)
        let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
        #expect(requested == 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.requestMoreIfNeeded()
        coordinator.requestMoreIfNeeded()
        #expect(requested == 1)
        root.isLoading = true
        coordinator.update(root)
        coordinator.requestMoreIfNeeded()
        #expect(requested == 1)
        root.isLoading = false
        root.automaticLoadingAllowed = false
        coordinator.update(root)
        coordinator.requestMoreIfNeeded()
        #expect(requested == 1)
    }

    @Test func diffErrorViewStillSupportsHideAndClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var hidden = false
        var closed = false
        let repository = GitRepositoryIdentity(worktreePath: directory.path, gitDirPath: directory.path + "/.git",
                                               commonGitDirPath: directory.path + "/.git")
        let root = GitEditorDiffView(request: .init(repository: repository, target: .staged, file: nil),
            theme: .oneDark, actions: GitDiffEditorActions(hide: { hidden = true }), close: { closed = true })
        let window = hostWindow(root)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        for (key, code, modifiers) in [("\u{1b}", UInt16(53), NSEvent.ModifierFlags.shift), ("w", UInt16(13), .command)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(EditorCommandRouter.shared.handle(event))
        }
        #expect(hidden && closed)
    }

    @Test func diffEditorForwardsHideOpenAndDocumentNavigationShortcuts() async throws {
        var hidden = false
        var opened = false
        var next = false
        let link = GitDiffScrollLink()
        let view = GitDiffLinkedEditor(text: "let value = 1", path: "/file.swift", highlights: [0: true],
            isActive: true, theme: .oneDark, link: link, side: 0,
            actions: GitDiffEditorActions(hide: { hidden = true }, open: { opened = true }, nextDocument: { next = true }),
            close: {})
        let window = hostWindow(view)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try #require(find(TextView.self, in: window.contentView))
        window.makeFirstResponder(editor)
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            #expect(EditorCommandRouter.shared.handle(event))
        }
        try key("\u{1b}", code: 53, modifiers: .shift)
        #expect(hidden)
        try key("o", code: 31, modifiers: .command)
        #expect(opened)
        try key("\t", code: 48, modifiers: .control)
        #expect(next)
    }
}
