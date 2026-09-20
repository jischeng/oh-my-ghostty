import SwiftUI

/// Shared single-pane and split-pane activity semantics. Fractions start at twelve o'clock.
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

    /// A contiguous perimeter interval for each normalized half or quadrant.
    /// Intervals may cross 1.0 (top half), preserving one continuous animation.
    static func interval(for rect: CGRect) -> ClosedRange<Double> {
        if rect.width == 1 && rect.height == 1 { return 0...1 }
        if rect.width == 1 { return rect.minY == 0 ? 0.75...1.25 : 0.25...0.75 }
        if rect.height == 1 { return rect.minX == 0 ? 0.5...1 : 0...0.5 }
        let start: Double = rect.minX == 0 ? (rect.minY == 0 ? 0.75 : 0.5) : (rect.minY == 0 ? 0 : 0.25)
        return start...(start + 0.25)
    }

    static func wrapped(_ range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let start = range.lowerBound.truncatingRemainder(dividingBy: 1)
        let end = start + range.upperBound - range.lowerBound
        return end <= 1 ? [start...end] : [start...1, 0...(end - 1)]
    }
}

struct TabActivityRing: View {
    let activity: TabActivity
    var interval: ClosedRange<Double> = 0...1
    var segmented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spinning: Bool {
        activity.state == .working && activity.progress == nil && !reduceMotion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { timeline in
            let phase = spinning ? timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 0.9) / 0.9 : 0
            let gap = segmented ? 0.012 : 0
            let start = interval.lowerBound + gap
            let length = interval.upperBound - interval.lowerBound - gap * 2
            let progress = TabActivityRingStyle.progress(activity)
            let head = phase * length
            let end = head + length * progress
            let localRanges: [ClosedRange<Double>] = end <= length
                ? [(start + head)...(start + end)]
                : [(start + head)...(start + length), start...(start + end - length)]
            ZStack {
                // A quiet working track makes the pane's ownership visible even at 12pt logos.
                if segmented && activity.state == .working {
                    arcs(TabActivityRingStyle.wrapped(start...(start + length)))
                        .opacity(0.20)
                }
                arcs(localRanges.flatMap { TabActivityRingStyle.wrapped($0) })
            }
        }
        .accessibilityHidden(true)
    }

    private func arcs(_ ranges: [ClosedRange<Double>]) -> some View {
        ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
            Circle().trim(from: range.lowerBound, to: range.upperBound)
                .stroke(TabActivityRingStyle.color(activity), style: .init(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
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
