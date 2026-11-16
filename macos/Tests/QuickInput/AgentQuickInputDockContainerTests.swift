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
    func accessoriesAlwaysDockInFlowWithoutOccludingTerminal(isPinned: Bool) async throws {
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
        terminal.frameChangeCount = 0

        for (composerHeight, queueHeight) in [(149.0, 0.0), (149, 61), (0, 61), (320, 61), (0, 0)] {
            container.update(
                content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                queue: AnyView(Color.clear),
                composerHeight: composerHeight,
                queueHeight: queueHeight,
                isPinned: isPinned
            )
            let expectedContentHeight = 600 - composerHeight - queueHeight
            #expect(abs(container.contentHost.frame.height - expectedContentHeight) < 0.001,
                    "Quick Input and queue bar must always split in-flow regardless of isPinned")
            #expect(abs(container.contentHost.frame.origin.y - (composerHeight + queueHeight)) < 0.001)
            container.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            container.layoutSubtreeIfNeeded()
            #expect(terminalMounts == 1)
            #expect(composerMounts == 1)
            #expect(abs(container.contentHost.frame.height - expectedContentHeight) < 0.001)
            #expect(container.composerHost.frame == NSRect(x: 0, y: queueHeight, width: 800, height: composerHeight))
            #expect(container.queueHost.frame == NSRect(x: 0, y: 0, width: 800, height: queueHeight))
            #expect(container.composerHost.isHidden == (composerHeight == 0))
            #expect(container.queueHost.isHidden == (queueHeight == 0))
            #expect(container.subviews == [container.contentHost, container.composerHost, container.queueHost])
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 30)))
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 120)))
            #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 300)))
            #expect(editor.string == "draft / 草稿")
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        }
        #expect(terminal.frameChangeCount > 0)
    }

    @Test(arguments: [false, true])
    func smallWindowReservesMinimumTerminalFloorAndRestoresHeightsOnResize(isPinned: Bool) {
        let container = AgentQuickInputDockContainer.Container(frame: .init(x: 0, y: 0, width: 800, height: 100))
        container.update(content: AnyView(Color.clear), composer: AnyView(Color.clear), queue: AnyView(Color.clear),
                         composerHeight: 149, queueHeight: 61, isPinned: isPinned)
        container.layoutSubtreeIfNeeded()
        // minContentHeight = min(160, 100 * 0.5) = 50 -> availableAccessory = 50.
        #expect(abs(container.contentHost.frame.height - 50) < 0.001)
        #expect(abs(container.queueHost.frame.height - 50) < 0.001)
        #expect(abs(container.composerHost.frame.height - 0) < 0.001)
        #expect(container.composerHost.isHidden)

        container.setFrameSize(.init(width: 800, height: 240))
        container.layoutSubtreeIfNeeded()
        // minContentHeight = min(160, 240 * 0.5) = 120 -> availableAccessory = 120 -> queue=61, composer=59.
        #expect(abs(container.contentHost.frame.height - 120) < 0.001)
        #expect(abs(container.queueHost.frame.height - 61) < 0.001)
        #expect(abs(container.composerHost.frame.height - 59) < 0.001)

        container.setFrameSize(.init(width: 800, height: 600))
        container.layoutSubtreeIfNeeded()
        #expect(abs(container.queueHost.frame.height - 61) < 0.001)
        #expect(abs(container.composerHost.frame.height - 149) < 0.001)
        #expect(abs(container.contentHost.frame.height - 390) < 0.001)
    }

    @Test func togglingPinnedKeepsIdenticalInFlowSplitGeometry() async throws {
        let terminal = NSView()
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

        for isPinned in [false, true] {
            for (composerHeight, queueHeight) in [(149.0, 61.0), (0, 61), (0, 0), (149, 0), (300, 61)] {
                container.update(
                    content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                    composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                    queue: AnyView(Color.clear),
                    composerHeight: composerHeight,
                    queueHeight: queueHeight,
                    isPinned: isPinned
                )
                #expect(abs(container.contentHost.frame.height - (600 - composerHeight - queueHeight)) < 0.001,
                        "Quick Input publishes the split native viewport before updating the hosted terminal")
                container.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                container.layoutSubtreeIfNeeded()
                #expect(terminalMounts == 1)
                #expect(composerMounts == 1)
                #expect(abs(container.contentHost.frame.height - (600 - composerHeight - queueHeight)) < 0.001)
                #expect(abs(container.composerHost.frame.height - composerHeight) < 0.001)
                #expect(abs(container.queueHost.frame.height - queueHeight) < 0.001)
                #expect(container.composerHost.isHidden == (composerHeight == 0))
                #expect(container.queueHost.isHidden == (queueHeight == 0))
                #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 30)))
                #expect(editor.string == "draft / 草稿")
                #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
            }
        }
    }
}
