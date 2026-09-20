import SwiftUI

/// Both presentations share the same outer footprint. The compact square fits
/// inside the ring's inner edge even at its corners (including status dots).
enum TabIconMetrics {
    static let footprint: CGFloat = 30
    static let ring: CGFloat = 30
    static let composition: CGFloat = 19
    static let pane: CGFloat = composition / 2
    static func singleLogo(_ preferred: CGFloat) -> CGFloat { min(18, max(17, preferred)) }
}

enum TabActivityRingStyle {
    static func progress(_ activity: TabActivity) -> Double {
        switch activity.state {
        case .idle: 0
        case .working: activity.progress.map { min(1, max(0.05, $0)) } ?? 0.25
        case .done, .needsAttention, .error: 1
        }
    }

    static func color(_ activity: TabActivity) -> Color {
        switch activity.state {
        case .idle: .clear
        case .working: activity.phase == .background ? .purple : .accentColor
        case .done: .green
        case .needsAttention: .orange
        case .error: .red
        }
    }

    /// A tab spinner reports work, never an average progress across unrelated jobs.
    /// Includes hidden panes; foreground work wins over background-only work.
    static func combinedWork(_ activities: [TabActivity]) -> TabActivity? {
        let working = activities.filter { $0.state == .working }
        guard let first = working.first else { return nil }
        return .init(source: first.source, state: .working,
                     phase: working.allSatisfy { $0.phase == .background } ? .background : nil,
                     label: nil, message: nil, detail: nil, progress: nil, icon: nil)
    }
}

/// The release spinner: one quarter arc, continuously rotating at a 0.9s period.
/// Single-pane determinate progress and terminal states retain their original semantics.
struct TabActivityRing: View {
    let activity: TabActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spinning: Bool {
        activity.state == .working && activity.progress == nil && !reduceMotion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { timeline in
            let phase = spinning ? timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 0.9) / 0.9 : 0
            Circle().trim(from: 0, to: TabActivityRingStyle.progress(activity))
                .stroke(TabActivityRingStyle.color(activity), style: .init(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(phase * 360 - 90))
        }
        .accessibilityHidden(true)
    }
}

struct TabActivityDot: View {
    let activity: TabActivity

    var body: some View {
        if activity.state != .idle {
            Circle().fill(TabActivityRingStyle.color(activity))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 0.5))
                .frame(width: 3, height: 3)
                .accessibilityHidden(true)
        }
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
