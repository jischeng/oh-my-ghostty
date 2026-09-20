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

    var priority: Int {
        if focused { return 4 }
        switch activity?.state {
        case .error, .needsAttention: return 3
        case .working: return 2
        default: return 0
        }
    }

    static func front(in panes: [Self]) -> Self? {
        panes.enumerated().max {
            $0.element.priority == $1.element.priority
                ? $0.offset > $1.offset : $0.element.priority < $1.element.priority
        }?.element
    }
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
                SplitTabLogoStack(panes: slot.views.compactMap { byID[$0.id] })
                    .position(x: slot.rect.midX * 24, y: slot.rect.midY * 24)
            }
        }
        .frame(width: 24, height: 24)
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
                // Unlike the compact icon, the preview exposes all folded leaves.
                let spatial = controller.surfaceTree.root?.spatial(within: CGSize(width: 180, height: 120))
                ZStack(alignment: .topLeading) {
                    ForEach(values) { pane in
                        if let bounds = spatial?.slots.first(where: {
                            if case .leaf(let surface) = $0.node { return surface.id == pane.id }
                            return false
                        })?.bounds {
                            PaneLogoMark(pane: pane, size: 20)
                                .position(x: bounds.midX, y: bounds.midY)
                        }
                    }
                }
                .frame(width: 180, height: 120)
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

/// Logo size never changes on folding. Two quiet exposed edges communicate depth.
struct SplitTabLogoStack: View {
    let panes: [SplitTabPane]

    var body: some View {
        if let front = SplitTabPane.front(in: panes) {
            let hidden = panes.filter { $0.id != front.id }
            ZStack {
                ForEach(0..<min(hidden.count, 2), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2.5)
                        .trim(from: 0.25, to: 0.75)
                        .stroke(Color.primary.opacity(index == 0 ? 0.28 : 0.14), lineWidth: 0.65)
                        .frame(width: 10, height: 10)
                        .offset(x: CGFloat(index + 1), y: CGFloat(index + 1))
                }
                PaneLogoMark(pane: front, size: 12)
                if let background = SplitTabPane.front(in: hidden), background.priority > 0 {
                    Circle()
                        .fill(background.activity?.state == .working ? Color.accentColor : .orange)
                        .frame(width: 2.5, height: 2.5)
                        .offset(x: 5, y: 5)
                }
            }
            .frame(width: 12, height: 12)
        }
    }
}

/// Shared by the compact composition and the larger hover inspector.
struct PaneLogoMark: View {
    let pane: SplitTabPane
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let working = pane.activity?.state == .working
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !working || reduceMotion)) { timeline in
            ZStack {
                if pane.focused {
                    Circle().fill(Color.accentColor.opacity(0.20))
                        .blur(radius: 2)
                        .frame(width: size, height: size)
                }
                logo
                    .padding(0.5)
                    .frame(width: size, height: size)
                if working {
                    Circle().trim(from: 0, to: 0.23)
                        .stroke(pane.activity?.phase == .background ? Color.purple : .accentColor,
                                style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(reduceMotion ? -90 :
                            timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) * 300))
                } else if pane.activity?.state == .needsAttention || pane.activity?.state == .error {
                    Circle().fill(pane.activity?.state == .error ? Color.red : .orange)
                        .frame(width: 3, height: 3)
                        .offset(x: size / 2 - 1, y: size / 2 - 1)
                }
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
