import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SplitTabPresentationTests {
    private func pane(_ state: TabActivityState = .idle, focused: Bool = false) -> SplitTabPane {
        .init(id: UUID(), icon: .systemSymbol("terminal"),
              activity: .init(source: "pi", state: state, label: nil, message: nil,
                              detail: nil, progress: nil, icon: nil),
              title: "Terminal", focused: focused)
    }

    @Test func regionRetainsLastFocusWhenFocusMovesElsewhere() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = TabPaneFocusHistory()
        history.record(a, liveIDs: [a, b, c])
        history.record(b, liveIDs: [a, b, c])
        history.record(c, liveIDs: [a, b, c])
        #expect(history.representative(in: [a, b], focused: c) == b)
        #expect(history.representative(in: [a, b], focused: a) == a)
        history.record(nil, liveIDs: [a, c])
        #expect(history.representative(in: [a], focused: c) == a)
        #expect(history.representative(in: [], focused: c) == nil)
    }

    @Test func ringIntervalsFollowPanePositions() {
        #expect(TabActivityRingStyle.interval(for: CGRect(x: 0, y: 0, width: 0.5, height: 1)) == 0.5...1)
        #expect(TabActivityRingStyle.interval(for: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)) == 0...0.5)
        #expect(TabActivityRingStyle.interval(for: CGRect(x: 0, y: 0, width: 1, height: 0.5)) == 0.75...1.25)
        #expect(TabActivityRingStyle.wrapped(0.75...1.25) == [0.75...1, 0...0.25])
        let quarters = [(0.5, 0.0), (0.5, 0.5), (0.0, 0.5), (0.0, 0.0)]
        for (index, point) in quarters.enumerated() {
            let rect = CGRect(x: point.0, y: point.1, width: 0.5, height: 0.5)
            let start = Double(index) / 4
            #expect(TabActivityRingStyle.interval(for: rect) == start...(start + 0.25))
        }
    }

    @Test func sharedRingPreservesReleaseStateSemantics() {
        #expect(TabActivityRingStyle.progress(pane(.idle).activity!) == 0)
        #expect(TabActivityRingStyle.progress(pane(.working).activity!) == 0.25)
        for state in [TabActivityState.done, .error, .needsAttention] {
            #expect(TabActivityRingStyle.progress(pane(state).activity!) == 1)
        }
    }

    @Test func renderActualSizeComposition() throws {
        let a = pane(focused: true)
        let b = pane(.working)
        let c = pane(.needsAttention)
        let icon = ZStack {
            PaneLogoMark(pane: a, size: 12, showsActivity: false).position(x: 6, y: 6)
            PaneLogoMark(pane: b, size: 12, showsActivity: false).position(x: 18, y: 6)
            PaneLogoMark(pane: c, size: 12, showsActivity: false).position(x: 6, y: 18)
            TabActivityRing(activity: b.activity!, interval: 0...0.25, segmented: true)
                .frame(width: 29, height: 29)
                .frame(width: 24, height: 24)
            TabActivityRing(activity: c.activity!, interval: 0.5...0.75, segmented: true)
                .frame(width: 29, height: 29)
                .frame(width: 24, height: 24)
            PaneLogoMark(pane: pane(), size: 12, showsActivity: false).position(x: 18, y: 18)
        }.frame(width: 24, height: 24)
        let renderer = ImageRenderer(content: icon.padding(16).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: 56, height: 56))
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omg-pane-icons-preview.png"))
    }
}
