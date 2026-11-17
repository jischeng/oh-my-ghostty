import AppKit
import SwiftUI

protocol FloatingAccessoryOcclusionContainer: AnyObject {
    func occludesContentPoint(inWindow pointInWindow: NSPoint) -> Bool
}

/// The terminal and accessories have one native geometry owner. Hosting views
/// render leaves only; none of their intrinsic sizes can resize this container.
struct AgentQuickInputDockContainer: NSViewRepresentable {
    let content: AnyView
    let composer: AnyView
    let queue: AnyView
    let composerHeight: CGFloat
    let queueHeight: CGFloat
    var queueWidth: CGFloat?
    var composerAccessoryOrigin: CGPoint?
    var onOutsideAccessoryMouseDown: (() -> Void)?
    var isPinned: Bool = false

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ view: Container, context: Context) {
        view.update(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            queue: AnyView(queue.environment(\.self, context.environment)),
            composerHeight: composerHeight,
            queueHeight: queueHeight,
            queueWidth: queueWidth,
            composerAccessoryOrigin: composerAccessoryOrigin,
            onOutsideAccessoryMouseDown: onOutsideAccessoryMouseDown,
            isPinned: isPinned
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class ComposerHostingView: NSHostingView<AnyView> {
        override func scrollWheel(with event: NSEvent) {
            // Swallow scroll events over Quick Input chrome so unhandled wheel deltas
            // cannot propagate through to the background terminal surface.
        }
    }

    final class CapsuleStackHostingView: NSHostingView<AnyView> {
        private var isForwardingScrollWheel = false

        var hasAnchorViews: Bool {
            !anchorViews(in: self).isEmpty
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            let anchors = anchorViews(in: self)
            guard !anchors.isEmpty else {
                return super.hitTest(point)
            }
            guard containsActiveColumnPoint(localPoint, anchors: anchors) else { return nil }
            if let hit = super.hitTest(point) {
                return hit
            }
            if let scrollView = descendantScrollView(),
               !scrollView.isHiddenOrHasHiddenAncestor {
                let pointInScroll = scrollView.convert(localPoint, from: self)
                if scrollView.bounds.contains(pointInScroll) {
                    let pointInScrollSuper = scrollView.superview?.convert(localPoint, from: self) ?? pointInScroll
                    return scrollView.hitTest(pointInScrollSuper) ?? scrollView
                }
            }
            return self
        }

        override func scrollWheel(with event: NSEvent) {
            guard !isForwardingScrollWheel else { return }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard containsActiveColumnPoint(localPoint) else {
                super.scrollWheel(with: event)
                return
            }
            if let scrollView = descendantScrollView(),
               !scrollView.isHiddenOrHasHiddenAncestor {
                let pointInScroll = scrollView.convert(event.locationInWindow, from: nil)
                if !scrollView.bounds.contains(pointInScroll) {
                    isForwardingScrollWheel = true
                    defer { isForwardingScrollWheel = false }
                    scrollView.scrollWheel(with: event)
                }
            }
            // Swallow scroll events inside active capsule stacks so they never leak
            // to the underlying composer or terminal surface.
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if anchorViews(in: self).contains(where: { $0.isActive && !$0.isHiddenOrHasHiddenAncestor }) {
                addCursorRect(bounds, cursor: .arrow)
            }
        }

        func containsActiveColumnPoint(_ localPoint: NSPoint) -> Bool {
            containsActiveColumnPoint(localPoint, anchors: anchorViews(in: self))
        }

        private func containsActiveColumnPoint(
            _ localPoint: NSPoint,
            anchors: [FloatingAccessoryAnchor.AnchorView]
        ) -> Bool {
            guard bounds.contains(localPoint) else { return false }
            guard !anchors.isEmpty else { return true }

            var activeRects: [NSRect] = []
            var clippedScrollRects: [NSRect] = []
            for anchor in anchors where anchor.isActive && !anchor.isHiddenOrHasHiddenAncestor {
                let rectInHost = convert(anchor.bounds, from: anchor)
                if let clipView = anchor.enclosingScrollView?.contentView {
                    let clipInHost = convert(clipView.bounds, from: clipView)
                    let clipped = rectInHost.intersection(clipInHost)
                    guard !clipped.isNull, clipped.width > 0.5, clipped.height > 0.5 else { continue }
                    activeRects.append(clipped)
                    clippedScrollRects.append(clipped)
                } else {
                    guard rectInHost.width > 0.5, rectInHost.height > 0.5 else { continue }
                    activeRects.append(rectInHost)
                }
            }

            guard !activeRects.isEmpty else { return false }
            if activeRects.contains(where: { $0.contains(localPoint) }) {
                return true
            }

            let hasAbove = activeRects.contains { rect in
                localPoint.x >= rect.minX && localPoint.x <= rect.maxX && rect.minY >= localPoint.y
            }
            let hasBelow = activeRects.contains { rect in
                localPoint.x >= rect.minX && localPoint.x <= rect.maxX && rect.maxY <= localPoint.y
            }
            if hasAbove && hasBelow {
                return true
            }

            if let scrollView = descendantScrollView(),
               !scrollView.isHiddenOrHasHiddenAncestor {
                let scrollClipRect = convert(scrollView.contentView.bounds, from: scrollView.contentView)
                if scrollClipRect.contains(localPoint) {
                    let horizontalRects = clippedScrollRects.isEmpty ? activeRects : clippedScrollRects
                    if let minX = horizontalRects.map(\.minX).min(),
                       let maxX = horizontalRects.map(\.maxX).max(),
                       localPoint.x >= minX, localPoint.x <= maxX {
                        return true
                    }
                }
            }
            return false
        }

        private func anchorViews(in view: NSView) -> [FloatingAccessoryAnchor.AnchorView] {
            var result: [FloatingAccessoryAnchor.AnchorView] = []
            for subview in view.subviews {
                if let anchor = subview as? FloatingAccessoryAnchor.AnchorView {
                    result.append(anchor)
                } else {
                    result.append(contentsOf: anchorViews(in: subview))
                }
            }
            return result
        }
    }

    final class Container: NSView, FloatingAccessoryOcclusionContainer {
        let contentHost = NSHostingView(rootView: AnyView(EmptyView()))
        let composerHost = ComposerHostingView(rootView: AnyView(EmptyView()))
        let queueHost = CapsuleStackHostingView(rootView: AnyView(EmptyView()))
        let composerShadowLayer = CALayer()
        private var requestedComposerHeight: CGFloat = 0
        private var requestedQueueHeight: CGFloat = 0
        private var requestedQueueWidth: CGFloat?
        private var requestedComposerAccessoryOrigin: CGPoint?
        private var onOutsideAccessoryMouseDown: (() -> Void)?
        private var mouseDownMonitor: Any?
        private(set) var isPinned: Bool = false
        private let floatingAccessoryViews = NSHashTable<NSView>.weakObjects()

        deinit {
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMouseDownMonitor()
        }

        private func updateMouseDownMonitor() {
            if window == nil {
                if let mouseDownMonitor {
                    NSEvent.removeMonitor(mouseDownMonitor)
                    self.mouseDownMonitor = nil
                }
                return
            }
            guard mouseDownMonitor == nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                self?.handleLocalMouseDown(event) ?? event
            }
        }

        @discardableResult
        func handleLocalMouseDown(_ event: NSEvent) -> NSEvent {
            guard let window, event.window === window,
                  !queueHost.isHidden,
                  let onOutsideAccessoryMouseDown else {
                return event
            }
            let pt = convert(event.locationInWindow, from: nil)
            if queueHost.hitTest(pt) != nil {
                return event
            }
            if !composerHost.isHidden,
               composerHost.frame.contains(pt),
               pt.y < composerHost.frame.minY + 36 {
                return event
            }
            onOutsideAccessoryMouseDown()
            return event
        }

        func registerFloatingAccessoryView(_ view: NSView) {
            floatingAccessoryViews.add(view)
        }

        func unregisterFloatingAccessoryView(_ view: NSView) {
            floatingAccessoryViews.remove(view)
        }

        func occludesContentPoint(inWindow pointInWindow: NSPoint) -> Bool {
            let local = convert(pointInWindow, from: nil)
            if !composerHost.isHidden, composerHost.frame.contains(local) {
                return true
            }
            if !queueHost.isHidden {
                let queueLocal = queueHost.convert(pointInWindow, from: nil)
                if queueHost.containsActiveColumnPoint(queueLocal) {
                    return true
                }
            }
            if let window = self.window {
                for accessory in floatingAccessoryViews.allObjects
                where !accessory.isHiddenOrHasHiddenAncestor && accessory.window === window {
                    let accessoryPoint = accessory.convert(pointInWindow, from: nil)
                    if let anchor = accessory as? FloatingAccessoryAnchor.AnchorView {
                        if anchor.containsActivePoint(accessoryPoint) {
                            return true
                        }
                    } else if accessory.bounds.contains(accessoryPoint) {
                        return true
                    }
                }
            }
            return false
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            for host in [contentHost, composerHost, queueHost] {
                host.wantsLayer = true
                host.sizingOptions = []
                addSubview(host)
            }
            composerShadowLayer.backgroundColor = NSColor.clear.cgColor
            composerShadowLayer.isOpaque = false
            composerShadowLayer.isHidden = true
            if let containerLayer = layer, let composerLayer = composerHost.layer {
                containerLayer.insertSublayer(composerShadowLayer, below: composerLayer)
            }
            configureOverlayLayers(composerVisible: false)
            composerHost.isHidden = true
            queueHost.isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(
            content: AnyView,
            composer: AnyView,
            queue: AnyView,
            composerHeight: CGFloat,
            queueHeight: CGFloat,
            queueWidth: CGFloat? = nil,
            composerAccessoryOrigin: CGPoint? = nil,
            onOutsideAccessoryMouseDown: (() -> Void)? = nil,
            isPinned: Bool = false
        ) {
            requestedComposerHeight = max(0, composerHeight)
            requestedQueueHeight = max(0, queueHeight)
            requestedQueueWidth = queueWidth.map { max(0, $0) }
            requestedComposerAccessoryOrigin = composerAccessoryOrigin
            self.onOutsideAccessoryMouseDown = onOutsideAccessoryMouseDown
            self.isPinned = isPinned
            applyAccessoryFrames()
            // Preserve the Surface and ComposerTextView instances, including
            // first responder, selection, marked text and scrollback state.
            contentHost.rootView = content
            composerHost.rootView = composer
            queueHost.rootView = queue
        }

        override func layout() {
            applyAccessoryFrames()
            super.layout()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            applyAccessoryFrames()
        }

        private func applyAccessoryFrames() {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                let safeWidth = bounds.width
                let safeHeight = max(0, bounds.height)
                let contentFrame = NSRect(x: 0, y: 0, width: safeWidth, height: safeHeight)

                let insetX = min(
                    AgentQuickInputMetrics.floatingHorizontalInset,
                    max(0, (safeWidth - 120) * 0.5)
                )
                let cardWidth = max(0, safeWidth - insetX * 2)
                let topMargin = min(AgentQuickInputMetrics.floatingTopMargin, safeHeight * 0.1)
                let availableOverlay = max(
                    0,
                    safeHeight - AgentQuickInputMetrics.floatingBottomInset - topMargin
                )

                let nextComposerHeight = cardWidth > 0
                    ? min(requestedComposerHeight, availableOverlay)
                    : 0
                let composerY = nextComposerHeight > 0
                    ? min(AgentQuickInputMetrics.floatingBottomInset, max(0, safeHeight - nextComposerHeight))
                    : 0
                let composerFrame = NSRect(
                    x: insetX,
                    y: composerY,
                    width: cardWidth,
                    height: nextComposerHeight
                )

                let nextQueueHeight: CGFloat
                let queueFrame: NSRect
                if nextComposerHeight > 0, requestedQueueHeight > 0, let origin = requestedComposerAccessoryOrigin {
                    let rawY = composerFrame.minY + origin.y
                    nextQueueHeight = cardWidth > 0
                        ? min(requestedQueueHeight, max(0, safeHeight - topMargin - rawY))
                        : 0
                    let resolvedWidth = min(cardWidth, requestedQueueWidth ?? cardWidth)
                    let minQueueX = insetX
                    let maxQueueX = max(insetX, safeWidth - insetX - resolvedWidth)
                    let queueX = min(max(minQueueX, composerFrame.minX + origin.x), maxQueueX)
                    queueFrame = NSRect(
                        x: queueX,
                        y: nextQueueHeight > 0 ? rawY : 0,
                        width: resolvedWidth,
                        height: nextQueueHeight
                    )
                } else {
                    let stackGap = nextComposerHeight > 0
                        ? AgentQuickInputMetrics.floatingStackSpacing
                        : 0
                    let remainingForQueue = max(0, availableOverlay - nextComposerHeight - stackGap)
                    nextQueueHeight = cardWidth > 0
                        ? min(requestedQueueHeight, remainingForQueue)
                        : 0
                    let queueY: CGFloat = if nextQueueHeight > 0 {
                        nextComposerHeight > 0
                            ? composerY + nextComposerHeight + AgentQuickInputMetrics.floatingStackSpacing
                            : min(AgentQuickInputMetrics.floatingBottomInset, max(0, safeHeight - nextQueueHeight))
                    } else {
                        0
                    }
                    if nextQueueHeight > 0,
                       nextComposerHeight == 0,
                       let requestedQueueWidth {
                        let resolvedWidth = min(cardWidth, requestedQueueWidth)
                        let queueX = max(insetX, safeWidth - insetX - resolvedWidth)
                        queueFrame = NSRect(x: queueX, y: queueY, width: resolvedWidth, height: nextQueueHeight)
                    } else {
                        queueFrame = NSRect(x: insetX, y: queueY, width: cardWidth, height: nextQueueHeight)
                    }
                }

                let frames: [(NSView, NSRect)] = [
                    (contentHost, contentFrame),
                    (composerHost, composerFrame),
                    (queueHost, queueFrame)
                ]
                for (host, frame) in frames where host.frame != frame { host.frame = frame }
                if composerHost.isHidden != (nextComposerHeight == 0) {
                    composerHost.isHidden = nextComposerHeight == 0
                }
                if queueHost.isHidden != (nextQueueHeight == 0) {
                    queueHost.isHidden = nextQueueHeight == 0
                }
                configureOverlayLayers(composerVisible: nextComposerHeight > 0)
            }
        }

        private func configureOverlayLayers(composerVisible: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            for host in [composerHost, queueHost] {
                host.wantsLayer = true
                host.layer?.masksToBounds = false
                host.layer?.backgroundColor = NSColor.clear.cgColor
            }
            // Keep composerHost completely unmasked and shadow-free so an
            // in-window NSVisualEffectView samples underlying layers cleanly.
            composerHost.layer?.shadowOpacity = 0
            composerHost.layer?.shadowPath = nil
            composerHost.layer?.mask = nil

            if composerShadowLayer.superlayer == nil,
               let containerLayer = layer,
               let composerLayer = composerHost.layer {
                containerLayer.insertSublayer(composerShadowLayer, below: composerLayer)
            }

            if composerVisible, !composerHost.bounds.isEmpty {
                let pad: CGFloat = 44
                composerShadowLayer.frame = composerHost.frame.insetBy(dx: -pad, dy: -pad)
                let localCard = CGRect(
                    x: pad,
                    y: pad,
                    width: composerHost.bounds.width,
                    height: composerHost.bounds.height
                )
                let cardPath = CGPath(
                    roundedRect: localCard,
                    cornerWidth: AgentQuickInputMetrics.cardCornerRadius,
                    cornerHeight: AgentQuickInputMetrics.cardCornerRadius,
                    transform: nil
                )
                composerShadowLayer.shadowColor = NSColor.black.cgColor
                composerShadowLayer.shadowOpacity = 0.30
                composerShadowLayer.shadowRadius = 18
                composerShadowLayer.shadowOffset = CGSize(width: 0, height: -5)
                composerShadowLayer.shadowPath = cardPath
                composerShadowLayer.isHidden = false

                let maskPath = CGMutablePath()
                maskPath.addRect(composerShadowLayer.bounds)
                maskPath.addPath(cardPath)
                let maskLayer = (composerShadowLayer.mask as? CAShapeLayer) ?? CAShapeLayer()
                maskLayer.frame = composerShadowLayer.bounds
                maskLayer.fillRule = .evenOdd
                maskLayer.path = maskPath
                composerShadowLayer.mask = maskLayer
            } else {
                composerShadowLayer.shadowOpacity = 0
                composerShadowLayer.shadowPath = nil
                composerShadowLayer.mask = nil
                composerShadowLayer.isHidden = true
            }
        }
    }
}

