import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitInspectorUsabilityTests {
    private func window(_ view: NSView, width: CGFloat = 360, height: CGFloat = 300) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
    private func key(_ char: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: char,
            charactersIgnoringModifiers: char, isARepeat: false, keyCode: char == "c" ? 8 : 0))
    }

    @Test func nativeInspectorSelectionAndRefButtonsActuallyCopyFullValues() async throws {
        let value = "renjiejiang02 · renjiejiang02@deeproute.ai"
        let field = InspectorCopyableTextField(labelWithString: value)
        field.isSelectable = true
        let board = NSPasteboard.withUniqueName()
        field.pasteboard = board
        let host = window(field)
        defer { host.contentView = nil; host.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange((value as NSString).range(of: "renjiejiang02@deeproute.ai"))
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == "renjiejiang02@deeproute.ai")
        #expect(EditorCommandRouter.shared.handle(try key("a", in: host)))
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == value)

        let ref = GitRefDecoration(name: "release/" + String(repeating: "long-reference-", count: 16), kind: .tag)
        let list = GitRefListView()
        list.configure([ref])
        list.frame = NSRect(x: 0, y: 0, width: 360, height: GitRefListView.height(for: [ref], width: 360))
        host.contentView = list
        list.layoutSubtreeIfNeeded()
        let copy = try #require(find(InspectorCopyButton.self, in: list).last { $0.value == ref.name })
        copy.pasteboard = board
        copy.performClick(nil)
        #expect(board.string(forType: .string) == ref.name)
        let refField = try #require(find(InspectorCopyableTextField.self, in: list).first)
        refField.pasteboard = board
        refField.selectText(nil)
        #expect(EditorCommandRouter.shared.handle(try key("a", in: host)))
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == ref.name)
    }

    @Test func tableShortcutAndContextMenuCopyCommitFields() async throws {
        let commit = GitHistoryCommit(id: .init("0123456789abcdef"), parentIDs: [], authorName: "Author",
            authorEmail: "author@example.com", authoredAt: Date(), subject: "A full untruncated commit subject")
        let view = NSHostingView(rootView: GitHistoryTable(commits: [commit], selectedCommitID: nil,
            onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in }))
        view.sizingOptions = []
        let host = window(view)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(InspectorCopyTableView.self, in: view).first)
        let board = NSPasteboard.withUniqueName()
        table.pasteboard = board
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        host.makeFirstResponder(table)
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == commit.subject)
        let menu = try #require(table.menu as? InspectorCopyMenu)
        (table.target as? GitHistoryTable.Coordinator)?.menuNeedsUpdate(menu)
        menu.pasteboard = board
        let index = try #require(menu.items.firstIndex { $0.title == "Copy email" })
        menu.performActionForItem(at: index)
        #expect(board.string(forType: .string) == commit.authorEmail)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let subject = try #require(find(NSTextField.self, in: cell).first)
        let center = subject.frame.minY + subject.firstBaselineOffsetFromTop - (subject.font?.capHeight ?? 0) / 2
        #expect(abs(center - GitGraphColumnLayout.contentAxisY) <= 0.5)
        let fields = cell.subviews.compactMap { $0 as? InspectorCopyableTextField }
        let identity = try #require(fields.first { $0.stringValue.contains(commit.authorEmail) })
        identity.pasteboard = board
        let copyMenu = try #require(identity.menu(for: try key("c", in: host)))
        let emailIndex = try #require(copyMenu.items.firstIndex { $0.title == "Copy email" })
        copyMenu.performActionForItem(at: emailIndex)
        #expect(board.string(forType: .string) == commit.authorEmail)
    }

    @Test func repositoryHeaderShowsCopyablePathRemoteAndHeadTags() async throws {
        let repository = GitRepositoryIdentity(worktreePath: "/repo/oh-my-ghostty", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let rows: [(String, [String], String)] = [
            ("3df9918", ["5f1627b", "b7ee389"], "macos: integrate source-first markdown"),
            ("b7ee389", ["5f1627b"], "macos: replace milkdown with source editor"),
            ("5f1627b", ["67259da"], "macos/preview: restore clean github rendering"),
            ("67259da", [], "macos: set pointer cursor on link hover"),
        ]
        let commits = rows.enumerated().map { index, row in
            GitHistoryCommit(id: .init(row.0), parentIDs: row.1.map(GitCommitID.init), authorName: "jischeng",
                authorEmail: "j.s.cheng@hotmail.com", authoredAt: Date(timeIntervalSince1970: 1_788_800_000), subject: row.2,
                refDecorations: [.init(name: "codex/markdown-source-editor", kind: index == 0 ? .currentBranch : .localBranch),
                                 .init(name: "dev-v0.11.0-" + row.0, kind: .tag), .init(name: "release-" + row.0, kind: .tag)])
        }
        var content = InspectorGitContent(repository: repository, branch: "codex/markdown-source-editor",
            status: .ready(repository: repository, branch: "main", headCommitID: commits[0].id),
            history: .init(commits: commits))
        content.workingTree.remoteURL = "https://example.com/team/oh-my-ghostty.git"
        let view = NSHostingView(rootView: InspectorGitView(content: content, perform: { _ in })
            .background(Color(NSColor.windowBackgroundColor)))
        view.sizingOptions = []
        let host = window(view, width: 265, height: 780)
        host.appearance = NSAppearance(named: .darkAqua)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let fields = find(InspectorCopyableTextField.self, in: view)
        #expect(fields.contains { $0.stringValue == repository.worktreePath })
        #expect(fields.contains { $0.stringValue == content.workingTree.remoteURL })
        let headerRefs = try #require(find(GitRefBadgesView.self, in: view).first { group in
            var ancestor = group.superview
            while let value = ancestor {
                if value is NSTableView { return false }
                ancestor = value.superview
            }
            return true
        })
        #expect(find(NSButton.self, in: headerRefs).contains { $0.attributedTitle.string.contains("dev-v0.11.0-3df9918") })
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-usability-overview.png"))
        }
    }

    @Test func foldedRefsKeepANamedTagAndScopePickerUsesFullIDs() async throws {
        let refs = [.init(name: "main", kind: GitRefDecorationKind.currentBranch)] +
            (0..<8).map { GitRefDecoration(name: "very-long-release-tag-\($0)-production", kind: .tag) }
        for width in [144.0, 176.0, 300.0] {
            let badges = GitRefBadgesView.badges(for: refs, width: width)
            #expect(badges.contains { $0.decoration.kind == .tag && !$0.isCount })
            #expect(Set(badges.flatMap(\.refs)) == Set(refs))
        }
        let twoTags = Array(refs.prefix(3))
        let compactTags = GitRefBadgesView.badges(for: twoTags, width: 360)
        #expect(compactTags.filter { $0.decoration.kind == .tag && !$0.isCount }.count == 1)
        #expect(compactTags.contains { $0.decoration.kind == .tag && $0.isCount })
        let name = String(repeating: "超长分支名称/", count: 30)
        #expect((GitHistoryScopePicker.compact(name) as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width <= 220)
        let branch = GitBranchInfo(name: name, commit: .init("a"), isCurrent: true, isRemote: false, upstream: "", tracking: "")
        var actions: [InspectorGitAction] = []
        let view = NSHostingView(rootView: GitHistoryScopePicker(title: name, branches: [branch], enabled: true) { actions.append($0) })
        view.sizingOptions = []
        let host = window(view, width: 220, height: 30)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(100))
        let control = try #require(find(GitHistoryScopePicker.Control.self, in: view).first)
        let menu = try #require(control.menu)
        let index = try #require(menu.items.firstIndex { $0.toolTip == name })
        menu.performActionForItem(at: index)
        #expect(actions == [.browseBranch(branch.id)])
        #expect(control.bounds.width <= 220)
    }
}
