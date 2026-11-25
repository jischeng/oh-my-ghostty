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

    @Test func trimsTrailingPunctuationAndEllipsesButKeepsQuestions() {
        #expect(AITitleSanitizer.sanitize("Release plan.") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release plan！") == "Release plan")
        #expect(AITitleSanitizer.sanitize("\"Release plan.\"") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release plan?") == "Release plan?")
        #expect(AITitleSanitizer.sanitize("Release plan…") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Release plan...") == "Release plan")
        #expect(AITitleSanitizer.sanitize("重命名为...") == "重命名为")
        #expect(AITitleSanitizer.sanitize("“重命名为……”") == "重命名为")
        #expect(AITitleSanitizer.sanitize("Release plan:") == "Release plan")
        #expect(AITitleSanitizer.sanitize("Fix Node.js") == "Fix Node.js")
        #expect(AITitleSanitizer.sanitize("...") == nil)
        #expect(AITitleSanitizer.sanitize("…\nReal title…") == "Real title")
    }

    @Test func capsAtThirtySixDisplayColumnsCleanlyWithoutBakedInEllipsis() {
        #expect(AITitleSanitizer.maxWidth == 36)

        // Concise 13–18 CJK character titles fit within 36 columns without any chop or ellipsis.
        let sixteenCJK = "修复收件箱标签页自动重命名省略号"
        #expect(AITitleSanitizer.sanitize(sixteenCJK) == sixteenCJK)
        #expect(AITitleSanitizer.sanitize(String(repeating: "会", count: 18)) == String(repeating: "会", count: 18))

        // Runaway single-token ASCII cuts at 36 columns without appending "…".
        let ascii = String(repeating: "a", count: 60)
        let capped = AITitleSanitizer.sanitize(ascii)
        #expect(capped == String(repeating: "a", count: 36))
        #expect(AITitleSanitizer.width(capped ?? "") == 36)
        #expect(capped?.contains("…") == false)

        // Runaway multi-word English cuts cleanly at a word boundary without appending "…".
        let sentence = "Fix the flaky login test across CI runners and retry"
        let wordBounded = AITitleSanitizer.sanitize(sentence)
        #expect(wordBounded == "Fix the flaky login test across CI")
        #expect(AITitleSanitizer.width(wordBounded ?? "") <= 36)

        // Runaway CJK cuts at character boundary without appending "…"; mixed CJK + half-cut ASCII word drops the broken word.
        let cjk = String(repeating: "会", count: 30)
        let cappedCJK = AITitleSanitizer.sanitize(cjk)
        #expect(cappedCJK == String(repeating: "会", count: 18))
        #expect(cappedCJK?.count == 18)
        #expect(AITitleSanitizer.sanitize("修复 API 请求在弱网环境下的超时重试与幂等性校验问题") == "修复 API 请求在弱网环境下的超时重试")
        #expect(AITitleSanitizer.sanitize("修复 API 请求在弱网环境下超时重试与PostgreSQL连接池") == "修复 API 请求在弱网环境下超时重试与")
        #expect(AgentConversationTitleStore.displayTitle("修复 API 请求在弱网环境下超时重试与PostgreSQL连接池", columns: 36)
            == "修复 API 请求在弱网环境下超时重试与")
        #expect(AITitleSanitizer.sanitize("重构客户端 NativeTabSidebarController") == "重构客户端")

        #expect(AITitleSanitizer.sanitize("会", maxWidth: 1) == nil)
        #expect(AITitleSanitizer.sanitize("abc", maxWidth: 0) == nil)
        #expect(AITitleSanitizer.sanitize("abcdef", maxWidth: 4) == "abcd")
    }

    @Test func measuresHalfwidthAndWideCharacters() {
        #expect(AITitleSanitizer.width("abc") == 3)
        #expect(AITitleSanitizer.width("会") == 2)
        #expect(AITitleSanitizer.width("a会b") == 4)
        #expect(AITitleSanitizer.width("🙂") == 2)
        #expect(AITitleSanitizer.width("") == 0)
    }
}
