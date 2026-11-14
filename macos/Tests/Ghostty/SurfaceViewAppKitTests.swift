@testable import Ghostty
import AppKit
import Testing
import Foundation

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
}
