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

    static func color(_ activity: TabActivity, scheme: ColorScheme = .dark) -> Color {
        let dark = scheme == .dark
        switch activity.state {
        case .idle: return .clear
        case .working: return dark ? Color(red: 0.65, green: 0.79, blue: 0.94)
            : Color(red: 0.28, green: 0.48, blue: 0.67)
        case .done: return dark ? Color(red: 0.73, green: 0.82, blue: 0.77)
            : Color(red: 0.40, green: 0.54, blue: 0.47)
        case .needsAttention: return dark ? Color(red: 0.91, green: 0.77, blue: 0.54)
            : Color(red: 0.64, green: 0.45, blue: 0.22)
        case .error: return dark ? Color(red: 0.91, green: 0.64, blue: 0.62)
            : Color(red: 0.70, green: 0.35, blue: 0.34)
        }
    }

    /// A perceptible 2.4s brightness breath, not just a tiny change in tint opacity.
    static func breath(at time: TimeInterval, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : (1 - cos(time * 2 * .pi / 2.4)) / 2
    }

    static func logoOpacity(breath: Double) -> Double { 0.55 + 0.45 * breath }

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

/// A faint continuous arc brightens in working regions. No stationary track or segment breaks.
struct TabActivityRing: View {
    let activity: TabActivity
    var sectors: [ClosedRange<Double>] = [0...1]
    @Environment(\.colorScheme) private var colorScheme
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
                    .stroke(TabActivityRingStyle.color(activity, scheme: colorScheme),
                            style: .init(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(phase * 360 - 90))
                    .mask {
                        GeometryReader { geometry in
                            ZStack {
                                Rectangle().fill(.white.opacity(0.24))
                                Path { path in
                                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                for sector in sectors {
                                    path.move(to: center)
                                    path.addArc(center: center, radius: max(geometry.size.width, geometry.size.height),
                                                startAngle: .degrees(sector.lowerBound * 360 - 90),
                                                endAngle: .degrees(sector.upperBound * 360 - 90), clockwise: false)
                                    path.closeSubpath()
                                }
                                }.fill(.white).blur(radius: 1.2)
                            }
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let working = activity?.state == .working
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !working || reduceMotion)) { timeline in
            let breath = TabActivityRingStyle.breath(
                at: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion
            )
            content.overlay {
                if let activity, activity.state != .idle {
                    TabActivityRingStyle.color(activity, scheme: colorScheme)
                        .opacity(activity.state == .done ? 0.14 : 0.60)
                        .mask(content)
                }
            }
            .opacity(working ? TabActivityRingStyle.logoOpacity(breath: breath) : 1)
            .shadow(color: working
                    ? TabActivityRingStyle.color(activity!, scheme: colorScheme).opacity(0.28 * breath)
                    : .clear, radius: working ? 1 + 1.5 * breath : 0)
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
