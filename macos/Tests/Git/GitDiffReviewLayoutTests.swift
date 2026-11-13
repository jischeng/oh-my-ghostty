import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

struct GitDiffReviewLayoutTests {
    @Test func foldsContextAndExpandsWithoutChangingSourceCoordinates() {
        let rows = (0..<30).map { index in
            GitDiffPresentation.Row(text: "line \(index)", beforeLine: index + 1,
                                    afterLine: index + 1, added: index == 15 ? true : nil)
        }
        let layout = GitDiffReviewLayout(rows: rows, expanded: [])
        #expect(layout.items.first == .folded(0..<12))
        #expect(layout.items.last == .folded(19..<30))
        #expect(layout.items.contains(.row(15)))
        let expanded = GitDiffReviewLayout(rows: rows, expanded: [0])
        #expect(expanded.items.first == .row(0))
        #expect(expanded.items.contains(.row(11)))
        #expect(expanded.items.last == .folded(19..<30))
        #expect(rows[15].afterLine == 16)
    }

    @Test @MainActor func reviewAndComposerRenderWithLongSourceAndNarrowSidebar() async throws {
        let defaults = UserDefaults.standard
        let savedReview = defaults.object(forKey: "git.diff.review")
        let savedMode = defaults.object(forKey: "git.diff.viewMode")
        defaults.set(true, forKey: "git.diff.review")
        defaults.set(GitL10n.text("Inline"), forKey: "git.diff.viewMode")
        defer {
            defaults.set(savedReview, forKey: "git.diff.review")
            defaults.set(savedMode, forKey: "git.diff.viewMode")
        }

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-review-composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let before = (1...80).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "let value40 = 40", with: "let value40 = 400")
        let fileURL = repoRoot.appendingPathComponent("Example.swift")
        try Data(before.utf8).write(to: fileURL)
        for args in [["init", "--quiet"], ["add", "Example.swift"]] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repoRoot.path)
            try #require(res.isSuccess)
        }
        try Data(after.utf8).write(to: fileURL)

        let repository = GitRepositoryIdentity(
            worktreePath: repoRoot.path,
            gitDirPath: repoRoot.path + "/.git",
            commonGitDirPath: repoRoot.path + "/.git"
        )
        let request = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Example.swift", status: "M")
        )
        let workbench = MonacoWorkbenchController()
        defer { workbench.tearDown() }

        let root = HStack(spacing: 0) {
            GitEditorDiffView(
                request: request,
                theme: .oneDark,
                externalController: workbench,
                close: {}
            )
            Divider()
            VStack {
                GitCommitComposer(message: .constant("Refine Git review"), stagedCount: 2, isBusy: false,
                                  canCommit: true, isUpdatingIndex: false, commit: {},
                                  unstagedCount: 3, hasHead: true)
                Spacer()
            }.padding(10).frame(width: 260)
        }
        .frame(width: 1000, height: 360)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.09, alpha: 1)))
        .preferredColorScheme(.dark)

        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        for _ in 0..<120 {
            if workbench.activeDiff != nil, workbench.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        host.layoutSubtreeIfNeeded()
        #expect(workbench.activeDiff?.path == "Example.swift")
        #expect(workbench.activeDiff?.review == true)
        #expect(workbench.activeDiff?.inline == true)
        let webView = try #require(workbench.webView)
        #expect(!webView.isOpaque)
        #expect((webView.underPageBackgroundColor?.alphaComponent ?? 1) == 0)
        #expect(host.fittingSize.width >= 1000)
    }

    @Test @MainActor func longLinesStayInsideNarrowSplitViewport() async throws {
        let defaults = UserDefaults.standard
        let savedWrap = defaults.object(forKey: "git.diff.wordWrap")
        let savedMode = defaults.object(forKey: "git.diff.viewMode")
        let savedReview = defaults.object(forKey: "git.diff.review")
        defaults.set(GitL10n.text("Side by Side"), forKey: "git.diff.viewMode")
        defaults.set(true, forKey: "git.diff.review")
        defer {
            defaults.set(savedWrap, forKey: "git.diff.wordWrap")
            defaults.set(savedMode, forKey: "git.diff.viewMode")
            defaults.set(savedReview, forKey: "git.diff.review")
        }

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-narrow-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let source = String(repeating: "long_identifier + ", count: 40) + "\n"
        try Data(source.utf8).write(to: repoRoot.appendingPathComponent("Long.swift"))
        let initRes = try await LocalGitExecutor().execute(
            arguments: ["init", "--quiet"],
            workingDirectory: repoRoot.path
        )
        try #require(initRes.isSuccess)

        let repository = GitRepositoryIdentity(
            worktreePath: repoRoot.path,
            gitDirPath: repoRoot.path + "/.git",
            commonGitDirPath: repoRoot.path + "/.git"
        )
        let request = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Long.swift", status: "A", isUntracked: true)
        )

        for wrap in [true, false] {
            defaults.set(wrap, forKey: "git.diff.wordWrap")
            let workbench = MonacoWorkbenchController()
            defer { workbench.tearDown() }
            let host = NSHostingView(
                rootView: GitEditorDiffView(
                    request: request,
                    theme: .oneDark,
                    externalController: workbench,
                    close: {}
                )
                .frame(width: 300, height: 260)
            )
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }

            for _ in 0..<120 {
                if workbench.activeDiff != nil, workbench.isReady { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == 300)
            #expect(workbench.activeDiff?.inline == false)
            #expect(workbench.activeDiff?.wordWrap == wrap)
            let webView = try #require(workbench.webView)
            #expect(webView.bounds.width <= 300.5)
        }
    }

    @Test func emptyAndEntirelyChangedFilesHaveNoSpuriousFold() {
        #expect(GitDiffReviewLayout(rows: [], expanded: []).items.isEmpty)
        let row = GitDiffPresentation.Row(text: "new", beforeLine: nil, afterLine: 1, added: true)
        #expect(GitDiffReviewLayout(rows: [row], expanded: []).items == [.row(0)])
    }
}
