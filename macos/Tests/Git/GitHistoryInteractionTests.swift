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
        let host = NSHostingView(rootView: root.background(Color(NSColor.windowBackgroundColor)))
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

    @Test func decorationsPutMainAndBranchesBeforeTagsAndAggregate() {
        let refs: [GitRefDecoration] = [
            .init(name: "v1", kind: .tag), .init(name: "feature", kind: .currentBranch),
            .init(name: "origin/main", kind: .remoteBranch), .init(name: "main", kind: .localBranch),
            .init(name: "develop", kind: .localBranch),
        ]
        #expect(GitRefDecoration.orderedForDisplay(refs).map(\.name) == ["main", "origin/main", "feature", "develop", "v1"])
        let narrow = GitRefBadgesView.height(for: refs, width: 130)
        let wide = GitRefBadgesView.height(for: refs, width: 600)
        #expect(narrow == wide)
        let badges = GitRefBadgesView.badges(for: refs, width: 130)
        #expect(badges.contains { $0.isCount })
        #expect(Set(badges.flatMap(\.refs)) == Set(refs))
        #expect(badges.flatMap(\.refs).count == refs.count)
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
        #expect(table.numberOfRows == 5)
        #expect(table.effectiveStyle == .plain)
        let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
        coordinator.activateRow(0, doubleClick: false)
        #expect(opened.isEmpty && toggled.isEmpty)
        coordinator.activateRow(0, doubleClick: true)
        #expect(toggled == [first.id] && opened.isEmpty)
        toggled.removeAll()
        let summaryCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let disclosure = try #require(summaryCell.subviews.compactMap { $0 as? NSButton }.first)
        disclosure.performClick(nil)
        #expect(toggled == [first.id])
        coordinator.activateRow(2, doubleClick: false)
        #expect(opened == [file])
        let firstCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let headCell = table.view(atColumn: 0, row: 4, makeIfNecessary: true)
        let firstGraph = try #require(find(GitGraphCellView.self, in: firstCell))
        let headGraph = try #require(find(GitGraphCellView.self, in: headCell))
        #expect(!firstGraph.isHead && headGraph.isHead)
        #expect(firstGraph.frame.width > 0 && firstGraph.frame.width <= 31)
        let metadata = table.view(atColumn: 0, row: 3, makeIfNecessary: true)
        let detailLabel = try #require(find(NSTextField.self, in: metadata))
        #expect(detailLabel.stringValue.contains("Commit body"))
        let requiredHeight = try #require(detailLabel.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: detailLabel.bounds.width, height: .greatestFiniteMagnitude)).height)
        #expect(detailLabel.bounds.height >= requiredHeight)
        let shortBodyHeader = try #require(find(NSButton.self, in: metadata))
        #expect(shortBodyHeader.title == GitL10n.format("Commit message · {0} line", "1"))
        let headerY = shortBodyHeader.frame.minY
        shortBodyHeader.performClick(nil)
        let closedBody = try #require(table.view(atColumn: 0, row: 3, makeIfNecessary: true))
        closedBody.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 3).height == 28)
        #expect(find(NSButton.self, in: closedBody)?.frame.minY == headerY)
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render"), let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-expanded.png"))
        }
    }

    @Test func longBodyFoldsAfterFilesWithoutMovingTheSummaryOrRepeatingMetadata() async throws {
        for width in [220.0, 360.0] {
            let first = commit("1234567", refs: [.init(name: "main", kind: .currentBranch), .init(name: "v1.2", kind: .tag)])
            let files = (0..<6).map { GitDiffFile(path: "Sources/File\($0).swift", status: $0 == 1 ? "A" : "M") }
            let details = GitCommitExpansion(metadata: .init(commitID: first.id, authorName: "Author",
                authorEmail: "a@example.com", authoredAt: "2026-09-09", parents: [],
                message: "Commit 1234567\n\n" + (0..<100).map { "Explanation line \($0)" }.joined(separator: "\n")),
                files: files, statistics: .init(additions: 642, deletions: 87, binaryFiles: 0))
            var root = GitHistoryTable(commits: [first, commit("next001"), commit("next002")], selectedCommitID: nil,
                headCommitID: first.id, onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in })
            let window = hostWindow(root, width: width, height: 680)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(120))
            let table = try #require(find(NSTableView.self, in: window.contentView))
            let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
            let originalHeight = table.rect(ofRow: 0).height
            func summary() throws -> [String] {
                let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                return cell.subviews.compactMap { $0 as? NSTextField }.map { $0.stringValue + NSStringFromRect($0.frame) }
            }
            let originalSummary = try summary()
            root.expandedCommits = [first.id: details]
            coordinator.update(root)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(table.numberOfRows == 11)
            #expect(table.rect(ofRow: 0).height == originalHeight)
            #expect(try summary() == originalSummary)
            let header = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
            header.layoutSubtreeIfNeeded()
            #expect(find(NSButton.self, in: header)?.attributedTitle.string ==
                GitL10n.format("{0} files changed", "6") + " · +642 −87")
            let filesTop = table.rect(ofRow: 2).minY
            let message = try #require(table.view(atColumn: 0, row: 8, makeIfNecessary: true))
            message.layoutSubtreeIfNeeded()
            #expect(table.rect(ofRow: 8).height == 28)
            let toggle = try #require(find(NSButton.self, in: message))
            #expect(toggle.title == GitL10n.format("Commit message · {0} lines", "100"))
            let toggleFrame = toggle.frame
            toggle.performClick(nil)
            #expect(table.rect(ofRow: 8).height > 500)
            #expect(table.rect(ofRow: 2).minY == filesTop)
            let expanded = try #require(table.view(atColumn: 0, row: 8, makeIfNecessary: true))
            expanded.layoutSubtreeIfNeeded()
            #expect(find(NSTextField.self, in: expanded)?.stringValue.contains("Explanation line 99") == true)
            let less = try #require(find(NSButton.self, in: expanded))
            #expect(less.title == GitL10n.format("Commit message · {0} lines", "100"))
            #expect(less.frame == toggleFrame)
            less.performClick(nil)
            #expect(table.rect(ofRow: 8).height == 28)
            #expect(NSLocationInRange(9, table.rows(in: table.visibleRect)))
            #expect(table.rect(ofRow: 2).minY == filesTop)
            if FileManager.default.fileExists(atPath: "/tmp/omg-git-render"), let view = window.contentView {
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-timeline-\(Int(width)).png"))
            }
            coordinator.activateRow(1, doubleClick: false)
            #expect(table.numberOfRows == 5)
            coordinator.activateRow(1, doubleClick: false)
            #expect(table.numberOfRows == 11)
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
        #expect(table.numberOfRows == 101)
        #expect(table.rect(ofRow: 100).minY > table.visibleRect.maxY)
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
        root.automaticLoadingAllowed = true
        root = GitHistoryTable(commits: (0..<200).map { commit(String($0)) }, selectedCommitID: nil,
            hasMore: true, onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in }, onLoadMore: { requested += 1 })
        coordinator.update(root)
        coordinator.requestMoreIfNeeded()
        #expect(table.numberOfRows == 201)
        #expect(table.rect(ofRow: 200).minY > table.visibleRect.maxY)
        #expect(requested == 1, "Appending a page must move pagination below the new rows")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.bounds.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.requestMoreIfNeeded()
        #expect(requested == 2)
        root.hasMore = false
        coordinator.update(root)
        #expect(table.numberOfRows == 200)
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
