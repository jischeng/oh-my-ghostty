import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalHistoryHighlightTests {
    @Test func highlightsOnlyTheExactViewportRowAfterAScroll() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 250)
        let first = Ghostty.SurfaceView.historyHighlightFrame(
            row: 0, topPadding: 10, bounds: bounds, cellHeight: 20
        )
        let third = Ghostty.SurfaceView.historyHighlightFrame(
            row: 2, topPadding: 10, bounds: bounds, cellHeight: 20
        )
        #expect(first == CGRect(x: 4, y: 220, width: 312, height: 20))
        #expect(third == CGRect(x: 4, y: 180, width: 312, height: 20))
        #expect(Ghostty.SurfaceView.historyHighlightFrame(
            row: 13, topPadding: 10, bounds: bounds, cellHeight: 20
        ) == nil)
        #expect(Ghostty.SurfaceView.historyHighlightFrame(
            row: 0, topPadding: -1, bounds: bounds, cellHeight: 20
        ) == nil)
    }
}
