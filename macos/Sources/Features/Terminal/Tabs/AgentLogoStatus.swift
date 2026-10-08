import SwiftUI

/// Shared footprint keeps single and multi-pane titles aligned within a 28pt row.
enum TabIconMetrics {
    static let footprint: CGFloat = 26
    static let composition: CGFloat = 22
    static let pane: CGFloat = composition / 2
    static func singleLogo(_ preferred: CGFloat) -> CGFloat { min(18, max(17, preferred)) }
}

enum AgentLogoStyle {
    static func color(_ activity: TabActivity) -> Color {
        switch activity.state {
        case .idle: return .clear
        case .working: return activity.phase == .background ? .purple : .accentColor
        case .done: return Color(nsColor: NSColor.systemGreen.blended(withFraction: 0.15, of: .black) ?? .systemGreen)
        case .needsAttention: return .orange
        case .error: return .red
        }
    }

    static func tintStrength(state: TabActivityState?, focused: Bool) -> Double {
        switch state {
        case .done, .working, .needsAttention, .error: return 1
        case .idle, nil: return focused ? 1 : 0
        }
    }

    /// Starts at full brightness, avoiding a random phase jump on entering work.
    static func breath(at time: TimeInterval, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : (1 + cos(max(0, time) * 2 * .pi / 1.8)) / 2
    }

    static func logoOpacity(breath: Double) -> Double { 0.30 + 0.70 * breath }

    static func animates(state: TabActivityState?, visible: Bool, reduceMotion: Bool) -> Bool {
        state == .working && visible && !reduceMotion
    }
}

/// Alpha-masked tint preserves transparent silhouettes and underlying image detail.
/// Shared by the single logo, compact panes and hover preview. Working state is
/// expressed only by the logo's breath, with no outer ring or status dot.
struct AgentLogoStatus: ViewModifier {
    let activity: TabActivity?
    var focused = false
    @State private var visible = false
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let animating = AgentLogoStyle.animates(
            state: activity?.state, visible: visible, reduceMotion: reduceMotion
        )
        content.overlay {
            let tint = activity.flatMap { $0.state == .idle ? nil : $0 }
                .map { AgentLogoStyle.color($0) } ?? .accentColor
            tint.opacity(AgentLogoStyle.tintStrength(state: activity?.state, focused: focused))
                // Animate only the tint, never the mask's layout.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: activity?.state)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: focused)
                .mask(content)
        }
        // Only the opacity interpolates. No timer re-evaluates the masked
        // content or its containing tab/window every animation frame.
        .opacity(dimmed ? AgentLogoStyle.logoOpacity(breath: 0) : 1)
        .animation(
            animating ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
            value: dimmed
        )
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            dimmed = false
        }
        .onChange(of: animating) { dimmed = $0 }
    }
}

/// Controller-owned recency survives sidebar reconstruction and focus moving to another slot.
struct TabPaneFocusHistory {
    private(set) var recent: [UUID] = []

    mutating func record(_ id: UUID?, liveIDs: Set<UUID>) {
        recent.removeAll { !liveIDs.contains($0) || $0 == id }
        if let id, liveIDs.contains(id) { recent.insert(id, at: 0) }
    }

    func representative(in ids: [UUID], focused: UUID?) -> UUID? {
        if let focused, ids.contains(focused) { return focused }
        return recent.first(where: { ids.contains($0) }) ?? ids.first
    }
}
