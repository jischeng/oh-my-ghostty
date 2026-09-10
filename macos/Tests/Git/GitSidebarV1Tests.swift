import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitSidebarV1Tests {
    @Test func sidebarTabSwitchesKeepHistoryTableAndScrollPosition() async throws {
        let repo = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let commits = (0..<100).map { GitHistoryCommit(id: .init("commit-\($0)"), parentIDs: [], authorName: "A", authorEmail: "", authoredAt: .distantPast, subject: "Commit \($0)") }
        var content = InspectorGitContent(repository: repo, branch: "main", status: .ready(repository: repo, branch: "main", headCommitID: nil),
                                          history: .init(commits: commits))
        let host = NSHostingView(rootView: InspectorGitView(content: content, perform: { _ in }))
        host.sizingOptions = []
        let win = window(host)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(NSTableView.self, in: host).first)
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin
        for tab in [InspectorGitContent.ActiveTab.changes, .branches, .history] {
            content = InspectorGitContent(repository: repo, branch: "main", status: content.status,
                                           activeTab: tab, history: content.history)
            host.rootView = InspectorGitView(content: content, perform: { _ in })
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            #expect(find(NSTableView.self, in: host).contains { $0 === table })
            #expect(scroll.contentView.bounds.origin == offset)
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
    private func window(_ view: NSView, height: CGFloat = 520) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func capture(_ view: NSView, path: String) throws {
        guard FileManager.default.fileExists(atPath: "/tmp/omg-git-render") else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @Test func stagingUpdatesPreserveComposerFocusSelectionScrollAndPinnedPosition() async throws {
        let repo = GitRepositoryIdentity(worktreePath: "/repo/omg", gitDirPath: "/repo/omg/.git", commonGitDirPath: "/repo/omg/.git")
        var content = InspectorGitContent(repository: repo, branch: "main", status: .ready(repository: repo, branch: "main", headCommitID: nil), activeTab: .changes)
        content.commitDraft = "A draft message"
        content.workingTree.unstaged = (0..<60).map { GitDiffFile(path: "Sources/File\($0).swift", status: "M") }
        let host = NSHostingView(rootView: InspectorGitView(content: content, perform: { _ in }).background(Color(NSColor.windowBackgroundColor)))
        host.sizingOptions = []
        let win = window(host)
        win.appearance = NSAppearance(named: .darkAqua)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(find(InspectorCopyableTextView.self, in: host).first)
        let composer = try #require(editor.enclosingScrollView)
        let files = try #require(find(NSScrollView.self, in: host).first { $0 !== composer && ($0.documentView?.bounds.height ?? 0) > 600 })
        files.contentView.scroll(to: NSPoint(x: 0, y: 160))
        files.reflectScrolledClipView(files.contentView)
        win.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 2, length: 5))
        let originalY = composer.convert(composer.bounds, to: host).minY
        let offset = files.contentView.bounds.origin
        for busy in [true, false] {
            content.isUpdatingIndex = busy
            content.operation = busy ? "Staging files…" : nil
            if !busy { content.workingTree.staged = [content.workingTree.unstaged.removeFirst()] }
            host.rootView = InspectorGitView(content: content, perform: { _ in }).background(Color(NSColor.windowBackgroundColor))
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            #expect(find(InspectorCopyableTextView.self, in: host).first === editor)
            #expect(win.firstResponder === editor)
            #expect(editor.string == "A draft message" && editor.selectedRange() == NSRange(location: 2, length: 5))
            #expect(abs(composer.convert(composer.bounds, to: host).minY - originalY) <= 0.5)
            #expect(files.contentView.bounds.origin == offset)
        }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            win.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(80))
            win.displayIfNeeded()
            try capture(host, path: "/tmp/omg-git-changes-\(appearance.rawValue).png")
        }
        content.commitDraft = (0..<30).map { "Message line \($0)" }.joined(separator: "\n")
        host.rootView = InspectorGitView(content: content, perform: { _ in }).background(Color(NSColor.windowBackgroundColor))
        try await Task.sleep(for: .milliseconds(100))
        #expect(composer.bounds.height <= 112 && composer.bounds.height > 44)
        #expect(win.firstResponder === editor)
        content.workingTree.staged = []
        content.workingTree.unstaged = []
        host.rootView = InspectorGitView(content: content, perform: { _ in }).background(Color(NSColor.windowBackgroundColor))
        try await Task.sleep(for: .milliseconds(100))
        win.displayIfNeeded()
        try capture(host, path: "/tmp/omg-git-changes-empty.png")
    }

    @Test func commitMenuIsGroupedAndKeepsTheClickedCommitWhileSelectionChanges() async throws {
        let commits = ["aaa1111", "bbb2222"].map { GitHistoryCommit(id: .init($0), parentIDs: [], authorName: "A", authorEmail: "a@example.com", authoredAt: .distantPast, subject: $0) }
        var actions: [(GitCommitOperation, GitCommitID)] = []
        var root = GitHistoryTable(commits: commits, selectedCommitID: nil, onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in },
                                   onCommitAction: { actions.append(($0, $1)) })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let win = window(host, height: 250)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(NSTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = try #require(table.menu)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.filter(\.isSeparatorItem).count == 3)
        #expect(menu.items.contains { $0.title == "Copy Commit Hash" })
        let pick = try #require(menu.items.firstIndex { $0.identifier?.rawValue == GitCommitOperation.cherryPick.rawValue })
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        menu.performActionForItem(at: pick)
        #expect(actions.last?.0 == .cherryPick && actions.last?.1 == commits[0].id)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let subject = try #require(cell.subviews.compactMap { $0 as? InspectorCopyableTextField }.first)
        let fieldMenus = [subject.menu(for: event)] + find(InspectorMetadataText.self, in: cell).map { $0.menu(for: event) }
        for fieldMenu in fieldMenus {
            let fieldMenu = try #require(fieldMenu)
            coordinator.menuNeedsUpdate(fieldMenu)
            #expect(fieldMenu.items.contains { $0.identifier?.rawValue == "createWorktree" })
            #expect(fieldMenu.items.first { $0.title == "Copy Commit Hash" }?.representedObject as? String == commits[0].id.rawValue)
        }
        root.isBusy = true
        coordinator.update(root)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.first { $0.identifier?.rawValue == "cherryPick" }?.isEnabled == false)
        #expect(menu.items.first { $0.identifier?.rawValue == "compareWithHead" }?.isEnabled == true)
    }
}
