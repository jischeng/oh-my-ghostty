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
            if composerHeight > 0 {
                #expect(abs((container.composerHost.layer?.shadowOpacity ?? 0) - 0.28) < 0.001)
                #expect(container.composerHost.layer?.shadowRadius == 16)
                #expect(container.composerHost.layer?.shadowOffset == CGSize(width: 0, height: -4))
                #expect(container.composerHost.layer?.shadowPath != nil)
            } else {
                #expect(container.composerHost.layer?.shadowOpacity == 0)
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
}
