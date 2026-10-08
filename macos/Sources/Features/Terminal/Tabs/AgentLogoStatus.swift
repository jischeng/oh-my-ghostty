import AppKit
import QuartzCore
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        AgentLogoNativeBreath(
            content: AnyView(content.overlay {
                let tint = activity.flatMap { $0.state == .idle ? nil : $0 }
                    .map { AgentLogoStyle.color($0) } ?? .accentColor
                tint.opacity(AgentLogoStyle.tintStrength(state: activity?.state, focused: focused))
                    .mask(content)
            }),
            working: AgentLogoStyle.animates(state: activity?.state, visible: true, reduceMotion: reduceMotion)
        )
    }
}

/// The animated layer belongs to an AppKit container, not SwiftUI's display
/// list. Its static hosting view has no frame clock or repeating transaction.
struct AgentLogoNativeBreath: NSViewRepresentable {
    let content: AnyView
    let working: Bool

    func makeNSView(context: Context) -> AgentLogoAnimationHost { AgentLogoAnimationHost() }

    func updateNSView(_ view: AgentLogoAnimationHost, context: Context) {
        view.setContent(AnyView(content.environment(\.self, context.environment)), working: working)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentLogoAnimationHost, context: Context) -> CGSize? {
        nsView.hostingView.fittingSize
    }

    static func dismantleNSView(_ view: AgentLogoAnimationHost, coordinator: Void) {
        view.stop()
    }
}

@MainActor
final class AgentLogoAnimationHost: NSView {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var working = false
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // Icons must not intercept the enclosing tab's clicks or drag initiation.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setContent(_ content: AnyView, working: Bool) {
        hostingView.rootView = content
        self.working = working
        refreshAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAnimation() }
                })
            }
        }
        refreshAnimation()
    }

    override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }

    private func refreshAnimation() {
        let visible = window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        guard let layer else { return }
        AgentLogoLayerBreath.setRunning(working && visible && !isHiddenOrHasHiddenAncestor, on: layer)
    }

    func stop() {
        working = false
        if let layer { AgentLogoLayerBreath.setRunning(false, on: layer) }
        removeWindowObservers()
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }
}

/// Idempotent state changes do not restart the breath. The model opacity stays
/// fully bright so removing an animation never leaves a dim idle/done logo.
@MainActor
enum AgentLogoLayerBreath {
    static let key = "omg.agentLogo.breath"

    static func setRunning(_ running: Bool, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        if running {
            if layer.animation(forKey: key) == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1.0
                animation.toValue = AgentLogoStyle.logoOpacity(breath: 0)
                animation.duration = 0.9
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: key)
            }
        } else {
            layer.removeAnimation(forKey: key)
        }
        CATransaction.commit()
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
