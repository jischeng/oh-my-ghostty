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

    @Test func foldingPrioritizesFocusThenAttentionThenWork() {
        let idle = pane()
        let working = pane(.working)
        let attention = pane(.needsAttention)
        let focused = pane(focused: true)
        #expect(SplitTabPane.front(in: [idle, working])?.id == working.id)
        #expect(SplitTabPane.front(in: [working, attention])?.id == attention.id)
        #expect(SplitTabPane.front(in: [attention, focused])?.id == focused.id)
        #expect(SplitTabPane.front(in: []) == nil)
        #expect(SplitTabPane.front(in: [idle, pane()])?.id == idle.id)
    }

    @Test func renderActualSizeComposition() throws {
        let a = pane(focused: true)
        let b = pane(.working)
        let c = pane(.needsAttention)
        let icon = ZStack {
            PaneLogoMark(pane: a, size: 12).position(x: 6, y: 6)
            PaneLogoMark(pane: b, size: 12).position(x: 18, y: 6)
            PaneLogoMark(pane: c, size: 12).position(x: 6, y: 18)
            SplitTabLogoStack(panes: [pane(), pane()]).position(x: 18, y: 18)
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
