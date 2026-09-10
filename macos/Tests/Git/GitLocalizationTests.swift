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
        let previous = GitL10n.current.languageCode
        GitL10n.configure(language: .simplifiedChinese)
        defer { GitL10n.configure(language: .system, preferredLanguages: [previous]) }
        let branch = GitBranchInfo(name: "Branches", commit: .init("abc1234"), isCurrent: true, isRemote: false, upstream: "origin/HEAD", tracking: "")
        let nodes = GitCollectionBuilder.nodes(source: .refs(branches: [branch], worktrees: [], scopes: false, branchesError: nil, worktreesError: nil), mode: .list)
        #expect(nodes[0].item.title == "分支")
        #expect(nodes[0].children[0].item.title == "Branches")
        let data = "fatal: History Changes {0} /tmp/中文 {1}"
        #expect(GitExecutionError.processFailed(exitCode: 1, stderr: data).localizedDescription == data)
        #expect(GitL10n.format("Worktree no longer exists: {0}", data) == "Worktree 已不存在：" + data)
        let files = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: .changes(staged: [], unstaged: [.init(path: "History/Branches.cpp", status: "M")], stagedError: nil, unstagedError: nil), mode: .list))
        #expect(files.contains { $0.item.title == "Branches.cpp" && $0.item.subtitle == "History" })
    }

    @Test func inputsAndCollectionsRenderInBothLanguages() throws {
        let previous = GitL10n.current.languageCode
        defer { GitL10n.configure(language: .system, preferredLanguages: [previous]) }
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            GitL10n.configure(language: language)
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
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/omg-git-localization-\(language.rawValue).png"))
            }
        }
    }
}
