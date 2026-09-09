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

    @Test func graphUsesLocalNodeWidthsAndMatchingBoundaryCoordinates() {
        var engine = GitGraphLayout()
        let rows = fixture().map { engine.append(commitID: $0.id, parentIDs: $0.parentIDs) }
        let columns = rows.indices.map {
            GitGraphColumnLayout(row: rows[$0], previous: rows[safe: $0 - 1], next: rows[safe: $0 + 1])
        }
        #expect(rows[0].nodeLane == 0 && rows[1].nodeLane == 0 && rows[5].nodeLane == 0)
        #expect(columns[0].width == columns[1].width && columns[1].width == columns[5].width)
        #expect(columns[2].width > columns[1].width)
        for index in 0..<(rows.count - 1) {
            #expect(rows[index].bottomLanes == rows[index + 1].topLanes)
            for lane in rows[index].bottomLanes.indices {
                #expect(columns[index].edgeX(lane: lane, count: rows[index].bottomLanes.count, top: false) ==
                        columns[index + 1].edgeX(lane: lane, count: rows[index + 1].topLanes.count, top: true))
            }
        }
        for (row, column) in zip(rows, columns) {
            for lane in 0..<row.requiredLaneCount {
                #expect(column.middleX(lane: lane, row: row) >= 7.5)
                #expect(column.middleX(lane: lane, row: row) <= column.width - 7.5)
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
            let nextMain = try cell(7)
            let branch = try cell(8)
            let subject = try #require(find(NSTextField.self, in: main))
            #expect(subject.frame.minX == find(NSTextField.self, in: nextMain)?.frame.minX)
            #expect(subject.frame.minX < (find(NSTextField.self, in: branch)?.frame.minX ?? 0))
            #expect(subject.bounds.width > width * 0.70)
            #expect(foldedHeight == table.rect(ofRow: 7).height)
            let meta = main.subviews.compactMap { $0 as? NSTextField }
            #expect(meta[1].stringValue == "renjiejiang02 · renjiejiang02@deeproute.ai")
            #expect(meta[2].stringValue.hasSuffix(" · main001"))
            for value in [nextMain, branch] {
                let group = try #require(find(GitRefBadgesView.self, in: value))
                let named = group.subviews.compactMap { $0 as? NSButton }
                #expect(named.count == 1 && named[0].frame.width <= 104)
                #expect(group.bounds.height == 17)
            }
            let badges = try #require(find(GitRefBadgesView.self, in: main))
            #expect(badges.bounds.height == 0)
            let references = try #require(find(GitRefListView.self, in: try cell(5)))
            #expect(first.refDecorations.allSatisfy { references.refs.contains($0) })
            #expect(table.rect(ofRow: 2).minY < table.rect(ofRow: 5).minY)
            let message = try cell(6)
            let control = try #require(find(NSButton.self, in: message))
            let controlFrame = control.frame
            let filePosition = table.rect(ofRow: 2)
            control.performClick(nil)
            let openControl = try #require(find(NSButton.self, in: try cell(6)))
            #expect(openControl.title == "Commit message · 18 lines")
            #expect(openControl.frame == controlFrame)
            #expect(table.rect(ofRow: 2) == filePosition)
            try await capture(host, path: "/tmp/omg-git-navigator-message-open-\(Int(width)).png")
            openControl.performClick(nil)
            try await capture(host, path: "/tmp/omg-git-navigator-\(Int(width)).png")

        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        if let value = view as? T { return value }
        return view?.subviews.compactMap { find(type, in: $0) }.first
    }
    private func capture(_ view: NSView, path: String) async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/omg-git-render") else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
