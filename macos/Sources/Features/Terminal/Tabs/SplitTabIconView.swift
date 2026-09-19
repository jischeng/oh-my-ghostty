import AppKit
import SwiftUI

// MARK: - Split Tab Icon Layout

/// Calculates the normalized 2x2 grid slots for displaying split panes in a tab icon.
///
/// Rules:
/// - Single Pane: 1 full slot (1.0 x 1.0).
/// - 2 Panes (horizontal or vertical): 2 half slots (0.5 x 1.0 or 1.0 x 0.5).
/// - 3 Panes: 1 half slot and 2 quarter slots (0.5 x 0.5).
/// - 4 Panes: 4 quarter slots (0.5 x 0.5) forming a 2x2 grid.
/// - Minimum allowed size for a distinct slot is 1/2 width x 1/2 height.
///   Any further splits that would make width or height < 1/2 are folded
///   into the parent slot with a stacked/folded appearance.
enum SplitTabIconLayout {
    struct Slot<ViewType: NSView & Codable & Identifiable>: Identifiable, Equatable {
        var id: ViewType.ID {
            views.first!.id
        }

        /// Normalized bounds within [0, 1] x [0, 1]
        let rect: CGRect

        /// The views assigned to this slot. When folded, views.count > 1.
        let views: [ViewType]

        /// True if this slot contains multiple folded/stacked panes.
        let isFolded: Bool

        static func == (lhs: Slot<ViewType>, rhs: Slot<ViewType>) -> Bool {
            lhs.rect == rhs.rect &&
            lhs.isFolded == rhs.isFolded &&
            lhs.views.map(\.id) == rhs.views.map(\.id)
        }
    }

    /// Layout a complete split tree into normalized icon slots.
    static func layout<ViewType>(
        tree: SplitTree<ViewType>
    ) -> [Slot<ViewType>] {
        guard let root = tree.root else { return [] }
        return layout(node: root, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Recursively computes slots, stopping division when a child's width or height would fall below 0.5.
    static func layout<ViewType>(
        node: SplitTree<ViewType>.Node,
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> [Slot<ViewType>] {
        switch node {
        case .leaf(let view):
            return [Slot(rect: rect, views: [view], isFolded: false)]

        case .split(let split):
            switch split.direction {
            case .horizontal:
                // Horizontal split divides width into left and right.
                // Each child gets width: 0.5. Allowed only if rect.width > 0.5.
                if rect.width > 0.5 + 0.001 {
                    let leftRect = CGRect(x: rect.minX, y: rect.minY, width: 0.5, height: rect.height)
                    let rightRect = CGRect(x: rect.minX + 0.5, y: rect.minY, width: 0.5, height: rect.height)
                    return layout(node: split.left, rect: leftRect) +
                           layout(node: split.right, rect: rightRect)
                } else {
                    // Splitting further horizontally would make width < 0.5.
                    // Fold this subtree at the current slot.
                    let leaves = node.leaves()
                    return [Slot(rect: rect, views: leaves, isFolded: leaves.count > 1)]
                }

            case .vertical:
                // Vertical split divides height into top and bottom.
                // Each child gets height: 0.5. Allowed only if rect.height > 0.5.
                if rect.height > 0.5 + 0.001 {
                    let topRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5)
                    let bottomRect = CGRect(x: rect.minX, y: rect.minY + 0.5, width: rect.width, height: 0.5)
                    return layout(node: split.left, rect: topRect) +
                           layout(node: split.right, rect: bottomRect)
                } else {
                    // Splitting further vertically would make height < 0.5.
                    // Fold this subtree at the current slot.
                    let leaves = node.leaves()
                    return [Slot(rect: rect, views: leaves, isFolded: leaves.count > 1)]
                }
            }
        }
    }
}

// MARK: - Split Tab Icon View

/// Renders a multi-pane split tab icon respecting the split hierarchy (up to 2x2).
/// Beyond 2x2, deeper splits are displayed using a folded/stacked card style.
/// Each pane maintains independent status, displaying its agent logo, running spinner,
/// and focused highlight.
struct SplitTabIconView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    let fallbackIcon: GhosttyTabIcon
    let fallbackActivity: TabActivity?
    let iconColor: Color

    private let gap: CGFloat = 1.0

    var body: some View {
        let size = settings.tabIconSize
        let slots = SplitTabIconLayout.layout(tree: controller.surfaceTree)

        ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                let r = pixelRect(for: slot.rect, in: size)
                SplitTabSlotView(
                    controller: controller,
                    slot: slot,
                    rect: r,
                    fallbackIcon: fallbackIcon,
                    fallbackActivity: fallbackActivity,
                    iconColor: iconColor
                )
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
        }
        .frame(width: size, height: size + 3)
        .help(splitHelpText)
        .accessibilityLabel(splitAccessibilityLabel)
    }

