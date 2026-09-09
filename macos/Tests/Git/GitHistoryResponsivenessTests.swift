import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryResponsivenessTests {
    @Test func metadataDoubleClickCancelsCopyAndExpandsTheCommit() async throws {
        let button = InspectorClickCopyText(frame: NSRect(x: 0, y: 0, width: 150, height: 20))
        let board = NSPasteboard.withUniqueName()
        button.pasteboard = board
        button.configure(text: "Author", value: "Full Author", label: "Author")
        var expansions = 0
        button.onDoubleClick = { expansions += 1 }
        InspectorCopyMenu.copy("original", to: board)
        button.activate(clickCount: 1, deferSingle: true)
        button.activate(clickCount: 2)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        #expect(expansions == 1 && board.string(forType: .string) == "original")
        button.activate(clickCount: 1, deferSingle: true)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        #expect(board.string(forType: .string) == "Full Author")
        #expect(button.attributedTitle.string == "Author")
    }

    @Test func localExpansionPreservesUnrelatedCellsAndAvoidsWholeTableReloads() async throws {
        let commits = (0..<500).map { index in
            GitHistoryCommit(id: .init("commit-\(index)"), parentIDs: index == 499 ? [] : [.init("commit-\(index + 1)")],
                authorName: "Author", authorEmail: "a@example.com", authoredAt: Date(timeIntervalSince1970: 0), subject: "Commit \(index)")
        }
        let body = String(repeating: "An explanatory line for the performance regression.\n", count: 180)
        let detail = GitCommitExpansion(metadata: .init(commitID: commits[0].id, authorName: "Author", authorEmail: "a@example.com",
            authoredAt: "2026-09-09", parents: commits[0].parentIDs, message: "Subject\n\n" + body),
            files: [.init(path: "file.swift", status: "M")])
        var root = GitHistoryTable(commits: commits, selectedCommitID: nil, onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in })
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let value = view as? T { return value }
            return view.subviews.compactMap { find(type, in: $0) }.first
        }
        let table = try #require(find(NSTableView.self, in: view))
        let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
        let unrelated = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        var timings: [Double] = []
        for _ in 0..<20 {
            let start = Date()
            root.expandedCommits = [commits[0].id: detail]
            coordinator.update(root)
            #expect(table.view(atColumn: 0, row: 4, makeIfNecessary: true) === unrelated)
            root.expandedCommits = [:]
            coordinator.update(root)
            #expect(table.view(atColumn: 0, row: 1, makeIfNecessary: true) === unrelated)
            timings.append(Date().timeIntervalSince(start) * 1000)
        }
        root.expandedCommits = [commits[0].id: detail]
        coordinator.update(root)
        var bodyTimings: [Double] = []
        for _ in 0..<20 {
            let cell = try #require(table.view(atColumn: 0, row: 3, makeIfNecessary: true))
            cell.layoutSubtreeIfNeeded()
            let control = try #require(find(NSButton.self, in: cell))
            let start = Date()
            NSApp.sendAction(control.action!, to: control.target, from: control)
            bodyTimings.append(Date().timeIntervalSince(start) * 1000)
        }
        print("Git local UI benchmark (500 commits): expansion cycle median=\(timings.sorted()[10])ms; message toggle median=\(bodyTimings.sorted()[10])ms")
    }
}
