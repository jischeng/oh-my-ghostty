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

    @Test func unpinnedAccessoriesFloatOverFullTerminalViewportWithZeroResize() async throws {
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

        for (composerHeight, queueHeight) in [(253.0, 0.0), (253, 61), (0, 61), (320, 61), (0, 0)] {
            container.update(
                content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                queue: AnyView(Color.clear),
                composerHeight: composerHeight,
                queueHeight: queueHeight,
                isPinned: false
            )
            #expect(container.contentHost.frame == NSRect(x: 0, y: 0, width: 800, height: 600),
                    "Unpinned Quick Input and queue bar must float without changing contentHost.frame")
            container.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            container.layoutSubtreeIfNeeded()
            #expect(terminalMounts == 1)
            #expect(composerMounts == 1)
            #expect(terminal.frameChangeCount == 0)
            #expect(container.contentHost.frame == container.bounds)
            #expect(container.composerHost.frame == NSRect(x: 0, y: queueHeight, width: 800, height: composerHeight))
            #expect(container.queueHost.frame == NSRect(x: 0, y: 0, width: 800, height: queueHeight))
            #expect(container.composerHost.isHidden == (composerHeight == 0))
            #expect(container.queueHost.isHidden == (queueHeight == 0))
            #expect(container.subviews == [container.contentHost, container.composerHost, container.queueHost])
            #expect(editor.string == "draft / 草稿")
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        }

        // Verify floating occlusion hit-testing distinguishes floating vs pinned modes.
        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 200,
            queueHeight: 60,
            isPinned: false
        )
        container.layoutSubtreeIfNeeded()
        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 30)))
        #expect(container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 180)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 300)))

        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(Color.clear),
            composerHeight: 200,
            queueHeight: 60,
            isPinned: true
        )
        container.layoutSubtreeIfNeeded()
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 30)))
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: 100, y: 180)))
    }

    @Test func smallWindowClampsAccessoriesAndRestoresRequestedHeightsOnResize() {
        let container = AgentQuickInputDockContainer.Container(frame: .init(x: 0, y: 0, width: 800, height: 100))
        container.update(content: AnyView(Color.clear), composer: AnyView(Color.clear), queue: AnyView(Color.clear),
                         composerHeight: 253, queueHeight: 61, isPinned: true)
        container.layoutSubtreeIfNeeded()
        #expect(container.contentHost.frame.height >= -0.001)
        #expect(abs(container.composerHost.frame.height - 39) < 0.001)
        container.setFrameSize(.init(width: 800, height: 600))
        container.layoutSubtreeIfNeeded()
        #expect(abs(container.composerHost.frame.height - 253) < 0.001)
        #expect(abs(container.contentHost.frame.height - 286) < 0.001)
    }

    @Test func togglingPinnedAccessoriesSplitsTerminalAndComposerAtTheirFinalGeometry() async throws {
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

        for (composerHeight, queueHeight) in [(253.0, 61.0), (0, 61), (0, 0), (253, 0), (300, 61)] {
            container.update(
                content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                queue: AnyView(Color.clear),
                composerHeight: composerHeight,
                queueHeight: queueHeight,
                isPinned: true
            )
            #expect(abs(container.contentHost.frame.height - (600 - composerHeight - queueHeight)) < 0.001,
                    "Pinned Quick Input publishes the split native viewport before updating the hosted terminal")
            container.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            container.layoutSubtreeIfNeeded()
            #expect(terminalMounts == 1)
            #expect(composerMounts == 1)
            #expect(abs(container.contentHost.frame.height - (600 - composerHeight - queueHeight)) < 0.001)
            #expect(abs(container.composerHost.frame.height - composerHeight) < 0.001)
            #expect(abs(container.queueHost.frame.height - queueHeight) < 0.001)
            #expect(container.composerHost.isHidden == (composerHeight == 0))
            #expect(container.queueHost.isHidden == (queueHeight == 0))
            #expect(editor.string == "draft / 草稿")
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        }
    }
}
