import SwiftUI

/// Logos approach the ring; the working arc is drawn behind them.
enum TabIconMetrics {
    static let footprint: CGFloat = 30
    static let ring: CGFloat = 30
    static let composition: CGFloat = 22
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

    /// Clockwise fractions starting at twelve o'clock, for masking a single rotating arc.
    static func sectors(for rect: CGRect) -> [ClosedRange<Double>] {
        if rect.width == 1 && rect.height == 1 { return [0...1] }
        if rect.width == 1 { return rect.minY == 0 ? [0...0.25, 0.75...1] : [0.25...0.75] }
        if rect.height == 1 { return rect.minX == 0 ? [0.5...1] : [0...0.5] }
        let start: Double = rect.minX == 0 ? (rect.minY == 0 ? 0.75 : 0.5) : (rect.minY == 0 ? 0 : 0.25)
        return [start...(start + 0.25)]
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

/// One continuous working arc, masked by pane ownership; no segmented tracks.
struct TabActivityRing: View {
    let activity: TabActivity
    var sectors: [ClosedRange<Double>] = [0...1]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spinning: Bool {
        activity.state == .working && !reduceMotion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { timeline in
            let phase = spinning ? timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 0.9) / 0.9 : 0
            if activity.state == .working {
                Circle().trim(from: 0, to: reduceMotion ? 1 : 0.25)
                    .stroke(Color.blue, style: .init(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(phase * 360 - 90))
                    .mask {
                        GeometryReader { geometry in
                            Path { path in
                                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                for sector in sectors {
                                    path.move(to: center)
                                    path.addArc(center: center, radius: max(geometry.size.width, geometry.size.height),
                                                startAngle: .degrees(sector.lowerBound * 360 - 90),
                                                endAngle: .degrees(sector.upperBound * 360 - 90), clockwise: false)
                                    path.closeSubpath()
                                }
                            }.fill(.white).blur(radius: 0.7)
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Alpha-masked tint preserves transparent silhouettes and underlying image detail.
/// Shared by the single logo, compact panes and hover preview.
struct AgentLogoStatus: ViewModifier {
    let activity: TabActivity?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let working = activity?.state == .working
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !working || reduceMotion)) { timeline in
            content.overlay {
                if let activity, activity.state != .idle {
                    let pulse = working && !reduceMotion
                        ? 0.08 * sin(timeline.date.timeIntervalSinceReferenceDate * .pi) : 0
                    let color: Color = working ? .blue : TabActivityRingStyle.color(activity)
                    color.opacity((activity.state == .done ? 0.50 : 0.78) + pulse)
                        .mask(content)
                }
            }
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
