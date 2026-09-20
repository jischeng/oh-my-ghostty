import AppKit
import SwiftUI

/// Divider segments are confined to their parent split, including unequal ratios.
enum TabSplitPreviewLayout {
    struct Divider: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    static func dividers<V>(tree: SplitTree<V>, size: CGSize) -> [Divider] {
        guard let spatial = tree.root?.spatial(within: size) else { return [] }
        return spatial.slots.compactMap { slot in
            guard case .split(let split) = slot.node else { return nil }
            let bounds = slot.bounds
            switch split.direction {
            case .horizontal:
                let x = bounds.minX + bounds.width * split.ratio
                return .init(start: CGPoint(x: x, y: bounds.minY), end: CGPoint(x: x, y: bounds.maxY))
            case .vertical:
                let y = bounds.minY + bounds.height * split.ratio
                return .init(start: CGPoint(x: bounds.minX, y: y), end: CGPoint(x: bounds.maxX, y: y))
            }
        }
    }
}

struct TabSplitPreview: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let panes: [SplitTabPane]

    var body: some View {
        GeometryReader { geometry in
            let spatial = tree.root?.spatial(within: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.025)
                ForEach(panes) { pane in
                    if let bounds = spatial?.slots.first(where: {
                        if case .leaf(let surface) = $0.node { return surface.id == pane.id }
                        return false
                    })?.bounds {
                        ZStack {
                            if pane.focused { Color.accentColor.opacity(0.045) }
                            PaneLogoMark(pane: pane, size: min(22, max(1, min(bounds.width, bounds.height) - 10)))
                        }
                        .frame(width: bounds.width, height: bounds.height)
                        .clipped()
                        .position(x: bounds.midX, y: bounds.midY)
                    }
                }
                Path { path in
                    for divider in TabSplitPreviewLayout.dividers(tree: tree, size: geometry.size) {
                        path.move(to: divider.start)
                        path.addLine(to: divider.end)
                    }
                }
                .stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.75)
            }
        }
        .frame(height: 140)
        .accessibilityHidden(true)
    }
}
