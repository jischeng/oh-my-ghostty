import AppKit
import SwiftUI

/// Icon geometry preserves split direction, not terminal divider ratios.
/// Stop at half-width/half-height; deeper subtrees retain every pane in one slot.
enum SplitTabIconLayout {
    struct Slot<ViewType: NSView & Codable & Identifiable>: Identifiable, Equatable {
        var id: ViewType.ID { views[0].id }
        let rect: CGRect
        let views: [ViewType]
        let isFolded: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rect == rhs.rect && lhs.isFolded == rhs.isFolded &&
                lhs.views.map(\.id) == rhs.views.map(\.id)
        }
    }

    static func layout<V>(tree: SplitTree<V>) -> [Slot<V>] {
        guard let root = tree.root else { return [] }
        return layout(node: root)
    }

    private static func layout<V>(
        node: SplitTree<V>.Node,
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> [Slot<V>] {
        switch node {
        case .leaf(let view):
            return [.init(rect: rect, views: [view], isFolded: false)]
        case .split(let split):
            let horizontal = split.direction == .horizontal
            guard (horizontal ? rect.width : rect.height) > 0.5 else {
                return [.init(rect: rect, views: node.leaves(), isFolded: true)]
            }
            var first = rect
            if horizontal { first.size.width /= 2 } else { first.size.height /= 2 }
            let second = first.offsetBy(dx: horizontal ? first.width : 0,
                                        dy: horizontal ? 0 : first.height)
            return layout(node: split.left, rect: first) + layout(node: split.right, rect: second)
        }
    }
}

/// Value-only presentation: no tab-wide/focused activity may leak into another pane.
struct SplitTabPane: Identifiable {
    let id: UUID
    let icon: GhosttyTabIcon
    let activity: TabActivity?
    let title: String
    let focused: Bool

}

struct SplitTabIconView: View {
    @ObservedObject var controller: TerminalController
    let hovered: Bool
    let select: () -> Void
    @State private var iconHovered = false
    @State private var previewVisible = false

    private var panes: [SplitTabPane] {
        controller.surfaceTree.map { surface in
            let activity = controller.agentActivity(for: surface)
            let session = controller.paneSessionContext(for: surface)
            let agent = activity.flatMap { SupportedAgent(rawValue: $0.source) }
            let icon: GhosttyTabIcon
            if let requested = activity?.icon {
                switch requested.kind {
                case .bundledAsset: icon = .asset(requested.name)
                case .systemSymbol: icon = .systemSymbol(requested.name)
                }
            } else if let agent {
                icon = .asset(agent.assetName)
            } else {
                icon = session?.workspace?.icon ?? .systemSymbol(session?.tabIconSystemName ?? "terminal")
            }
            return .init(id: surface.id, icon: icon, activity: activity,
                         title: agent?.displayName ?? surface.title,
                         focused: surface.id == (controller.focusedSurface ?? controller.surfaceTree.first)?.id)
        }
    }

    var body: some View {
        let values = panes
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        let slots = SplitTabIconLayout.layout(tree: controller.surfaceTree)
        ZStack {
            ForEach(slots) { slot in
                if let id = controller.tabPaneFocusHistory.representative(
                    in: slot.views.map(\.id), focused: controller.focusedSurface?.id
                ), let pane = byID[id] {
                    PaneLogoMark(pane: pane, size: TabIconMetrics.pane)
                        .position(x: slot.rect.midX * TabIconMetrics.composition,
                                  y: slot.rect.midY * TabIconMetrics.composition)
                }
            }
        }
        .frame(width: TabIconMetrics.composition, height: TabIconMetrics.composition)
        .frame(width: TabIconMetrics.footprint, height: TabIconMetrics.footprint)
        .overlay {
            if let activity = TabActivityRingStyle.combinedWork(values.compactMap(\.activity)) {
                TabActivityRing(activity: activity)
                    .frame(width: TabIconMetrics.ring, height: TabIconMetrics.ring)
            }
        }
        .opacity(hovered ? 1 : 0.88)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { iconHovered = $0 }
        .task(id: iconHovered) {
            guard iconHovered else { previewVisible = false; return }
            do { try await Task.sleep(nanoseconds: 550_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            previewVisible = true
        }
        .onDisappear { previewVisible = false }
        .popover(isPresented: $previewVisible, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(values.count) Panes").font(.headline)
                TabSplitPreview(tree: controller.surfaceTree, panes: values)
                ForEach(values) { pane in
                    HStack(spacing: 10) {
                        PaneLogoMark(pane: pane, size: 18)
                        Text(pane.title.isEmpty ? "Terminal" : pane.title).lineLimit(1)
                        Spacer()
                        Text(pane.activity?.state.rawValue ?? "idle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .padding(16)
            .frame(width: 280)
        }
        .accessibilityLabel(values.map {
            "\($0.title), \($0.activity?.state.rawValue ?? "idle")\($0.focused ? ", focused" : "")"
        }.joined(separator: "; "))
    }
}

/// Shared by the compact composition and the larger hover inspector.
struct PaneLogoMark: View {
    let pane: SplitTabPane
    let size: CGFloat
    var showsActivity = true

    var body: some View {
            ZStack {
                if pane.focused {
                    Circle().fill(Color.accentColor.opacity(0.20))
                        .blur(radius: 2)
                        .frame(width: size, height: size)
                }
                logo
                    .padding(0.5)
                    .frame(width: size, height: size)
                if showsActivity, let activity = pane.activity, activity.state != .idle {
                    TabActivityDot(activity: activity)
                        .offset(x: (size - 3) / 2, y: (size - 3) / 2)
                }
            }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var logo: some View {
        switch pane.icon {
        case .systemSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .foregroundStyle(Color.primary.opacity(pane.focused ? 0.95 : 0.65))
        case .asset(let name):
            Image(name).resizable().scaledToFit()
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}
