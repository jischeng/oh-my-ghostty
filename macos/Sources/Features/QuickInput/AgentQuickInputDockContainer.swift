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
            isPinned: isPinned
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class Container: NSView, FloatingAccessoryOcclusionContainer {
        let contentHost = NSHostingView(rootView: AnyView(EmptyView()))
        let composerHost = NSHostingView(rootView: AnyView(EmptyView()))
        let queueHost = NSHostingView(rootView: AnyView(EmptyView()))
        private var requestedComposerHeight: CGFloat = 0
        private var requestedQueueHeight: CGFloat = 0
        private var requestedQueueWidth: CGFloat?
        private(set) var isPinned: Bool = false

        func occludesContentPoint(inWindow pointInWindow: NSPoint) -> Bool {
            let local = convert(pointInWindow, from: nil)
            if !composerHost.isHidden, composerHost.frame.contains(local) {
                return true
            }
            if !queueHost.isHidden, queueHost.frame.contains(local) {
                return true
            }
            return false
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            for host in [contentHost, composerHost, queueHost] {
                host.sizingOptions = []
                addSubview(host)
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
            isPinned: Bool = false
        ) {
            requestedComposerHeight = max(0, composerHeight)
            requestedQueueHeight = max(0, queueHeight)
            requestedQueueWidth = queueWidth.map { max(0, $0) }
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
                let stackGap = nextComposerHeight > 0
                    ? AgentQuickInputMetrics.floatingStackSpacing
                    : 0
                let remainingForQueue = max(0, availableOverlay - nextComposerHeight - stackGap)
                let nextQueueHeight = cardWidth > 0
                    ? min(requestedQueueHeight, remainingForQueue)
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
                let queueY: CGFloat = if nextQueueHeight > 0 {
                    nextComposerHeight > 0
                        ? composerY + nextComposerHeight + AgentQuickInputMetrics.floatingStackSpacing
                        : min(AgentQuickInputMetrics.floatingBottomInset, max(0, safeHeight - nextQueueHeight))
                } else {
                    0
                }
                let queueFrame: NSRect
                if nextQueueHeight > 0,
                   nextComposerHeight == 0,
                   let requestedQueueWidth {
                    let resolvedWidth = min(cardWidth, requestedQueueWidth)
                    let queueX = max(insetX, safeWidth - insetX - resolvedWidth)
                    queueFrame = NSRect(x: queueX, y: queueY, width: resolvedWidth, height: nextQueueHeight)
                } else {
                    queueFrame = NSRect(x: insetX, y: queueY, width: cardWidth, height: nextQueueHeight)
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
            for host in [composerHost, queueHost] {
                host.wantsLayer = true
                host.layer?.masksToBounds = false
                host.layer?.backgroundColor = NSColor.clear.cgColor
            }
            guard let layer = composerHost.layer else { return }
            if composerVisible, !composerHost.bounds.isEmpty {
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = 0.34
                layer.shadowRadius = 18
                layer.shadowOffset = CGSize(width: 0, height: -5)
                layer.shadowPath = CGPath(
                    roundedRect: composerHost.bounds,
                    cornerWidth: AgentQuickInputMetrics.cardCornerRadius,
                    cornerHeight: AgentQuickInputMetrics.cardCornerRadius,
                    transform: nil
                )
            } else {
                layer.shadowOpacity = 0
                layer.shadowPath = nil
            }
        }
    }
}
