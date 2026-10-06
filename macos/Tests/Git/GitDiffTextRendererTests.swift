import AppKit
import Testing
@testable import Ghostty

struct GitDiffTextRendererTests {
    @Test func numbersOnlyHunkLinesAndColorsPlusMinusContent() {
        let diff = """
        diff --git a/file.txt b/file.txt
        index 1234567..7654321 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,2 +1,3 @@
        -old
        +++literal-add
         context
        ---literal-delete
        """

        let rendered = GitDiffTextRenderer.render(diff).string
        let lines = rendered.components(separatedBy: "\n")
        #expect(lines.count == 9)
        #expect(prefix(of: lines[0]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[1]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[2]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[3]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[4]).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(prefix(of: lines[5]).contains("1"))
        #expect(prefix(of: lines[6]).contains("1"))
        #expect(prefix(of: lines[7]).contains("2"))
        #expect(prefix(of: lines[8]).contains("3"))
        #expect(lines[6].contains("+++literal-add"))
        #expect(lines[8].contains("---literal-delete"))
    }

    @MainActor
    @Test func fallbackPatchHasScrollableTextKitGeometry() throws {
        let patch = "@@ -2823,1 +2823,2000 @@\n-old\n" + String(repeating: "+new\n", count: 2_000)
        let scroll = GitDiffTextView.makeScrollView(text: patch)
        let textView = try #require(scroll.documentView as? NSTextView)
        let container = try #require(textView.textContainer)
        let layout = try #require(textView.layoutManager)
        #expect(!container.widthTracksTextView && !container.heightTracksTextView)
        #expect(textView.frame.width > 0 && textView.frame.height > 0)
        layout.ensureLayout(for: container)
        #expect(layout.usedRect(for: container).height > scroll.contentView.bounds.height)
        #expect(textView.frame.height > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: textView.frame.height - scroll.contentView.bounds.height))
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(textView.string.contains("2823"))
        #expect(textView.string.contains("4822"))
        #expect(layout.numberOfGlyphs == textView.string.utf16.count)
    }

    private func prefix(of line: String) -> String {
        String(line.split(separator: "│", maxSplits: 1).first ?? "")
    }
}
