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

    @Test func wholeTabWorkIncludesHiddenPanesAndStopsWhenAllStop() {
        #expect(TabActivityRingStyle.combinedWork([]) == nil)
        #expect(TabActivityRingStyle.combinedWork([pane(.done).activity!, pane(.idle).activity!]) == nil)
        let work = TabActivityRingStyle.combinedWork([pane(.idle).activity!, pane(.working).activity!])
        #expect(work?.state == .working)
        #expect(work?.progress == nil)
        let background = TabActivity(source: "pi", state: .working, phase: .background,
                                     label: nil, message: nil, detail: nil, progress: 0.6, icon: nil)
        #expect(TabActivityRingStyle.combinedWork([background])?.phase == .background)
        #expect(TabActivityRingStyle.combinedWork([background, pane(.working).activity!])?.phase == nil)
    }

    @Test func sharedRingPreservesReleaseStateSemantics() {
        #expect(TabActivityRingStyle.progress(pane(.idle).activity!) == 0)
        #expect(TabActivityRingStyle.progress(pane(.working).activity!) == 0.25)
        for state in [TabActivityState.done, .error, .needsAttention] {
            #expect(TabActivityRingStyle.progress(pane(state).activity!) == 1)
        }
    }

    @Test func compositionCornersAndDotsStayInsideRing() {
        let innerRadius = TabIconMetrics.ring / 2 - 0.75
        #expect(TabIconMetrics.composition / 2 * sqrt(2) < innerRadius)
        for preferred in [CGFloat(12), 16, 20] {
            #expect(TabIconMetrics.singleLogo(preferred) / 2 * sqrt(2) < innerRadius)
        }
    }

    @Test func renderActualSizeComposition() throws {
        let positions: [[CGPoint]] = [
            [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.75, y: 0.75)],
            [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
             CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]
        ]
        let preview = HStack(spacing: 16) {
            ForEach(positions.indices, id: \.self) { layout in
                ZStack {
                    ForEach(positions[layout].indices, id: \.self) { index in
                        PaneLogoMark(pane: pane(index == 0 ? .working : .idle), size: TabIconMetrics.pane)
                            .position(x: positions[layout][index].x * TabIconMetrics.composition,
                                      y: positions[layout][index].y * TabIconMetrics.composition)
                    }
                }
                .frame(width: TabIconMetrics.composition, height: TabIconMetrics.composition)
                .frame(width: TabIconMetrics.footprint, height: TabIconMetrics.footprint)
                .overlay {
                    TabActivityRing(activity: pane(.working).activity!)
                        .frame(width: TabIconMetrics.ring, height: TabIconMetrics.ring)
                }
            }
        }
        let renderer = ImageRenderer(content: preview.padding(16).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omg-pane-icons-preview.png"))
    }
}
