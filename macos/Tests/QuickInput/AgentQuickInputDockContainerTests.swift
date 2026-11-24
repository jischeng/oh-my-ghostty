import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct AgentQuickInputDockContainerTests {
    private struct MountProbe: NSViewRepresentable {
        let create: () -> NSView
        func makeNSView(context: Context) -> NSView { create() }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private final class ResizeTrackingView: NSView {
        var frameChangeCount = 0
        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { frameChangeCount += 1 }
        }
    }

    @Test(arguments: [false, true])
    func accessoriesAlwaysFloatOverFullTerminalWithZeroResize(isPinned: Bool) async throws {
        let terminal = ResizeTrackingView()
        let editor = NSTextView()
        editor.string = "draft / 草稿"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        var terminalMounts = 0
        var composerMounts = 0
        let container = AgentQuickInputDockContainer.Container()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        container.update(
            content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
            composer: AnyView(MountProbe { composerMounts += 1; return editor }),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 0,
            isPinned: isPinned
        )
        container.layoutSubtreeIfNeeded()
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(container.composerHost.layer?.shadowOpacity == 0)
        #expect(container.composerShadowLayer.shadowOpacity == 0)
        #expect(container.composerShadowLayer.isHidden)
        terminal.frameChangeCount = 0

        let insetX = AgentQuickInputMetrics.floatingHorizontalInset
        let bottomInset = AgentQuickInputMetrics.floatingBottomInset
        let spacing = AgentQuickInputMetrics.floatingStackSpacing
        let cardWidth = 800 - insetX * 2

        for (composerHeight, queueHeight) in [(148.0, 0.0), (148, 52), (0, 52), (320, 52), (0, 0)] {
            container.update(
                content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                queue: AnyView(Color.clear),
                composerHeight: composerHeight,
                queueHeight: queueHeight,
                isPinned: isPinned
            )
            #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600),
                    "Floating Quick Input and queue must never shrink contentHost regardless of isPinned")
            container.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            container.layoutSubtreeIfNeeded()
            #expect(terminalMounts == 1)
            #expect(composerMounts == 1)
            #expect(terminal.frameChangeCount == 0)
            #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))

            let expectedComposerY = composerHeight > 0 ? bottomInset : 0
            let expectedQueueY: CGFloat = if queueHeight > 0 {
                composerHeight > 0 ? (expectedComposerY + composerHeight + spacing) : bottomInset
            } else {
                0
            }
            #expect(container.composerHost.frame == NSRect(
                x: insetX,
                y: expectedComposerY,
                width: cardWidth,
                height: composerHeight
            ))
            #expect(container.queueHost.frame == NSRect(
                x: insetX,
                y: expectedQueueY,
                width: cardWidth,
                height: queueHeight
            ))
            #expect(container.composerHost.isHidden == (composerHeight == 0))
            #expect(container.queueHost.isHidden == (queueHeight == 0))
            #expect(container.composerHost.layer?.masksToBounds == false)
            #expect(container.queueHost.layer?.masksToBounds == false)
            #expect(container.composerHost.layer?.shadowOpacity == 0)
            if composerHeight > 0 {
                #expect(abs(container.composerShadowLayer.shadowOpacity - 0.30) < 0.001)
                #expect(container.composerShadowLayer.shadowRadius == 18)
                #expect(container.composerShadowLayer.shadowOffset == CGSize(width: 0, height: -5))
                #expect(container.composerShadowLayer.shadowPath != nil)
                #expect(container.composerShadowLayer.mask != nil)
                #expect(!container.composerShadowLayer.isHidden)
            } else {
                #expect(container.composerShadowLayer.shadowOpacity == 0)
                #expect(container.composerShadowLayer.isHidden)
            }
            #expect(container.subviews == [container.contentHost, container.composerHost, container.queueHost])

            // Side margins, bottom margin, and area above cards must stay unoccluded.
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 8, y: 40)))
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 792, y: 40)))
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 6)))
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 500)))
            #expect(container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 40)) == (composerHeight > 0 || queueHeight > 0))
            #expect(container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 100)) == (composerHeight > 0))
            if queueHeight > 0 {
                #expect(container.occludesContentPoint(inWindow: NSPoint(x: 100, y: expectedQueueY + 20)))
                #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 8, y: expectedQueueY + 20)))
            }
            if composerHeight > 0, queueHeight > 0 {
                #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: expectedComposerY + composerHeight + 4)))
            }
            #expect(editor.string == "draft / 草稿")
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        }
        #expect(terminal.frameChangeCount == 0)
    }

    @Test(arguments: [false, true])
    func smallWindowClampsFloatingCardsWithoutShrinkingContentHost(isPinned: Bool) {
        let container = AgentQuickInputDockContainer.Container(frame: .init(x: 0, y: 0, width: 800, height: 100))
        container.update(content: AnyView(Color.clear), composer: AnyView(Color.clear), queue: AnyView(Color.clear),
                         composerHeight: 148, queueHeight: 52, isPinned: isPinned)
        container.layoutSubtreeIfNeeded()
        // availableOverlay = 100 - 12 - min(16, 10) = 78 -> composer=78, queue=0.
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 100))
        #expect(container.composerHost.frame == NSRect(x: 16, y: 12, width: 768, height: 78))
        #expect(!container.composerHost.isHidden)
        #expect(container.queueHost.isHidden)

        container.setFrameSize(.init(width: 800, height: 240))
        container.layoutSubtreeIfNeeded()
        // availableOverlay = 240 - 12 - 16 = 212 -> composer=148, queue=52.
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 240))
        #expect(container.composerHost.frame == NSRect(x: 16, y: 12, width: 768, height: 148))
        #expect(container.queueHost.frame == NSRect(x: 16, y: 168, width: 768, height: 52))
        #expect(!container.queueHost.isHidden)

        container.setFrameSize(.init(width: 800, height: 600))
        container.layoutSubtreeIfNeeded()
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(container.composerHost.frame == NSRect(x: 16, y: 12, width: 768, height: 148))
        #expect(container.queueHost.frame == NSRect(x: 16, y: 168, width: 768, height: 52))

        container.setFrameSize(.init(width: 140, height: 600))
        container.layoutSubtreeIfNeeded()
        // insetX = min(16, (140 - 120) * 0.5) = 10 -> cardWidth = 120.
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 140, height: 600))
        #expect(container.composerHost.frame == NSRect(x: 10, y: 12, width: 120, height: 148))
        #expect(container.queueHost.frame == NSRect(x: 10, y: 168, width: 120, height: 52))
    }

    @Test func togglingPinnedKeepsIdenticalFloatingGeometry() async throws {
        let terminal = ResizeTrackingView()
        let editor = NSTextView()
        editor.string = "draft / 草稿"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        var terminalMounts = 0
        var composerMounts = 0
        let container = AgentQuickInputDockContainer.Container()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        container.update(
            content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
            composer: AnyView(MountProbe { composerMounts += 1; return editor }),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 0,
            isPinned: false
        )
        container.layoutSubtreeIfNeeded()
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.frameChangeCount = 0

        for isPinned in [false, true] {
            for (composerHeight, queueHeight) in [(148.0, 52.0), (0, 52), (0, 0), (148, 0), (300, 52)] {
                container.update(
                    content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                    composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                    queue: AnyView(Color.clear),
                    composerHeight: composerHeight,
                    queueHeight: queueHeight,
                    isPinned: isPinned
                )
                #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
                container.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                container.layoutSubtreeIfNeeded()
                #expect(terminalMounts == 1)
                #expect(composerMounts == 1)
                #expect(terminal.frameChangeCount == 0)
                #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
                #expect(abs(container.composerHost.frame.height - composerHeight) < 0.001)
                #expect(abs(container.queueHost.frame.height - queueHeight) < 0.001)
                #expect(container.composerHost.isHidden == (composerHeight == 0))
                #expect(container.queueHost.isHidden == (queueHeight == 0))
                #expect(container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 30)) == (composerHeight > 0 || queueHeight > 0))
                #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 6, y: 30)))
                #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 6)))
                #expect(editor.string == "draft / 草稿")
                #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
            }
        }
    }

    @Test func collapsedQueuePillFramesAtBottomTrailingWithoutOccludingLeadingPrompt() {
        let terminal = ResizeTrackingView()
        let container = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        container.update(
            content: AnyView(MountProbe { terminal }),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 0
        )
        container.layoutSubtreeIfNeeded()
        terminal.frameChangeCount = 0

        container.update(
            content: AnyView(MountProbe { terminal }),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: AgentQuickInputMetrics.collapsedQueueHeight,
            queueWidth: 172
        )
        container.layoutSubtreeIfNeeded()

        #expect(terminal.frameChangeCount == 0)
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(container.composerHost.isHidden)
        #expect(!container.queueHost.isHidden)
        #expect(container.queueHost.frame == NSRect(x: 612, y: 12, width: 172, height: 28))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 60, y: 20)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 500, y: 20)))
        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 680, y: 20)))
    }

    @Test func registeredPerPaneAccessoryViewOccludesOnlyItsOwnBounds() async throws {
        let container = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        container.update(
            content: AnyView(
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    Color.clear
                        .frame(width: 140, height: 28)
                        .background(FloatingAccessoryAnchor())
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 0
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        container.layoutSubtreeIfNeeded()

        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 700, y: 24)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 24)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 792, y: 24)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 700, y: 6)))

        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 0
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        container.layoutSubtreeIfNeeded()

        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 700, y: 24)))
    }

    @Test func composerAccessoryOriginPositionsStackAboveFooterWithPerCapsuleHitTestAndOutsideCollapse() async throws {
        let container = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        let capsuleStack = VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .frame(width: 180, height: 34)
                .background(FloatingAccessoryAnchor(isActive: true))
            Color.clear
                .frame(width: 280, height: 34)
                .background(FloatingAccessoryAnchor(isActive: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

        var outsideDismissCount = 0
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(capsuleStack),
            composerHeight: 148,
            queueHeight: 75,
            queueWidth: 280,
            composerAccessoryOrigin: CGPoint(x: 110, y: 38),
            onOutsideAccessoryMouseDown: { outsideDismissCount += 1 }
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        container.layoutSubtreeIfNeeded()

        // insetX = 16, composerY = 12 -> queueX = 16 + 110 = 126, queueY = 12 + 38 = 50
        #expect(container.queueHost.frame == NSRect(x: 126, y: 50, width: 280, height: 75))
        #expect(container.queueHost.hasAnchorViews)

        // Points inside bottom capsule (y = 50..84) and shorter top capsule (y = 91..125, x = 126..306) hit.
        #expect(container.queueHost.hitTest(NSPoint(x: 200, y: 67)) != nil)
        #expect(container.queueHost.hitTest(NSPoint(x: 200, y: 108)) != nil)

        // The 7pt vertical gap between active capsules inside the shared column span (y = 87, x = 200)
        // is bridged so scrolling across gaps never falls through; empty space beside the shorter
        // top capsule (x = 360, y = 108) still passes through.
        #expect(container.queueHost.hitTest(NSPoint(x: 200, y: 87)) != nil)
        #expect(container.queueHost.hitTest(NSPoint(x: 360, y: 108)) == nil)

        func mouseDown(at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }

        // Clicks inside active capsules or on the footer switch strip keep the stack open.
        _ = container.handleLocalMouseDown(try mouseDown(at: NSPoint(x: 200, y: 67)))
        _ = container.handleLocalMouseDown(try mouseDown(at: NSPoint(x: 130, y: 24)))
        #expect(outsideDismissCount == 0)

        // Clicks in the composer text area beside a capsule or out on the terminal collapse the stack.
        _ = container.handleLocalMouseDown(try mouseDown(at: NSPoint(x: 360, y: 108)))
        _ = container.handleLocalMouseDown(try mouseDown(at: NSPoint(x: 500, y: 300)))
        #expect(outsideDismissCount == 2)

        // Above-composer placement occludes active capsules and bridged gaps inside the column span.
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(capsuleStack),
            composerHeight: 148,
            queueHeight: 75,
            queueWidth: 280,
            composerAccessoryOrigin: CGPoint(x: 110, y: 156)
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        container.layoutSubtreeIfNeeded()

        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 200, y: 185)))
        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 200, y: 225)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 360, y: 225)))
        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 200, y: 205)))

        // Deactivating anchors stops occlusion and passes clicks through immediately.
        let inactiveStack = VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .frame(width: 180, height: 34)
                .background(FloatingAccessoryAnchor(isActive: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(inactiveStack),
            composerHeight: 148,
            queueHeight: 34,
            queueWidth: 180,
            composerAccessoryOrigin: CGPoint(x: 110, y: 156)
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        container.layoutSubtreeIfNeeded()

        #expect(container.queueHost.hitTest(NSPoint(x: 200, y: 185)) == nil)
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 200, y: 185)))
    }

    @Test func capsuleStackAndComposerSwallowScrollWheelEvents() async throws {
        final class ScrollSpyParentView: NSView {
            var scrollWheelCount = 0
            override func scrollWheel(with event: NSEvent) {
                scrollWheelCount += 1
            }
        }

        let spy = ScrollSpyParentView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let container = AgentQuickInputDockContainer.Container(frame: spy.bounds)
        spy.addSubview(container)
        let window = NSWindow(
            contentRect: spy.bounds,
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = spy
        defer { window.contentView = nil; window.close() }

        let capsuleStack = VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .frame(width: 220, height: 34)
                .background(FloatingAccessoryAnchor(isActive: true))
            Color.clear
                .frame(width: 220, height: 34)
                .background(FloatingAccessoryAnchor(isActive: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(capsuleStack),
            composerHeight: 148,
            queueHeight: 75,
            queueWidth: 220,
            composerAccessoryOrigin: CGPoint(x: 40, y: 38)
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        container.layoutSubtreeIfNeeded()

        // Directly deliver a CGEvent-backed scrollWheel targeted inside queueHost gap and composerHost.
        let winPointGap = NSPoint(x: 100, y: 87)
        let cgGap = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 30,
            wheel2: 0,
            wheel3: 0
        ))
        let screenPoint = window.convertPoint(toScreen: winPointGap)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? window.frame.height
        cgGap.location = CGPoint(x: screenPoint.x, y: primaryScreenHeight - screenPoint.y)
        let wheelAtGap = try #require(NSEvent(cgEvent: cgGap))

        #expect(container.queueHost.hitTest(winPointGap) != nil)
        container.queueHost.scrollWheel(with: wheelAtGap)
        container.composerHost.scrollWheel(with: wheelAtGap)
        #expect(spy.scrollWheelCount == 0)
    }

    @Test func dockedModeShrinksContentHostInFlowWithoutShadowOrOcclusion() {
        let container = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 165,
            queueHeight: 0,
            layoutMode: .dockedOrFloatingFallback
        )
        container.layoutSubtreeIfNeeded()

        #expect(container.isDocked)
        #expect(container.contentHost.frame == NSRect(x: 0, y: 165, width: 800, height: 435))
        #expect(container.composerHost.frame == NSRect(x: 0, y: 0, width: 800, height: 165))
        #expect(!container.composerHost.isHidden)
        #expect(container.composerShadowLayer.isHidden)
        #expect(container.composerShadowLayer.shadowOpacity == 0)
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 40)))

        // Closing restores full height cleanly.
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 0,
            layoutMode: .dockedOrFloatingFallback
        )
        container.layoutSubtreeIfNeeded()

        #expect(!container.isDocked)
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(container.composerHost.isHidden)
    }

    @Test func shortPaneFallsBackToFloatingOverlayWithoutShrinkingContentHost() {
        let container = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 800, height: 240)
        )
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 165,
            queueHeight: 0,
            layoutMode: .dockedOrFloatingFallback
        )
        container.layoutSubtreeIfNeeded()

        #expect(!container.isDocked)
        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 240))
        #expect(container.composerHost.frame == NSRect(x: 16, y: 12, width: 768, height: 165))
        #expect(!container.composerShadowLayer.isHidden)

        // Growing past 256pt transitions smoothly into docked in-flow mode.
        container.setFrameSize(NSSize(width: 800, height: 300))
        container.layoutSubtreeIfNeeded()

        #expect(container.isDocked)
        // Clamped to 300 - 160 (minimumTerminalHeight) = 140pt.
        #expect(container.contentHost.frame == NSRect(x: 0, y: 140, width: 800, height: 160))
        #expect(container.composerHost.frame == NSRect(x: 0, y: 0, width: 800, height: 140))
        #expect(container.composerShadowLayer.isHidden)
    }

    @Test func tabOverlayPositionsUnclippedPopoverWhenComposerLivesInPane() throws {
        let container = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        var outsideDismissCount = 0
        let footerRect = NSRect(x: 0, y: 8, width: 420, height: 28)
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(EmptyView()),
            queue: AnyView(Color.clear),
            composerHeight: 0,
            queueHeight: 120,
            queueWidth: 380,
            composerAccessoryOrigin: CGPoint(x: 80, y: 42),
            activeComposerFooterRect: footerRect,
            onOutsideAccessoryMouseDown: { outsideDismissCount += 1 },
            layoutMode: .floating
        )
        container.layoutSubtreeIfNeeded()

        #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 900, height: 600))
        #expect(container.composerHost.isHidden)
        #expect(!container.queueHost.isHidden)
        #expect(container.queueHost.frame == NSRect(x: 80, y: 42, width: 380, height: 120))

        func mouseDown(at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }

        // Clicking the docked pane's footer toggle strip must not dismiss the tab-level popover.
        _ = container.handleLocalMouseDown(try mouseDown(at: NSPoint(x: 100, y: 20)))
        #expect(outsideDismissCount == 0)

        // Clicking outside dismisses the popover.
        _ = container.handleLocalMouseDown(try mouseDown(at: NSPoint(x: 650, y: 300)))
        #expect(outsideDismissCount == 1)
    }

    @Test func visualDockResizeStateSuppressesPTYCommitOnOpenDragAndClose() {
        var state = SurfaceCoreResizeState()
        let outer = CGSize(width: 800, height: 600)

        // Initial mount commits normally to PTY.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 0)
        #expect(state.request(outer) == .normal(outer))

        // Opening docked Quick Input shrinks visually with zero PTY commit.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 165)
        #expect(state.request(CGSize(width: 800, height: 435)) == .visualOnly(CGSize(width: 800, height: 435)))
        #expect(!state.hasUncommittedLiveSize)
        #expect(state.commitLiveSizeIfNeeded() == nil)

        // Dragging Quick Input height stays visual-only.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 220)
        #expect(state.request(CGSize(width: 800, height: 380)) == .visualOnly(CGSize(width: 800, height: 380)))
        #expect(!state.hasUncommittedLiveSize)

        // Closing Quick Input restores original height visually with zero PTY commit.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 0)
        #expect(state.request(outer) == .visualOnly(outer))
        #expect(!state.hasUncommittedLiveSize)

        // Genuinely resizing the window/split while docked commits to the PTY.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 165)
        #expect(state.request(CGSize(width: 800, height: 435)) == .visualOnly(CGSize(width: 800, height: 435)))

        let resizedOuter = CGSize(width: 600, height: 600)
        state.setVisualDockContext(outerSize: resizedOuter, dockedHeight: 165)
        #expect(state.request(CGSize(width: 600, height: 435)) == .normal(CGSize(width: 600, height: 435)))

        // Closing after a genuine outer resize commits the restored full pane size.
        state.setVisualDockContext(outerSize: resizedOuter, dockedHeight: 0)
        #expect(state.request(resizedOuter) == .normal(resizedOuter))

        // Width change inside the same outer pane (e.g. in-pane inspector/editor) must NOT stay visual-only.
        state.setVisualDockContext(outerSize: resizedOuter, dockedHeight: 165)
        #expect(state.request(CGSize(width: 600, height: 435)) == .visualOnly(CGSize(width: 600, height: 435)))
        #expect(state.request(CGSize(width: 380, height: 435)) == .normal(CGSize(width: 380, height: 435)))

        // During-drag live resize returning to committedSize still refreshes committedOuterSize.
        var dragState = SurfaceCoreResizeState()
        dragState.setVisualDockContext(outerSize: CGSize(width: 800, height: 600), dockedHeight: 0)
        #expect(dragState.request(CGSize(width: 800, height: 600)) == .normal(CGSize(width: 800, height: 600)))
        dragState.beginInteraction(mode: .duringDrag)
        dragState.setVisualDockContext(outerSize: CGSize(width: 800, height: 765), dockedHeight: 165)
        #expect(dragState.request(CGSize(width: 800, height: 600)) == nil)
        dragState.setVisualDockContext(outerSize: CGSize(width: 800, height: 700), dockedHeight: 165)
        #expect(dragState.request(CGSize(width: 800, height: 535)) == .live(CGSize(width: 800, height: 535)))
        dragState.setVisualDockContext(outerSize: CGSize(width: 800, height: 765), dockedHeight: 165)
        #expect(dragState.request(CGSize(width: 800, height: 600)) == .live(CGSize(width: 800, height: 600)))
        #expect(dragState.endInteraction() == nil)
        // Subsequent dock height drag inside the new outerSize stays visual-only.
        dragState.setVisualDockContext(outerSize: CGSize(width: 800, height: 765), dockedHeight: 200)
        #expect(dragState.request(CGSize(width: 800, height: 565)) == .visualOnly(CGSize(width: 800, height: 565)))
    }

    @Test func alternateScreenDockCommitsPTYResizeOnOpenDragAndClose() {
        var state = SurfaceCoreResizeState()
        let outer = CGSize(width: 800, height: 600)

        state.setVisualDockContext(outerSize: outer, dockedHeight: 0)
        #expect(state.request(outer, allowsVisualOnlyDock: false) == .normal(outer))

        // Opening docked Quick Input on alternate screen commits so the TUI reflows.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 165)
        #expect(
            state.request(CGSize(width: 800, height: 435), allowsVisualOnlyDock: false)
                == .normal(CGSize(width: 800, height: 435))
        )

        // Dragging Quick Input height on alternate screen also commits.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 220)
        #expect(
            state.request(CGSize(width: 800, height: 380), allowsVisualOnlyDock: false)
                == .normal(CGSize(width: 800, height: 380))
        )

        // Closing Quick Input restores full pane height via .normal so no blank bottom gap remains.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 0)
        #expect(state.request(outer, allowsVisualOnlyDock: false) == .normal(outer))

        // Opening on alternate screen, exiting to primary screen, then closing must still commit
        // the restored full height because committedSize was shrunk while on alternate screen.
        state.setVisualDockContext(outerSize: outer, dockedHeight: 165)
        #expect(
            state.request(CGSize(width: 800, height: 435), allowsVisualOnlyDock: false)
                == .normal(CGSize(width: 800, height: 435))
        )
        state.setVisualDockContext(outerSize: outer, dockedHeight: 0)
        #expect(state.request(outer, allowsVisualOnlyDock: true) == .normal(outer))
    }

    @Test func tabOverlayFrameProbeConvertsNestedRightSplitCoordinatesToOutermostContainer() async throws {
        let outerTabContainer = AgentQuickInputDockContainer.Container(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = outerTabContainer
        defer { window.contentView = nil; window.close() }

        var reportedRect: NSRect?
        let innerSplitContainer = HStack(spacing: 0) {
            Color.clear.frame(width: 450, height: 600)
            AgentQuickInputDockContainer(
                content: AnyView(Color.clear),
                composer: AnyView(
                    VStack {
                        Spacer()
                        HStack {
                            Spacer().frame(width: 50)
                            Color.clear
                                .frame(width: 28, height: 24)
                                .background(
                                    QuickInputTabOverlayFrameProbe(isActive: true) { rect in
                                        reportedRect = rect
                                    }
                                )
                            Spacer()
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ),
                queue: AnyView(EmptyView()),
                composerHeight: 165,
                queueHeight: 0,
                layoutMode: .dockedOrFloatingFallback
            )
            .frame(width: 450, height: 600)
        }

        outerTabContainer.update(
            content: AnyView(innerSplitContainer),
            composer: AnyView(EmptyView()),
            queue: AnyView(EmptyView()),
            composerHeight: 0,
            queueHeight: 0,
            layoutMode: .floating
        )
        outerTabContainer.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        outerTabContainer.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        let rect = try #require(reportedRect)
        // Right pane starts at x=450, button has 50pt leading spacer -> x ≈ 500, y ≈ 8 in AppKit coordinates.
        #expect(abs(rect.minX - 500) < 2)
        #expect(abs(rect.minY - 8) < 2)
        #expect(abs(rect.width - 28) < 2)
        #expect(abs(rect.height - 24) < 2)
    }

    @Test func focusRequestIDZeroDoesNotStealFocusAfterPriorFocusHandled() async throws {
        var draft = ""
        let binding = Binding<String>(get: { draft }, set: { draft = $0 })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let external = NSTextField(frame: NSRect(x: 0, y: 150, width: 100, height: 24))
        root.addSubview(external)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        let host = NSHostingView(rootView: AgentQuickInputTextEditor(
            text: binding,
            placeholder: "test",
            isPresented: true,
            focusRequestID: 1,
            font: .systemFont(ofSize: 13),
            onPasteImage: nil,
            onSend: {},
            onQueue: {},
            onCancel: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        root.addSubview(host)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        #expect(window.firstResponder is ComposerTextView)

        // Move focus away to external control, then update with focusRequestID == 0 (non-focusing switch back).
        #expect(window.makeFirstResponder(external))
        host.rootView = AgentQuickInputTextEditor(
            text: binding,
            placeholder: "test",
            isPresented: true,
            focusRequestID: 0,
            font: .systemFont(ofSize: 13),
            onPasteImage: nil,
            onSend: {},
            onQueue: {},
            onCancel: {}
        )
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!(window.firstResponder is ComposerTextView))
    }

    @Test func footerLayoutModeCompactsAtNarrowSplitWidths() {
        #expect(QuickInputFooterLayoutMode.resolve(width: 520) == .regular)
        #expect(QuickInputFooterLayoutMode.resolve(width: 460) == .regular)
        #expect(QuickInputFooterLayoutMode.resolve(width: 459) == .compact)
        #expect(QuickInputFooterLayoutMode.resolve(width: 340) == .compact)
        #expect(QuickInputFooterLayoutMode.resolve(width: 339) == .iconOnly)
        #expect(QuickInputFooterLayoutMode.regular.showsSecondaryActionTitles)
        #expect(!QuickInputFooterLayoutMode.compact.showsSecondaryActionTitles)
        #expect(QuickInputFooterLayoutMode.compact.showsPrimaryActionTitle)
        #expect(!QuickInputFooterLayoutMode.iconOnly.showsPrimaryActionTitle)
    }
}
