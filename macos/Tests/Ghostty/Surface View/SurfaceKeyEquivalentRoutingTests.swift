import AppKit
import Testing
@testable import Ghostty

@MainActor struct SurfaceKeyEquivalentRoutingTests {
    private let terminalView = NSView()

    private func ownsKeyboard(responder: NSResponder?) -> Bool {
        SurfaceKeyEquivalentRouting.textEditorOwnsKeyboard(
            firstResponder: responder,
            terminalView: terminalView
        )
    }

    @Test func terminalView_keepsTerminalShortcuts() {
        #expect(!ownsKeyboard(responder: terminalView))
    }

    @Test func noFirstResponder_keepsTerminalShortcuts() {
        #expect(!ownsKeyboard(responder: nil))
    }

    @Test func textView_defersToTextEditor() {
        #expect(ownsKeyboard(responder: NSTextView()))
    }

    @Test func otherView_keepsTerminalShortcuts() {
        #expect(!ownsKeyboard(responder: NSButton()))
    }
}