/// Registers an overlaid per-pane floating badge with the enclosing dock
/// container so terminal hover/link hints stay suppressed underneath it.
struct FloatingAccessoryAnchor: NSViewRepresentable {
    var isActive: Bool = true

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.isActive = isActive
        view.syncRegistration()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.unregister()
    }

    final class AnchorView: NSView {
        private weak var registeredContainer: AgentQuickInputDockContainer.Container?
        var isActive: Bool = true {
            didSet {
                guard isActive != oldValue else { return }
                syncRegistration()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func containsActivePoint(_ pointInAnchor: NSPoint) -> Bool {
            guard isActive, !isHiddenOrHasHiddenAncestor, bounds.contains(pointInAnchor) else {
                return false
            }
            if let clipView = enclosingScrollView?.contentView {
                return clipView.bounds.contains(convert(pointInAnchor, to: clipView))
            }
            return true
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            syncRegistration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncRegistration()
        }

        func syncRegistration() {
            let container = enclosingDockContainer()
            guard isActive else {
                registeredContainer?.unregisterFloatingAccessoryView(self)
                container?.unregisterFloatingAccessoryView(self)
                registeredContainer = container
                return
            }
            if registeredContainer !== container {
                registeredContainer?.unregisterFloatingAccessoryView(self)
                registeredContainer = container
            }
            container?.registerFloatingAccessoryView(self)
        }

        func unregister() {
            registeredContainer?.unregisterFloatingAccessoryView(self)
            registeredContainer = nil
        }
    }
}

/// Bridges inter-capsule gaps in standalone floating stacks (such as the per-pane
/// bottom-right Queue overlay) so wheel events and cursors stay out of the terminal.
struct QuickInputScrollTrapBackground: NSViewRepresentable {
    var isActive: Bool = true

    func makeNSView(context: Context) -> TrapView {
        let view = TrapView()
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: TrapView, context: Context) {
        view.isActive = isActive
        view.syncRegistration()
    }

    static func dismantleNSView(_ view: TrapView, coordinator: ()) {
        view.unregister()
    }

    final class TrapView: NSView {
        private weak var registeredContainer: AgentQuickInputDockContainer.Container?
        private var isForwardingScrollWheel = false
        var isActive: Bool = true {
            didSet {
                guard isActive != oldValue else { return }
                syncRegistration()
                window?.invalidateCursorRects(for: self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isActive, !isHiddenOrHasHiddenAncestor else { return nil }
            let localPoint = convert(point, from: superview)
            return bounds.contains(localPoint) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            guard isActive else {
                super.scrollWheel(with: event)
                return
            }
            guard !isForwardingScrollWheel else { return }
            if let root = superview?.superview,
               let scrollView = root.descendantScrollView(),
               !scrollView.isHiddenOrHasHiddenAncestor {
                let pointInScroll = scrollView.convert(event.locationInWindow, from: nil)
                if !scrollView.bounds.contains(pointInScroll) {
                    isForwardingScrollWheel = true
                    defer { isForwardingScrollWheel = false }
                    scrollView.scrollWheel(with: event)
                }
            }
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if isActive {
                addCursorRect(bounds, cursor: .arrow)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            syncRegistration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncRegistration()
        }

        func syncRegistration() {
            let container = enclosingDockContainer()
            guard isActive else {
                registeredContainer?.unregisterFloatingAccessoryView(self)
                container?.unregisterFloatingAccessoryView(self)
                registeredContainer = container
                return
            }
            if registeredContainer !== container {
                registeredContainer?.unregisterFloatingAccessoryView(self)
                registeredContainer = container
            }
            container?.registerFloatingAccessoryView(self)
        }

        func unregister() {
            registeredContainer?.unregisterFloatingAccessoryView(self)
            registeredContainer = nil
        }
    }
}

private extension NSView {
    func enclosingDockContainer() -> AgentQuickInputDockContainer.Container? {
        var current = superview
        while let view = current {
            if let container = view as? AgentQuickInputDockContainer.Container {
                return container
            }
            current = view.superview
        }
        return nil
    }

    func descendantScrollView() -> NSScrollView? {
        if let scrollView = self as? NSScrollView {
            return scrollView
        }
        for subview in subviews {
            if let found = subview.descendantScrollView() {
                return found
            }
        }
        return nil
    }
}