    private func pixelRect(for slotRect: CGRect, in size: CGFloat) -> CGRect {
        let w: CGFloat = (slotRect.width >= 1.0 - 0.001) ? size : (size - gap) / 2
        let h: CGFloat = (slotRect.height >= 1.0 - 0.001) ? size : (size - gap) / 2
        let x: CGFloat = (slotRect.minX < 0.001) ? 0 : (size - w)
        let y: CGFloat = (slotRect.minY < 0.001) ? 0 : (size - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private var splitHelpText: String {
        let surfaces = controller.surfaceTree.map { $0 }
        guard !surfaces.isEmpty else { return "Terminal" }
        let descriptions = surfaces.map { surface -> String in
            let isFocused = surface.id == controller.focusedSurface?.id
            let activity = controller.agentActivity(for: surface)
            let agent = activity.flatMap { SupportedAgent(rawValue: $0.source) }
            let title: String = {
                if let agent {
                    return agent.displayName
                }
                if !surface.title.isEmpty {
                    return surface.title
                }
                return "Terminal"
            }()
            var desc = isFocused ? "\(title) (Focused)" : title
            if let state = activity?.state, state != .idle {
                desc += " - \(activity?.message ?? state.rawValue.capitalized)"
            }
            return desc
        }
        return "Split (\(surfaces.count) panes):\n" + descriptions.joined(separator: "\n")
    }

    private var splitAccessibilityLabel: String {
        let count = controller.surfaceTree.count
        return "Split tab with \(count) panes"
    }
}

// MARK: - Split Tab Slot View

struct SplitTabSlotView: View {
    @ObservedObject var controller: TerminalController
    let slot: SplitTabIconLayout.Slot<Ghostty.SurfaceView>
    let rect: CGRect
    let fallbackIcon: GhosttyTabIcon
    let fallbackActivity: TabActivity?
    let iconColor: Color

    private let foldOffset: CGFloat = 1.5

    /// Selects the primary surface to display in this slot.
    /// Priority:
    /// 1. Currently focused surface if inside this slot
    /// 2. Surface with active working agent
    /// 3. First surface
    private var activeSurface: Ghostty.SurfaceView {
        if let focused = controller.focusedSurface, slot.views.contains(where: { $0.id == focused.id }) {
            return focused
        }
        if let working = slot.views.first(where: { controller.agentActivity(for: $0)?.state == .working }) {
            return working
        }
        return slot.views.first ?? controller.surfaceTree.first!
    }

    private var isFocused: Bool {
        guard let focused = controller.focusedSurface else { return false }
        return slot.views.contains(where: { $0.id == focused.id })
    }

    /// Whether any background pane in this folded slot has an active working agent.
    private var hasBackgroundWorkingAgent: Bool {
        guard slot.isFolded else { return false }
        let currentID = activeSurface.id
        return slot.views.contains { surface in
            surface.id != currentID && controller.agentActivity(for: surface)?.state == .working
        }
    }

    private var resolvedPresentation: (icon: GhosttyTabIcon, activity: TabActivity?, agent: SupportedAgent?) {
        let surface = activeSurface
        let session = controller.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface.pwd,
            terminalTitle: surface.title
        )
        let agentActivity = controller.agentActivity(for: surface)
        let canonicalIcon = session.workspace?.icon ?? .systemSymbol(
            session.tabIconSystemName
        )
        let agent = agentActivity.flatMap { SupportedAgent(rawValue: $0.source) }
        let icon: GhosttyTabIcon = if let requested = agentActivity?.icon {
            switch requested.kind {
            case .systemSymbol: .systemSymbol(requested.name)
            case .bundledAsset: .asset(requested.name)
            }
        } else if let agent {
            .asset(agent.assetName)
        } else if surface.id == controller.surfaceTree.first?.id {
            fallbackIcon
        } else {
            canonicalIcon
        }
        let activity = agentActivity ?? (surface.id == controller.surfaceTree.first?.id ? fallbackActivity : nil)
        return (icon, activity, agent)
    }

    var body: some View {
        let (icon, activity, agent) = resolvedPresentation
        let cardW = slot.isFolded ? rect.width - foldOffset : rect.width
        let cardH = slot.isFolded ? rect.height - foldOffset : rect.height
        let minDim = min(cardW, cardH)
        let iconTargetSize = max(minDim * 0.70, 4.0)

        ZStack(alignment: .topLeading) {
            if slot.isFolded {
                // Background card showing the offset edge (└──┐) of stacked panes
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(hasBackgroundWorkingAgent ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(
                                hasBackgroundWorkingAgent ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.35),
                                lineWidth: 0.6
                            )
                    )
                    .frame(width: cardW, height: cardH)
                    .offset(x: foldOffset, y: foldOffset)
            }

            // Foreground card for the primary surface
            ZStack {
                // Opaque card background to cover background stacked cards cleanly
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(slot.isFolded ? Color(NSColor.windowBackgroundColor) : Color.clear)

                // Subtle card fill tint
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isFocused ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))

                // Card border: highlighted if focused
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.25),
                        lineWidth: isFocused ? 0.9 : 0.6
                    )

                SplitTabMiniAgentIconView(
                    icon: icon,
                    activity: activity,
                    agent: agent,
                    color: iconColor,
                    targetSize: iconTargetSize,
                    ringSize: minDim - 0.8
                )
            }
            .frame(width: cardW, height: cardH)
        }
    }
}

