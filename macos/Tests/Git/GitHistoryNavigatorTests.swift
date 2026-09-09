import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryNavigatorTests {
    private func fixture() -> [GitHistoryCommit] {
        let refs: [GitRefDecoration] = [.init(name: "main", kind: .currentBranch)] +
            (0..<7).map { .init(name: "origin/fix/lake-search-api-with-a-very-long-name-\($0)", kind: .remoteBranch) } +
            (0..<8).map { .init(name: "1.1.147_lake-search-api_prod-long-release-tag-\($0)", kind: .tag) }
        return [("main001", ["main002", "side001", "side002", "side003"]),
                ("main002", ["base001"]), ("side003", ["base001"]),
                ("side002", ["base001"]), ("side001", ["base001"]),
                ("base001", ["root001"]), ("root001", [])].enumerated().map { index, value in
            GitHistoryCommit(id: .init(value.0), parentIDs: value.1.map(GitCommitID.init),
                authorName: "renjiejiang02", authorEmail: "renjiejiang02@deeproute.ai",
                authoredAt: Date(timeIntervalSince1970: 1_788_700_620),
                subject: index < 2 ? "fix(lake-search): pin available rapidjson \(index)" : "Merge work on \(value.0)",
                refDecorations: index == 0 ? refs : (index == 1 ? [refs[1]] : (index == 2 ? [refs[refs.count - 1]] : [])))
        }
    }

    @Test func graphProjectionKeepsNodeExtentsInsideAFixedSurface() {
        var engine = GitGraphLayout()
        let rows = fixture().map { engine.append(commitID: $0.id, parentIDs: $0.parentIDs) }
        let columns = rows.map { _ in GitGraphColumnLayout() }
        #expect(rows[0].nodeLane == 0 && rows[1].nodeLane == 0 && rows[5].nodeLane == 0)
        #expect(columns[0].width == columns[1].width && columns[1].width == columns[5].width)
        #expect(columns.allSatisfy { $0.width == 18 })
        for index in 0..<(rows.count - 1) {
            #expect(rows[index].bottomLanes == rows[index + 1].topLanes)
            for lane in rows[index].bottomLanes.indices {
                #expect(columns[index].edgeX(lane: lane, count: rows[index].bottomLanes.count) ==
                        columns[index + 1].edgeX(lane: lane, count: rows[index + 1].topLanes.count))
            }
        }
        for (row, column) in zip(rows, columns) {
            for lane in 0..<row.requiredLaneCount {
                #expect(column.middleX(lane: lane, row: row) >= 4)
                #expect(column.middleX(lane: lane, row: row) <= column.width - 4)
            }
        }
    }

    @Test func commonAndDenseLaneCountsNeverReserveMoreTextSpace() {
        for count in [1, 2, 3, 8, 32] {
            let ids = (0..<count).map { GitCommitID("lane-\($0)") }
            var layout = GitGraphLayout(activeLanes: ids)
            let row = layout.append(commitID: ids[count - 1], parentIDs: [])
            let column = GitGraphColumnLayout()
            #expect(column.width == 18)
            for lane in 0..<row.requiredLaneCount {
                let x = column.middleX(lane: lane, row: row)
                #expect(x - 4 >= 0 && x + 4 <= column.width)
            }
            if count == 2 {
                #expect(column.middleX(lane: 1, row: row) - column.middleX(lane: 0, row: row) == 8)
            }
        }
    }

    @Test func extremeNavigatorContentKeepsWidthsHeightsAndTopDisclosureStable() async throws {
        for width in [220.0, 360.0] {
            let commits = fixture()
            let first = commits[0]
            let body = (1...18).map { "Line \($0): explain the available rapidjson dependency and compatibility." }.joined(separator: "\n")
            let detail = GitCommitExpansion(metadata: .init(commitID: first.id, authorName: first.authorName,
                authorEmail: first.authorEmail, authoredAt: "2026-09-06", parents: first.parentIDs,
                message: first.subject + "\n\n" + body),
                files: [.init(path: "foo.swift", status: "M"), .init(path: "bar.swift", status: "A"),
                        .init(path: "new.swift", oldPath: "old.swift", status: "R100")],
                statistics: .init(additions: 642, deletions: 87, binaryFiles: 0))
            var root = GitHistoryTable(commits: commits, selectedCommitID: nil, headCommitID: first.id,
                expandedCommits: [:], onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in })
            let host = NSHostingView(rootView: root.background(Color(NSColor.windowBackgroundColor)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 730),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(180))
            host.layoutSubtreeIfNeeded()
            let table = try #require(find(NSTableView.self, in: host))
            func cell(_ row: Int) throws -> NSView {
                let value = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                value.layoutSubtreeIfNeeded()
                return value
            }
            let foldedMain = try cell(0)
            let foldedHeight = table.rect(ofRow: 0).height
            let foldedBadges = try #require(find(GitRefBadgesView.self, in: foldedMain))
            let badge = try #require(foldedBadges.subviews.compactMap { $0 as? NSButton }.last)
            badge.performClick(nil)
            let popover = try #require(foldedBadges.popover)
            #expect(popover.isShown)
            let fullList = try #require(find(GitRefListView.self, in: popover.contentViewController?.view))
            #expect(first.refDecorations.allSatisfy { fullList.refs.contains($0) })
            try await capture(popover.contentViewController!.view, path: "/tmp/omg-git-refs-popover-\(Int(width)).png")
            popover.close()
            root.expandedCommits = [first.id: detail]
            let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
            coordinator.update(root)
            let main = try cell(0)
            let nextMain = try cell(6)
            let branch = try cell(7)
            let subject = try #require(find(NSTextField.self, in: main))
            #expect(subject.frame.minX == find(NSTextField.self, in: nextMain)?.frame.minX)
            #expect(subject.frame.minX == find(NSTextField.self, in: branch)?.frame.minX)
            #expect(subject.bounds.width > width * 0.70)
            #expect(foldedHeight == table.rect(ofRow: 6).height)
            func metadataButtons(_ view: NSView) -> [InspectorClickCopyText] {
                if let button = view as? InspectorClickCopyText { return [button] }
                return view.subviews.flatMap(metadataButtons)
            }
            let meta = metadataButtons(main)
            #expect(meta.contains { $0.value == "renjiejiang02@deeproute.ai" })
            #expect(meta.contains { $0.value == "main001" })
            for value in [nextMain, branch] {
                let group = try #require(find(GitRefBadgesView.self, in: value))
                let named = group.subviews.compactMap { $0 as? NSButton }
                #expect(named.count == 1 && named[0].frame.width <= 104)
                #expect(group.bounds.height == 17)
            }
            let badges = try #require(find(GitRefBadgesView.self, in: main))
            #expect(badges.bounds.height == 17)
            #expect(find(GitRefListView.self, in: main) == nil)
            let message = try cell(5)
            let control = try #require(find(NSButton.self, in: message))
            let controlFrame = control.frame
            let filePosition = table.rect(ofRow: 2)
            control.performClick(nil)
            let openControl = try #require(find(NSButton.self, in: try cell(5)))
            #expect(openControl.title == "Commit message · 18 lines")
            #expect(openControl.frame == controlFrame)
            #expect(table.rect(ofRow: 2) == filePosition)
            try await capture(host, path: "/tmp/omg-git-navigator-message-open-\(Int(width)).png")
            openControl.performClick(nil)
            try await capture(host, path: "/tmp/omg-git-navigator-\(Int(width)).png")

        }
    }

    @Test func mainlineAndBranchTextUseTheSameLeadingBaseline() async throws {
        let input: [(String, [String], String)] = [
            ("tip", ["main", "side", "probe"], "feat: mainline start"),
            ("probe", ["base"], "feat: side branch work"),
            ("main", ["base"], "feat: mainline continues"),
            ("base", ["root"], "feat: shared mainline ancestor"),
            ("side", ["root"], "feat: another branch"),
            ("root", [], "feat: mainline root"),
        ]
        let commits = input.map { value in GitHistoryCommit(id: .init(value.0), parentIDs: value.1.map(GitCommitID.init),
            authorName: "Author", authorEmail: "author@example.com", authoredAt: Date(timeIntervalSince1970: 0), subject: value.2) }
        for width in [220.0, 360.0] {
            let view = NSHostingView(rootView: GitHistoryTable(commits: commits, selectedCommitID: nil,
                onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in }).background(Color(NSColor.windowBackgroundColor)))
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(120))
            let table = try #require(find(NSTableView.self, in: view))
            func x(_ row: Int) throws -> CGFloat {
                let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                return try #require(cell.subviews.compactMap { $0 as? NSTextField }.first).frame.minX
            }
            let baseline = try x(0)
            #expect(baseline == 22)
            for row in [2, 3, 5] { #expect(try x(row) == baseline) }
            for row in [1, 4] { #expect(try x(row) == baseline) }
            try await capture(view, path: "/tmp/omg-git-mainline-\(Int(width)).png")
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        if let value = view as? T { return value }
        return view?.subviews.compactMap { find(type, in: $0) }.first
    }
    private func capture(_ view: NSView, path: String) async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/omg-git-render") else { return }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
