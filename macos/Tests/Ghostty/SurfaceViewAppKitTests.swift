@testable import Ghostty
import AppKit
import GhosttyKit
import Testing
import Foundation

@Suite(.serialized)
struct SurfaceViewAppKitTests {
    @MainActor
    @Test func resignFirstResponderClearsUncommittedMarkedTextAndSyncsPreedit() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer {
            controller.dismissQuickInput()
            window.delegate = nil
            window.close()
        }

        let surface = try #require(controller.focusedSurface)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(surface))

        // 1. Companion QuickInput focus transfer clears active CJK preedit without dropping terminal focus.
        surface.focusDidChange(true)
        surface.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange(location: 0, length: 5))
        let clearsBeforeCompanion = surface.preeditClearCount

        let companionEditor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        companionEditor.companionSurfaceID = surface.id
        window.contentView?.addSubview(companionEditor)
        controller.focusQuickInputEditor(companionEditor, for: surface.id)

        #expect(window.firstResponder === companionEditor)
        #expect(!surface.hasMarkedText())
        #expect(surface.markedRange().length == 0)
        #expect(surface.preeditClearCount == clearsBeforeCompanion + 1)
        #expect(surface.focused)

        // 2. Non-companion focus loss also clears active CJK preedit and unfocuses the terminal.
        #expect(window.makeFirstResponder(surface))
        surface.setMarkedText(
            "zhongwen",
            selectedRange: NSRange(location: 8, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(surface.hasMarkedText())
        let externalField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(externalField)
        #expect(window.makeFirstResponder(externalField))

        #expect(!surface.hasMarkedText())
        #expect(surface.preeditClearCount == clearsBeforeCompanion + 2)
        #expect(!surface.focused)
    }
    @Test func accumulatedInsertTextReturnsBeforeDirectDispatch() throws {
        // Protect the AppKit input adapter: the accumulator is dispatched by
        // keyDown, so falling through here sends the same key twice.
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: macos.appendingPathComponent(
            "Sources/Ghostty/Surface View/SurfaceView_AppKit.swift"
        ), encoding: .utf8)
        #expect(source.contains("keyTextAccumulator = acc\n            return"))
        #expect(!source.contains("typedCommandBuffer"))
    }

    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @MainActor
    @Test func surfaceViewInitialSizeUsesValidSizeAndFallsBackToDefault() throws {
        let nativeApp = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"

        let sized = Ghostty.SurfaceView(
            nativeApp,
            baseConfig: config,
            initialSize: CGSize(width: 420, height: 310)
        )
        #expect(sized.frame.size == CGSize(width: 420, height: 310))
        if let layer = sized.layer {
            #expect(layer.bounds.size == CGSize(width: 420, height: 310))
        }

        let invalidSizes: [CGSize?] = [
            nil,
            .zero,
            CGSize(width: -10, height: 300),
            CGSize(width: 300, height: -10),
            CGSize(width: 0, height: 300),
            CGSize(width: 300, height: 0),
            CGSize(width: CGFloat.nan, height: 300),
            CGSize(width: 300, height: CGFloat.infinity),
        ]
        for candidate in invalidSizes {
            let fallback = Ghostty.SurfaceView(
                nativeApp,
                baseConfig: config,
                initialSize: candidate
            )
            #expect(fallback.frame.size == CGSize(width: 800, height: 600))
        }
    }

    @MainActor
    @Test func surfaceScrollViewMountsAtNonZeroContentSizeWithoutZeroFrameBounce() throws {
        @MainActor
        final class FrameHistory {
            var surfaceSizes: [CGSize] = []
            var clipSizes: [CGSize] = []
        }

        let nativeApp = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let surface = Ghostty.SurfaceView(nativeApp, baseConfig: config)
        let lease = SurfacePresentationLease()
        surface.presentation.authorize(lease)
        surface.cellSize = CGSize(width: 10, height: 20)
        surface.scrollbar = Ghostty.Action.Scrollbar(
            c: ghostty_action_scrollbar_s(total: 100, offset: 30, len: 30)
        )

        let oldWrapper = SurfaceScrollView(
            contentSize: CGSize(width: 800, height: 600),
            surfaceView: surface,
            lease: lease
        )
        #expect(oldWrapper.frame.size == CGSize(width: 800, height: 600))
        #expect(surface.isDescendant(of: oldWrapper))

        let history = FrameHistory()
        surface.postsFrameChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: surface,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                history.surfaceSizes.append(surface.frame.size)
                if let clipView = surface.superview?.superview {
                    history.clipSizes.append(clipView.frame.size)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let targetSize = CGSize(width: 399.5, height: 600)
        let remounted = SurfaceScrollView(
            contentSize: targetSize,
            surfaceView: surface,
            lease: lease
        )

        let innerScroll = try #require(remounted.subviews.first as? NSScrollView)
        let documentView = try #require(innerScroll.documentView)
        #expect(remounted.frame.size == targetSize)
        #expect(innerScroll.frame.size == targetSize)
        #expect(innerScroll.contentView.frame.size == targetSize)
        #expect(documentView.frame.size.width == targetSize.width)
        #expect(documentView.frame.size.height == 2000)
        #expect(surface.superview === documentView)
        #expect(surface.frame.size == targetSize)
        #expect(surface.frame.origin == innerScroll.contentView.documentVisibleRect.origin)
        #expect(surface.frame.origin == CGPoint(x: 0, y: 800))
        #expect(!history.surfaceSizes.isEmpty)
        #expect(history.surfaceSizes.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(!history.clipSizes.isEmpty)
        #expect(history.clipSizes.allSatisfy { $0.width > 0 && $0.height > 0 })

        let zeroWrapper = SurfaceScrollView(
            contentSize: .zero,
            surfaceView: surface,
            lease: lease
        )
        #expect(zeroWrapper.frame.size == .zero)
        #expect(surface.frame.size == targetSize)
    }

    @MainActor
    @Test func surfaceScrollViewDropsInitialDerivedConfigReplay() async throws {
        let nativeApp = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let surface = Ghostty.SurfaceView(
            nativeApp,
            baseConfig: config,
            initialSize: CGSize(width: 400, height: 600)
        )
        let lease = SurfacePresentationLease()
        surface.presentation.authorize(lease)
        let wrapper = SurfaceScrollView(
            contentSize: CGSize(width: 400, height: 600),
            surfaceView: surface,
            lease: lease
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(surface.surfaceSize == nil)

        wrapper.layoutSubtreeIfNeeded()
        for _ in 0..<40 where surface.surfaceSize == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(surface.surfaceSize != nil)
    }

    @MainActor
    @Test func newSplitInitializesNewSurfaceAtTargetSlotSize() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer {
            controller.dismissQuickInput()
            window.delegate = nil
            window.close()
        }

        let oldView = try #require(controller.focusedSurface)
        oldView.frame.size = CGSize(width: 801, height: 601)

        let rightSplit = try #require(controller.newSplit(at: oldView, direction: .right, baseConfig: config))
        #expect(rightSplit.frame.size == CGSize(width: 400, height: 601))

        let downSplit = try #require(controller.newSplit(at: rightSplit, direction: .down, baseConfig: config))
        #expect(downSplit.frame.size == CGSize(width: 400, height: 300))

        downSplit.frame.size = CGSize(width: 20, height: 20)
        let fallbackSplit = try #require(controller.newSplit(at: downSplit, direction: .left, baseConfig: config))
        #expect(fallbackSplit.frame.size == CGSize(width: 800, height: 600))
    }
}
