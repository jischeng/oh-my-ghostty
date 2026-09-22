@testable import Ghostty
import Testing
import Foundation

struct SurfaceViewAppKitTests {
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
