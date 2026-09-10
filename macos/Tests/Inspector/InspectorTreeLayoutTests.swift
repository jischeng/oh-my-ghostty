import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct InspectorTreeLayoutTests {
    @Test func gitCompactionRetainsRealPathsBatchesAndOneLevelIndent() throws {
        let files = ["tasks/session-79586-79586/deep/a.swift", "tasks/session-79586-79586/deep/b.swift", "tasks/other.txt"]
            .map { GitDiffFile(path: $0, status: "M") }
        let source = GitCollectionSource.changes(staged: [], unstaged: files, stagedError: nil, unstagedError: nil)
        let nodes = GitCollectionBuilder.nodes(source: source, mode: .tree)
        let rows = GitCollectionBuilder.rows(nodes)
        let folder = try #require(rows.first { $0.item.title == "session-79586-79586/deep" })
        #expect(folder.item.fullPath == "tasks/session-79586-79586/deep")
        #expect(folder.item.stageBatch?.files.map(\.path) == Array(files.prefix(2)).map(\.path))
        let child = try #require(rows.first { $0.item.title == "a.swift" })
        #expect(child.depth == folder.depth + 1)
        #expect(child.id == GitChangeSection.unstaged.rowID(path: files[0].path))
        let collapsed = GitCollectionBuilder.rows(nodes, collapsed: [folder.id])
        #expect(!collapsed.contains { $0.id == child.id })
        #expect(collapsed.contains { $0.item.title == "other.txt" })
        let branches = ["feature/team/deep/one", "feature/team/deep/two"].map {
            GitBranchInfo(name: $0, commit: .init("abc1234"), isCurrent: false, isRemote: false, upstream: "", tracking: "")
        }
        let refs = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: .refs(branches: branches, worktrees: [], scopes: false, branchesError: nil, worktreesError: nil), mode: .tree))
        #expect(refs.contains { $0.item.title == "feature/team/deep" })
        #expect(refs.contains { $0.id == "refs/heads/feature/team/deep/one" })
        let list = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: source, mode: .list))
        #expect(!list.contains { $0.item.isFolder })
    }

    @Test func localAndRemoteTreeListingShareCompactRulesAndPreserveSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-tree-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["tasks/session/deep", "with-file/child", "split/a", "split/b", "link-parent"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("a".utf8).write(to: root.appendingPathComponent("tasks/session/deep/a.swift"))
        try Data("a".utf8).write(to: root.appendingPathComponent("with-file/readme"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-parent/link"), withDestinationURL: root.appendingPathComponent("tasks"))
        let local = LocalWorkspaceFilesystem(workingDirectory: root.path)
        let ordinary = try await local.listDirectory(at: root.path)
        let compact = try await local.listTreeDirectory(at: root.path)
        #expect(ordinary.contains { $0.name == "tasks" })
        let compactTask = try #require(compact.first { $0.name == "tasks/session/deep" })
        func inode(_ path: String) throws -> NSNumber? {
            try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        }
        #expect(try inode(compactTask.path) == inode(root.appendingPathComponent("tasks/session/deep").path))
        for name in ["with-file", "split", "link-parent"] { #expect(compact.contains { $0.name == name }) }
        let result = try await GitProcessRunner().run(executablePath: "/usr/bin/env",
            arguments: ["python3", "-c", SSHWorkspaceFilesystem.compactTreeScript, root.path], workingDirectory: root.path)
        try #require(result.isSuccess)
        let marker = try #require(result.stdoutString.range(of: "OMG-TREE-v1\n"))
        let remote = try JSONDecoder().decode([WorkspaceFileEntry].self, from: Data(result.stdoutString[marker.upperBound...].utf8))
        #expect(remote.map(\.name).sorted() == compact.map(\.name).sorted())
        for entry in remote {
            let localEntry = try #require(compact.first { $0.name == entry.name })
            #expect(entry.isDirectory == localEntry.isDirectory)
            // macOS directory APIs may spell /var as /private/var. Verify
            // actual filesystem identity rather than treating aliases as paths
            // to different nodes.
            #expect(try inode(entry.path) == inode(localEntry.path))
        }
    }

    @Test func compactTreesRenderWithTheSameDepthAcrossFilesAndGit() async throws {
        let leaf = InspectorFileNode(id: "/repo/tasks/session/deep/a.swift", name: "a.swift", isDirectory: false,
            icon: .init(systemImage: "swift", tint: .orange), isExpanded: false, isLoading: false, children: nil)
        let folder = InspectorFileNode(id: "/repo/tasks/session/deep", name: "tasks/session/deep", isDirectory: true,
            icon: .init(systemImage: "folder", tint: .blue), isExpanded: true, isLoading: false, children: [leaf])
        let source = GitCollectionSource.changes(staged: [], unstaged: [.init(path: "tasks/session/deep/a.swift", status: "M")], stagedError: nil, unstagedError: nil)
        let host = NSHostingView(rootView: VStack(spacing: 12) {
            GitHistoryScopePicker(title: "feature/team/deep/compact-folders", branches: [], enabled: true,
                selectedID: "refs/heads/feature/team/deep/compact-folders", perform: { _ in }).frame(width: 300, height: 28)
            HStack(spacing: 16) {
            InspectorFileTreeView(tree: .init(rootName: "Files", rootPath: "/repo", nodes: [folder]), perform: { _ in }).frame(width: 300)
            GitCollectionView(source: source, mode: .tree, perform: { _ in }).frame(width: 300)
            }
        }.padding(10).background(Color(NSColor.windowBackgroundColor)))
        host.sizingOptions = []
        let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false; win.contentView = host; win.makeKeyAndOrderFront(nil)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/omg-compact-trees.png"))
        }
    }

    @Test func selectorContentAndTreeCheckboxesHavePredictableInsets() throws {
        let cell = GitScopeButtonCell()
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 28)
        #expect(cell.imageRect(forBounds: bounds).minX == 10)
        #expect(cell.titleRect(forBounds: bounds).minX >= cell.imageRect(forBounds: bounds).maxX + 6)
        #expect(cell.titleRect(forBounds: bounds).maxX <= bounds.maxX - 28)
        let file = GitDiffFile(path: "folder/file", status: "M")
        let batch = GitStageBatch(entries: [.init(file: file, section: .unstaged)])
        let folder = GitCollectionCell(frame: .init(x: 0, y: 0, width: 320, height: 26))
        let child = GitCollectionCell(frame: folder.frame)
        folder.configure(.init(item: .init(id: "folder", title: "folder", kind: .folder(1), stageBatch: batch), depth: 0, isTree: true), colors: .init(), toggle: {}, stage: {})
        child.configure(.init(item: .init(id: "file", title: "file", kind: .file(file, .unstaged), stageBatch: batch), depth: 1, isTree: true), colors: .init(), toggle: {}, stage: {})
        folder.layoutSubtreeIfNeeded(); child.layoutSubtreeIfNeeded()
        #expect(child.checkbox.frame.minX - folder.checkbox.frame.minX == InspectorTreeLayout.indent)
    }
}
