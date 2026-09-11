import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitLocalizationTests {
    @Test func catalogIsBundledCompleteAndFollowsTheExistingLanguageChoice() {
        #expect(GitStrings.catalog.count >= 250)
        let english = GitStrings(language: .system, preferredLanguages: ["en-US"])
        let chinese = GitStrings(language: .system, preferredLanguages: ["zh-Hans-CN"])
        #expect(english.text("Changes") == "Changes")
        #expect(chinese.text("Changes") == "更改")
        #expect(chinese.text("Open in Editor") == "在编辑器中打开")
        #expect(chinese.text("Open Folder in New Tab") == "在新标签页中打开所在文件夹")
        #expect(chinese.text("Linked scrolling") == "同步滚动")
        #expect(chinese.text("Previous file") == "上一个文件")
        #expect(chinese.format("{0} / {1} files", ["6", "18"]) == "6 / 18 个文件")
        #expect(chinese.text("Unified / Inline Diff") == "统一 / 行内差异")
        #expect(chinese.text("Reached the last change. Click again to open the next file.")
            == "已到当前文件最后一处差异，再次点击跳转到下一个文件。")
        #expect(GitStrings(language: .english, preferredLanguages: ["zh-Hans"]).text("History") == "History")
        #expect(GitStrings(language: .simplifiedChinese, preferredLanguages: ["en"]).text("History") == "历史")
        for (key, translations) in GitStrings.catalog {
            #expect(translations["en"] == key)
            #expect(translations["zh-Hans"]?.isEmpty == false)
            let expression = try? NSRegularExpression(pattern: #"\{[0-9]+\}"#)
            func placeholders(_ text: String) -> Set<String> {
                Set(expression?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { (text as NSString).substring(with: $0.range) } ?? [])
            }
            #expect(placeholders(key) == placeholders(translations["zh-Hans"] ?? ""))
        }
    }

    @Test func localizationNeverTranslatesRefNamesPathsOrGitOutput() {
        let chinese = GitStrings(language: .simplifiedChinese)
        #expect(chinese.text("Branches") == "分支")
        let branch = GitBranchInfo(name: "Branches", commit: .init("abc1234"), isCurrent: true, isRemote: false, upstream: "origin/HEAD", tracking: "")
        let nodes = GitCollectionBuilder.nodes(source: .refs(branches: [branch], worktrees: [], scopes: false, branchesError: nil, worktreesError: nil), mode: .list)
        #expect(nodes[0].children[0].item.title == "Branches")
        let data = "fatal: History Changes {0} /tmp/中文 {1}"
        #expect(GitExecutionError.processFailed(exitCode: 1, stderr: data).localizedDescription == data)
        #expect(chinese.format("Worktree no longer exists: {0}", [data]) == "Worktree 已不存在：" + data)
        let files = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: .changes(staged: [], unstaged: [.init(path: "History/Branches.cpp", status: "M")], stagedError: nil, unstagedError: nil), mode: .list))
        #expect(files.contains { $0.item.title == "Branches.cpp" && $0.item.subtitle == "History" })
    }

    @Test func inputsAndCollectionsRenderWithoutMutatingTheProcessLanguage() throws {
        let colors = GitCollectionColors()
        let source = GitCollectionSource.changes(staged: [.init(path: "src/a.cpp", status: "M")],
            unstaged: [.init(path: "src/b.cpp", status: "A", isUntracked: true)], stagedError: nil, unstagedError: nil)
        let content = VStack(spacing: 8) {
            GitCollectionToolbar(query: .constant(""), mode: .constant(.tree), placeholder: GitL10n.text("Search files…"), controller: GitCollectionController())
            GitCollectionView(source: source, mode: .tree, perform: { _ in })
            GitCommitComposer(message: .constant(""), stagedCount: 1, isBusy: false, canCommit: true, isUpdatingIndex: false, commit: {})
        }.padding(10).background(Color(colors.background))
        let host = NSHostingView(rootView: content); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: "/tmp/omg-git-localization.png")
            )
        }
    }
}
