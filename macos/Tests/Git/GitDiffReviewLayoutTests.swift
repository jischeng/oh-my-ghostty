import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

struct GitDiffReviewLayoutTests {
    @Test @MainActor func reviewAndComposerRenderWithLongSourceAndNarrowSidebar() async throws {
        let defaults = UserDefaults.standard
        let savedReview = defaults.object(forKey: "git.diff.review")
        let savedMode = defaults.object(forKey: "git.diff.viewMode")
        defaults.set(true, forKey: "git.diff.review")
        defaults.set(GitDiffViewMode.inline.rawValue, forKey: "git.diff.viewMode")
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

    @Test @MainActor func splitDiffViewModePersistsAcrossLanguageSwitchesAndMigratesLegacyValues() async throws {
        // 1. Verify legacy localized values ("Side by Side", "并排", "Inline", "内联") migrate to "split" / "inline".
        let suiteName = "omg.test.git.diff.prefs.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        isolatedDefaults.set("Side by Side", forKey: GitDiffPreferences.viewModeKey)
        let enPrefs = GitDiffPreferences(defaults: isolatedDefaults)
        #expect(enPrefs.viewMode == .split)
        #expect(isolatedDefaults.string(forKey: GitDiffPreferences.viewModeKey) == "split")

        isolatedDefaults.set("并排", forKey: GitDiffPreferences.viewModeKey)
        enPrefs.refreshFromDefaults()
        #expect(enPrefs.viewMode == .split)
        #expect(isolatedDefaults.string(forKey: GitDiffPreferences.viewModeKey) == "split")

        isolatedDefaults.set("内联", forKey: GitDiffPreferences.viewModeKey)
        enPrefs.refreshFromDefaults()
        #expect(enPrefs.viewMode == .inline)
        #expect(isolatedDefaults.string(forKey: GitDiffPreferences.viewModeKey) == "inline")

        // 2. Verify live GitEditorDiffView + toolbar switcher preserve split mode across en <-> zh-Hans switches.
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: GitDiffPreferences.viewModeKey)
        let savedReview = defaults.object(forKey: GitDiffPreferences.reviewKey)
        let savedLanguage = OhMyGhosttySettings.shared.language
        defer {
            GitL10n.configure(language: savedLanguage)
            OhMyGhosttySettings.shared.language = savedLanguage
            defaults.set(savedMode, forKey: GitDiffPreferences.viewModeKey)
            defaults.set(savedReview, forKey: GitDiffPreferences.reviewKey)
            GitDiffPreferences.shared.refreshFromDefaults()
        }

        GitL10n.configure(language: .english)
        OhMyGhosttySettings.shared.language = .english
        defaults.set("Side by Side", forKey: GitDiffPreferences.viewModeKey)
        GitDiffPreferences.shared.refreshFromDefaults()
        #expect(defaults.string(forKey: GitDiffPreferences.viewModeKey) == "split")

        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-lang-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        try Data("let x = 1\n".utf8).write(to: repoRoot.appendingPathComponent("Lang.swift"))
        for args in [["init", "--quiet"], ["add", "Lang.swift"]] {
            let res = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repoRoot.path)
            try #require(res.isSuccess)
        }
        try Data("let x = 2\n".utf8).write(to: repoRoot.appendingPathComponent("Lang.swift"))

        let repository = GitRepositoryIdentity(
            worktreePath: repoRoot.path,
            gitDirPath: repoRoot.path + "/.git",
            commonGitDirPath: repoRoot.path + "/.git"
        )
        let request = GitEditorDiffRequest(
            repository: repository,
            target: .unstaged,
            file: .init(path: "Lang.swift", status: "M")
        )
        let workbench = MonacoWorkbenchController()
        defer { workbench.tearDown() }

        let host = NSHostingView(
            rootView: GitEditorDiffView(
                request: request,
                theme: .oneDark,
                externalController: workbench,
                close: {}
            )
            .frame(width: 640, height: 320)
        )
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
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
        #expect(workbench.activeDiff?.inline == false)

        func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segmentedControls)
        }
        let modeControl = try #require(segmentedControls(in: host).first { $0.segmentCount == 2 && $0.image(forSegment: 0) != nil })
        #expect(modeControl.selectedSegment == 0)

        // Switch app language to Simplified Chinese and back to English: split mode must stay active!
        GitL10n.configure(language: .simplifiedChinese)
        OhMyGhosttySettings.shared.language = .simplifiedChinese
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(GitDiffPreferences.shared.viewMode == .split)
        #expect(defaults.string(forKey: GitDiffPreferences.viewModeKey) == "split")
        #expect(workbench.activeDiff?.inline == false)
        #expect(modeControl.selectedSegment == 0)

        GitL10n.configure(language: .english)
        OhMyGhosttySettings.shared.language = .english
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(GitDiffPreferences.shared.viewMode == .split)
        #expect(defaults.string(forKey: GitDiffPreferences.viewModeKey) == "split")
        #expect(workbench.activeDiff?.inline == false)
        #expect(modeControl.selectedSegment == 0)
    }
}
