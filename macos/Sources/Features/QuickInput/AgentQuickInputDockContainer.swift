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

    final class CapsuleStackHostingView: NSHostingView<AnyView> {
        var hasAnchorViews: Bool {
            !anchorViews(in: self).isEmpty
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let anchors = anchorViews(in: self)
            guard !anchors.isEmpty else {
                return super.hitTest(point)
            }
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            let hitsActiveAnchor = anchors.contains { anchor in
                anchor.containsActivePoint(anchor.convert(localPoint, from: self))
            }
            guard hitsActiveAnchor else { return nil }
            return super.hitTest(point)
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
        let composerHost = NSHostingView(rootView: AnyView(EmptyView()))
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
            if !queueHost.isHidden, !queueHost.hasAnchorViews, queueHost.frame.contains(local) {
                return true
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

        private func enclosingDockContainer() -> AgentQuickInputDockContainer.Container? {
            var current = superview
            while let view = current {
                if let container = view as? AgentQuickInputDockContainer.Container {
                    return container
                }
                current = view.superview
            }
            return nil
        }
    }
}
