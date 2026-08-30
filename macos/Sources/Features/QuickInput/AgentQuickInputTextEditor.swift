import AppKit
import SwiftUI

struct AgentQuickInputTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isPresented: Bool
    let onSend: () -> Void
    let onQueue: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = ComposerTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.font = .monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )
        editor.placeholder = placeholder
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.string = text
        editor.onSend = onSend
        editor.onQueue = onQueue
        editor.onCancel = onCancel
        scrollView.documentView = editor
        context.coordinator.editor = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? ComposerTextView else { return }
        editor.placeholder = placeholder
        editor.onSend = onSend
        editor.onQueue = onQueue
        editor.onCancel = onCancel
        if !editor.hasMarkedText(), editor.string != text {
            editor.string = text
        }
        if isPresented, !context.coordinator.wasPresented {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window != nil else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
        context.coordinator.wasPresented = isPresented
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var editor: ComposerTextView?
        var wasPresented = false

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            text = editor.string
        }
    }
}

enum AgentQuickInputMovementCommand: Equatable {
    case wordBackward(modifySelection: Bool)
    case wordForward(modifySelection: Bool)
    case paragraphBeginning(modifySelection: Bool)
    case paragraphEnd(modifySelection: Bool)

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Self? {
        let relevant = modifiers.intersection([.option, .shift, .command, .control])
        guard relevant == [.option] || relevant == [.option, .shift] else {
            return nil
        }
        let modifySelection = relevant.contains(.shift)
        switch keyCode {
        case 123: return .wordBackward(modifySelection: modifySelection)
        case 124: return .wordForward(modifySelection: modifySelection)
        case 126: return .paragraphBeginning(modifySelection: modifySelection)
        case 125: return .paragraphEnd(modifySelection: modifySelection)
        default: return nil
        }
    }

    var selector: Selector {
        switch self {
        case .wordBackward(false):
            #selector(NSStandardKeyBindingResponding.moveWordBackward(_:))
        case .wordBackward(true):
            #selector(NSStandardKeyBindingResponding.moveWordBackwardAndModifySelection(_:))
        case .wordForward(false):
            #selector(NSStandardKeyBindingResponding.moveWordForward(_:))
        case .wordForward(true):
            #selector(NSStandardKeyBindingResponding.moveWordForwardAndModifySelection(_:))
        case .paragraphBeginning(false):
            #selector(NSStandardKeyBindingResponding.moveToBeginningOfParagraph(_:))
        case .paragraphBeginning(true):
            #selector(
                NSStandardKeyBindingResponding.moveToBeginningOfParagraphAndModifySelection(_:)
            )
        case .paragraphEnd(false):
            #selector(NSStandardKeyBindingResponding.moveToEndOfParagraph(_:))
        case .paragraphEnd(true):
            #selector(
                NSStandardKeyBindingResponding.moveToEndOfParagraphAndModifySelection(_:)
            )
        }
    }
}

final class ComposerTextView: NSTextView {
    var pasteboard = NSPasteboard.general
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onSend: (() -> Void)?
    var onQueue: (() -> Void)?
    var onCancel: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        placeholder.draw(
            at: placeholderDrawingOrigin(),
            withAttributes: [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }

    func placeholderDrawingOrigin() -> NSPoint {
        let containerOrigin = textContainerOrigin
        guard let window else {
            return NSPoint(
                x: containerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: containerOrigin.y
            )
        }

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: &actualRange
        )
        let windowRect = window.convertFromScreen(screenRect)
        let localCaretRect = convert(windowRect, from: nil)
        guard localCaretRect.origin.x.isFinite else {
            return NSPoint(
                x: containerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: containerOrigin.y
            )
        }
        let devicePixel = 1 / max(window.backingScaleFactor, 1)
        return NSPoint(
            x: localCaretRect.maxX + devicePixel,
            y: containerOrigin.y
        )
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if hasMarkedText() {
                super.keyDown(with: event)
            } else {
                onCancel?()
            }
            return
        }
        if let movement = AgentQuickInputMovementCommand.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ), tryToPerform(movement.selector, with: nil) {
            return
        }
        if handleComposerCommand(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleComposerCommand(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if pasteboard.getOpinionatedStringContents() == nil,
           let path = pasteboard.imagePastePath() {
            insertText(path, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    private func handleComposerCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command, .shift, .option, .control,
        ])
        if event.keyCode == 36 || event.keyCode == 76,
           modifiers.contains(.command) {
            if modifiers.contains(.option) {
                onQueue?()
            } else {
                onSend?()
            }
            return true
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        switch AgentQuickInputEditingCommand.resolve(
            key: key,
            modifiers: modifiers
        ) {
        case .selectAll: selectAll(nil)
        case .copy: copy(nil)
        case .paste: paste(nil)
        case .cut: cut(nil)
        case .undo: undoManager?.undo()
        case .redo: undoManager?.redo()
        case nil: return false
        }
        return true
    }
}
