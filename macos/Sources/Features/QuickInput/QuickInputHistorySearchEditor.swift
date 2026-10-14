import AppKit
import SwiftUI

// One native input client stays mounted in both list and search mode. The first
// typed character (including IME composition) is handled by AppKit, not manually
// reconstructed from NSEvent.characters or dropped during a focus handoff.
struct QuickInputHistorySearchEditor: NSViewRepresentable {
    @Binding var query: String
    let placeholder: String
    let isSearching: Bool
    let focusRequestID: Int
    let onBeginSearch: () -> Void
    let onMove: (Int) -> Void
    let onSelect: () -> Void
    let onEscape: () -> Void
    let onToggle: () -> Void
    var canRequestFocus: (() -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(query: $query) }

    func makeNSView(context: Context) -> QuickInputHistorySearchTextView {
        let editor = QuickInputHistorySearchTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 7)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize.height = CGFloat.greatestFiniteMagnitude
        configure(editor)
        return editor
    }

    func updateNSView(_ editor: QuickInputHistorySearchTextView, context: Context) {
        configure(editor)
        if !editor.hasMarkedText(), editor.string != query {
            editor.string = query
            editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
        }
        if context.coordinator.handledFocusID != focusRequestID {
            context.coordinator.handledFocusID = focusRequestID
            editor.requestKeyboardFocus()
        }
    }

    private func configure(_ editor: QuickInputHistorySearchTextView) {
        editor.placeholder = placeholder
        editor.isSearching = isSearching
        editor.onBeginSearch = onBeginSearch
        editor.onMove = onMove
        editor.onSelect = onSelect
        editor.onEscape = onEscape
        editor.onToggle = onToggle
        editor.canRequestFocus = canRequestFocus
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var query: String
        var handledFocusID = -1
        init(query: Binding<String>) { _query = query }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            query = editor.string
        }
    }
}

final class QuickInputHistorySearchTextView: NSTextView {
    var isSearching = false
    var placeholder = "" { didSet { needsDisplay = true } }
    var onBeginSearch: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onSelect: (() -> Void)?
    var onEscape: (() -> Void)?
    var onToggle: (() -> Void)?
    var canRequestFocus: (() -> Bool)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { requestKeyboardFocus() }
    }

    func requestKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canRequestFocus?() != false,
                  let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSearching, string.isEmpty, !hasMarkedText() {
            placeholder.draw(at: NSPoint(x: 0, y: 7), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if OMGKeyboardShortcut.quickInputHistory.matches(event) {
            onToggle?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if OMGKeyboardShortcut.quickInputHistory.matches(event) { onToggle?(); return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if !hasMarkedText(), modifiers.isEmpty {
            switch event.keyCode {
            case 126: onMove?(-1); return
            case 125: onMove?(1); return
            case 36, 76: onSelect?(); return
            case 53: onEscape?(); return
            default: break
            }
        }
        if !isSearching, modifiers.isDisjoint(with: [.command, .control]),
           event.characters?.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) == true {
            string = ""
            isSearching = true
            onBeginSearch?()
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onEscape?() }
    }
}
