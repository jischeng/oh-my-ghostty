import Foundation
import Testing
@testable import Ghostty

struct AITitleSanitizerTests {
    @Test func keepsAPlainTitleAsIs() {
        #expect(AITitleSanitizer.sanitize("Fix the flaky inbox test") == "Fix the flaky inbox test")
        #expect(AITitleSanitizer.sanitize("Node.js build") == "Node.js build")
    }

    @Test func takesTheFirstNonEmptyLine() {
        #expect(AITitleSanitizer.sanitize("   \n\nInbox polish\nSecond line") == "Inbox polish")
        #expect(AITitleSanitizer.sanitize("\n\t\r\n") == nil)
        #expect(AITitleSanitizer.sanitize("") == nil)
    }

    @Test func stripsTitlePrefixes() {
        #expect(AITitleSanitizer.sanitize("Title: Plan the release") == "Plan the release")
        #expect(AITitleSanitizer.sanitize("title:  Plan the release") == "Plan the release")
        #expect(AITitleSanitizer.sanitize("标题：发布计划") == "发布计划")
        #expect(AITitleSanitizer.sanitize("**Title:** Release plan") == "Release plan")
    }

    @Test func stripsQuotesBackticksAndMarkdown() {
        #expect(AITitleSanitizer.sanitize("\"Release plan\"") == "Release plan")
        #expect(AITitleSanitizer.sanitize("`Release plan`") == "Release plan")
        #expect(AITitleSanitizer.sanitize("“发布计划”") == "发布计划")
        #expect(AITitleSanitizer.sanitize("**Release plan**") == "Release plan")
        #expect(AITitleSanitizer.sanitize("*Release plan*") == "Release plan")
        #expect(AITitleSanitizer.sanitize("## Release plan") == "Release plan")
        #expect(AITitleSanitizer.sanitize("- Release plan") == "Release plan")
        #expect(AITitleSanitizer.sanitize("3 * 4 * 5") == "3 * 4 * 5")
        #expect(AITitleSanitizer.sanitize("[Release plan](https://example.com/x)") == "Release plan")
    }

    @Test func removesControlCharactersAndCollapsesWhitespace() {
        #expect(AITitleSanitizer.sanitize("Release\u{0}\u{7} plan") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release \u{200B}\u{200B} plan") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release\t\tplan") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release\u{202E} plan") == "Release plan")
    }

    @Test func trimsTrailingPunctuationButKeepsQuestions() {
        #expect(AITitleSanitizer.sanitize("Release plan.") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release plan！") == "Release plan")
        #expect(AITitleSanitizer.sanitize("\"Release plan.\"") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release plan?") == "Release plan?")
        #expect(AITitleSanitizer.sanitize("Release plan…") == "Release plan…")
        #expect(AITitleSanitizer.sanitize("Release plan:") == "Release plan")
    }

    @Test func capsAtTwentyFourDisplayColumnsWithCJKCountingDouble() {
        let ascii = String(repeating: "a", count: 60)
        let capped = AITitleSanitizer.sanitize(ascii)
        #expect(capped == String(repeating: "a", count: 23) + "…")
        #expect(AITitleSanitizer.width(capped ?? "") == 24)

        let cjk = String(repeating: "会", count: 30)
        let cappedCJK = AITitleSanitizer.sanitize(cjk)
        #expect(cappedCJK == String(repeating: "会", count: 11) + "…")
        #expect(cappedCJK?.count == 12)

        // 24 columns of CJK is exactly the limit and is not truncated.
        #expect(AITitleSanitizer.sanitize(String(repeating: "会", count: 12)) == String(repeating: "会", count: 12))
        #expect(AITitleSanitizer.sanitize("会", maxWidth: 1) == nil)
        #expect(AITitleSanitizer.sanitize("abc", maxWidth: 0) == nil)
        #expect(AITitleSanitizer.sanitize("abcdef", maxWidth: 4) == "abc…")
    }

    @Test func measuresHalfwidthAndWideCharacters() {
        #expect(AITitleSanitizer.width("abc") == 3)
        #expect(AITitleSanitizer.width("会") == 2)
        #expect(AITitleSanitizer.width("a会b") == 4)
        #expect(AITitleSanitizer.width("🙂") == 2)
        #expect(AITitleSanitizer.width("") == 0)
    }
}
