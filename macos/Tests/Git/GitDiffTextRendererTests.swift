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
        #expect(prefix(of: lines[4]).contains("1"))
        #expect(prefix(of: lines[5]).contains("2"))
        #expect(prefix(of: lines[6]).contains("2"))
        #expect(prefix(of: lines[7]).contains("3"))
        #expect(lines[5].contains("+++literal-add"))
        #expect(lines[7].contains("---literal-delete"))
    }

    private func prefix(of line: String) -> String {
        String(line.split(separator: "│", maxSplits: 1).first ?? "")
    }
}
