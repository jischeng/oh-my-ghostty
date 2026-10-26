import AppKit
import SwiftUI
import CodeEditSourceEditor
import Testing
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
        let before = (1...80).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "let value40 = 40", with: "let value40 = 400")
        let presentation = GitDiffPresentation(before: before, after: after,
            patch: "@@ -40 +40 @@\n-let value40 = 40\n+let value40 = 400\n")
        let root = HStack(spacing: 0) {
            GitDiffReviewView(presentation: presentation, before: before, after: after,
                              path: "Example.swift", theme: .oneDark, split: false)
            Divider()
            VStack {
                GitCommitComposer(message: .constant("Refine Git review"), stagedCount: 2, isBusy: false,
                                  canCommit: true, isUpdatingIndex: false, commit: {},
                                  unstagedCount: 3, hasHead: true)
                Spacer()
            }.padding(10).frame(width: 260)
        }.frame(width: 1000, height: 360)
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
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/omg-git-review-preview.png"))
        #expect(host.fittingSize.width >= 1000)
    }

    @Test @MainActor func longLinesStayInsideNarrowSplitViewport() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "git.diff.wordWrap")
        defer { defaults.set(saved, forKey: "git.diff.wordWrap") }
        let source = String(repeating: "long_identifier + ", count: 40)
        let presentation = GitDiffPresentation(before: "", after: source + "\n", patch: "@@ -0,0 +1 @@\n+" + source + "\n")
        for wrap in [true, false] {
            defaults.set(wrap, forKey: "git.diff.wordWrap")
            let host = NSHostingView(rootView: GitDiffReviewView(presentation: presentation, before: "", after: source + "\n",
                path: "Long.swift", theme: .oneDark, split: true).frame(width: 300, height: 260))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == 300)
            func scrolls(_ view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap(scrolls)
            }
            let scroll = try #require(scrolls(host).first)
            let document = try #require(scroll.documentView)
            if wrap {
                #expect(document.bounds.width <= 301)
                #expect(document.bounds.height > 260)
            } else {
                #expect(document.bounds.width > 1000)
            }
        }
    }

    @Test func emptyAndEntirelyChangedFilesHaveNoSpuriousFold() {
        #expect(GitDiffReviewLayout(rows: [], expanded: []).items.isEmpty)
        let row = GitDiffPresentation.Row(text: "new", beforeLine: nil, afterLine: 1, added: true)
        #expect(GitDiffReviewLayout(rows: [row], expanded: []).items == [.row(0)])
    }
}
