import AppKit

/// Routing rules for key equivalents that would otherwise be consumed by the
/// terminal surface.
///
/// AppKit owns the standard editing commands — undo, redo, cut, copy, paste,
/// select all, and everything else the Edit menu defines — and dispatches them
/// through the First Responder chain. The terminal therefore yields whenever a
/// text editor owns keyboard input, instead of matching individual shortcuts
/// itself. Yielding is what gives the search field (and any other text field in
/// a terminal window) the complete, native set of editing shortcuts.
enum SurfaceKeyEquivalentRouting {
    /// Returns true when a text editor, rather than the terminal view, owns the
    /// keyboard for the given window state.
    ///
    /// - Parameters:
    ///   - firstResponder: The window's current first responder.
    ///   - terminalView: The terminal surface view being asked to handle the event.
    static func textEditorOwnsKeyboard(
        firstResponder: NSResponder?,
        terminalView: NSView
    ) -> Bool {
        // Nothing else claims the keyboard, so the terminal keeps its shortcuts.
        guard let firstResponder, firstResponder !== terminalView else { return false }

        // Field editors backing NSTextField/NSSearchField (and SwiftUI text
        // fields) are NSTextViews, as are the full text views used by the
        // editor panes and the quick input composer.
        return firstResponder is NSTextView
    }
}