// MARK: - Mini Agent Icon & Spinner

struct SplitTabMiniAgentIconView: View {
    let icon: GhosttyTabIcon
    let activity: TabActivity?
    let agent: SupportedAgent?
    let color: Color
    let targetSize: CGFloat
    let ringSize: CGFloat

    private var isSpinning: Bool {
        activity?.state == .working && activity?.progress == nil
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !isSpinning
        )) { timeline in
            ZStack {
                if let activity, activity.state != .idle {
                    Circle()
                        .trim(from: 0, to: ringProgress(activity))
                        .stroke(
                            ringColor(activity),
                            style: .init(lineWidth: 0.8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(
                            isSpinning ? rotation(at: timeline.date) : -90
                        ))
                        .frame(width: ringSize, height: ringSize)
                }

                GhosttyTabIconMiniRenderer(
                    icon: icon,
                    color: color,
                    targetSize: targetSize,
                    agent: agent
                )
            }
        }
    }

    private func rotation(at date: Date) -> Double {
        let period = 0.9
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return phase * 360 - 90
    }

    private func ringProgress(_ activity: TabActivity) -> Double {
        switch activity.state {
        case .idle: 0
        case .working: activity.progress.map { max(0.05, $0) } ?? 0.25
        case .done, .needsAttention, .error: 1
        }
    }

    private func ringColor(_ activity: TabActivity) -> Color {
        switch activity.state {
        case .idle: .clear
        case .working:
            activity.phase == .background ? .purple : .accentColor
        case .done: .green
        case .needsAttention: .orange
        case .error: .red
        }
    }
}

// MARK: - Mini Icon Renderer

struct GhosttyTabIconMiniRenderer: View {
    let icon: GhosttyTabIcon
    let color: Color
    let targetSize: CGFloat
    let agent: SupportedAgent?

    var body: some View {
        Group {
            switch icon {
            case .systemSymbol(let name):
                Image(systemName: name)
                    .font(.system(size: targetSize, weight: .semibold))
            case .asset(let name):
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: targetSize, height: targetSize)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: targetSize, height: targetSize)
            }
        }
        .scaleEffect(agent?.definition.iconScale ?? 1.0)
        .foregroundStyle(color)
        .frame(width: targetSize, height: targetSize)
    }
}
