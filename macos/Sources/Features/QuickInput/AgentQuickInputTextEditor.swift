import AppKit
import SwiftUI

protocol TerminalCompanionResponder: AnyObject {
    var companionSurfaceID: UUID? { get }
}

struct AgentQuickInputTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isPresented: Bool
    let focusRequestID: Int
    let font: NSFont
    var textColor: NSColor = .labelColor
    let onPasteImage: ((URL, @escaping (String) -> Void) -> Void)?
    let onSend: () -> Void
    let onQueue: () -> Void
    let onCancel: () -> Void
    var onRecallHistory: (() -> Bool)?
    var onNavigateHistory: ((QuickInputHistoryDirection, QuickInputDraftSnapshot, Bool, Bool)
        -> QuickInputHistoryNavigationResult)?
    var onHistoryCaretMoved: (() -> Void)?
    var companionSurfaceID: UUID?
    var onEditorMouseDown: (() -> Void)?
    var onPresentationReady: (() -> Void)?

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
        editor.placeholder = placeholder
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.string = text
        configureTypography(for: editor, coordinator: context.coordinator, force: true)
        editor.onPasteImage = onPasteImage
        editor.onSend = onSend
        editor.onQueue = onQueue
        editor.onCancel = onCancel
        editor.onRecallHistory = onRecallHistory
        editor.onNavigateHistory = onNavigateHistory
        editor.onHistoryCaretMoved = onHistoryCaretMoved
        editor.onEditorMouseDown = onEditorMouseDown
        editor.companionSurfaceID = companionSurfaceID
        scrollView.documentView = editor
        scrollView.isHidden = !isPresented
        context.coordinator.editor = editor
        context.coordinator.lastCompanionSurfaceID = companionSurfaceID
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? ComposerTextView else { return }
        // SwiftUI opacity/allowsHitTesting do not remove the NSTextView from
        // AppKit cursor handling. A dismissed composer would keep resetting the
        // terminal cursor to an I-beam, flickering against Cmd-link pointers.
        if scrollView.isHidden == isPresented {
            scrollView.isHidden = !isPresented
            scrollView.window?.invalidateCursorRects(for: scrollView)
        }
        editor.placeholder = placeholder
        editor.onPasteImage = onPasteImage
        editor.onSend = onSend
        editor.onQueue = onQueue
        editor.onCancel = onCancel
        editor.onRecallHistory = onRecallHistory
        editor.onNavigateHistory = onNavigateHistory
        editor.onHistoryCaretMoved = onHistoryCaretMoved
        editor.onEditorMouseDown = onEditorMouseDown
        editor.companionSurfaceID = companionSurfaceID
        let paneChanged = context.coordinator.lastCompanionSurfaceID != companionSurfaceID
        if paneChanged {
            context.coordinator.lastCompanionSurfaceID = companionSurfaceID
            editor.resetLocalUndoManager()
        }
        var needsTypographyRefresh = false
        if !editor.hasMarkedText(), editor.string != text {
            editor.restoreHistorySnapshot(
                .init(
                    text: text,
                    selection: NSRange(location: (text as NSString).length, length: 0)
                ),
                resetUndo: paneChanged || text.isEmpty
            )
            needsTypographyRefresh = true
        }
        configureTypography(for: editor, coordinator: context.coordinator, force: needsTypographyRefresh)
        if isPresented,
           focusRequestID > 0,
           focusRequestID != context.coordinator.handledFocusRequestID {
            let request = focusRequestID
            let coordinator = context.coordinator
            coordinator.pendingFocusRequestID = request
            let onReady = onPresentationReady
            DispatchQueue.main.async { [weak editor, weak scrollView] in
                guard let editor, let scrollView, !scrollView.isHiddenOrHasHiddenAncestor,
                      coordinator.pendingFocusRequestID == request,
                      let window = editor.window, window.isVisible,
                      (window.tabGroup?.selectedWindow ?? window) === window,
                      (window.windowController as? TerminalController)?.workspacePresentationIsParked != true else { return }
                // Resolve the dock's final reservation before AppKit scrolls
                // the newly focused editor into view.
                window.contentView?.layoutSubtreeIfNeeded()
                guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
                coordinator.handledFocusRequestID = request
                coordinator.pendingFocusRequestID = nil
                if let controller = window.windowController as? TerminalController {
                    controller.focusQuickInputEditor(editor, for: editor.companionSurfaceID)
                } else {
                    window.makeFirstResponder(editor)
                }
                onReady?()
            }
        } else if !isPresented {
            context.coordinator.pendingFocusRequestID = nil
        }
    }

    private func configureTypography(
        for editor: NSTextView,
        coordinator: Coordinator,
        force: Bool
    ) {
        coordinator.applyTypography(to: editor, font: font, textColor: textColor, force: force)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var editor: ComposerTextView?
        var handledFocusRequestID = 0
        var pendingFocusRequestID: Int?
        var lastCompanionSurfaceID: UUID?
        private var appliedFont: NSFont?
        private var appliedTextColor: NSColor?
        private var deferredTypography: (font: NSFont, textColor: NSColor)?
        private var lastSelection: NSRange?

        init(text: Binding<String>) {
            self._text = text
        }

        func applyTypography(
            to editor: NSTextView,
            font: NSFont,
            textColor: NSColor,
            force: Bool
        ) {
            let typographyChanged = appliedFont != font || appliedTextColor != textColor
            guard force || typographyChanged || deferredTypography != nil else { return }

            // Never mutate NSTextView.font/textColor or textStorage attributes while an
            // IME marked-text composition is active; AppKit's textColor setter rewrites
            // the entire storage range and disrupts active marked-text presentation.
            if editor.hasMarkedText() {
                deferredTypography = (font, textColor)
                return
            }
            deferredTypography = nil

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = AgentQuickInputMetrics.editorLineSpacing
            editor.font = font
            editor.textColor = textColor
            editor.insertionPointColor = textColor
            editor.defaultParagraphStyle = paragraphStyle
            editor.typingAttributes[.font] = font
            editor.typingAttributes[.foregroundColor] = textColor
            editor.typingAttributes[.paragraphStyle] = paragraphStyle
            appliedFont = font
            appliedTextColor = textColor

            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttributes(
                    [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle],
                    range: NSRange(location: 0, length: storage.length)
                )
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            if let pending = deferredTypography, !editor.hasMarkedText() {
                applyTypography(
                    to: editor,
                    font: pending.font,
                    textColor: pending.textColor,
                    force: true
                )
            }
            guard !editor.isRestoringHistory, text != editor.string else { return }
            text = editor.string
        }

        func syncFromBindingIfNeeded() {
            guard let editor, !editor.hasMarkedText(), editor.string != text else { return }
            editor.restoreHistorySnapshot(
                .init(
                    text: text,
                    selection: NSRange(location: (text as NSString).length, length: 0)
                ),
                resetUndo: text.isEmpty
            )
            if let appliedFont, let appliedTextColor {
                applyTypography(
                    to: editor,
                    font: appliedFont,
                    textColor: appliedTextColor,
                    force: true
                )
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor else { return }
            let previous = lastSelection
            lastSelection = editor.selectedRange()
            guard !editor.isRestoringHistory, previous != lastSelection else { return }
            editor.onHistoryCaretMoved?()
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
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool = false
    ) -> Self? {
        guard !hasMarkedText else { return nil }
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

final class ComposerTextView: NSTextView, TerminalCompanionResponder {
    static let placeholderCaretGap: CGFloat = 3

    var controlJNewlineEnabled: () -> Bool = { OhMyGhosttySettings.shared.quickInputControlJNewline }
    var pasteboard = NSPasteboard.general
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onPasteImage: ((URL, @escaping (String) -> Void) -> Void)?
    var onSend: (() -> Void)?
    var onQueue: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRecallHistory: (() -> Bool)?
    var onNavigateHistory: ((QuickInputHistoryDirection, QuickInputDraftSnapshot, Bool, Bool)
        -> QuickInputHistoryNavigationResult)?
    var onHistoryCaretMoved: (() -> Void)?
    var performMovementSelector: ((Selector) -> Bool)?
    var onEditorMouseDown: (() -> Void)?
    var companionSurfaceID: UUID?
    private(set) var isRestoringHistory = false

    override func mouseDown(with event: NSEvent) {
        onEditorMouseDown?()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            let window = self.window
            let companionID = self.companionSurfaceID
            DispatchQueue.main.async { [weak window] in
                guard let window,
                      let controller = window.windowController as? BaseTerminalController else {
                    return
                }
                if let companionID,
                   (window.firstResponder as? Ghostty.SurfaceView)?.id == companionID {
                    return
                }
                controller.syncFocusToSurfaceTree()
            }
        }
        return result
    }

    func restoreHistorySnapshot(
        _ snapshot: QuickInputDraftSnapshot,
        resetUndo: Bool = false
    ) {
        isRestoringHistory = true
        if resetUndo {
            string = snapshot.text
            resetLocalUndoManager()
        } else {
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            breakUndoCoalescing()
            if localUndoManager.groupsByEvent, localUndoManager.groupingLevel > 0 {
                localUndoManager.endUndoGrouping()
                localUndoManager.beginUndoGrouping()
            }
            if allowsUndo,
               shouldChangeText(in: fullRange, replacementString: snapshot.text) {
                textStorage?.replaceCharacters(in: fullRange, with: snapshot.text)
                didChangeText()
            } else {
                string = snapshot.text
            }
        }
        let length = (string as NSString).length
        let location = min(snapshot.selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(snapshot.selection.length, length - location)))
        scrollRangeToVisible(selectedRange())
        isRestoringHistory = false
    }

    func isOnHistoryBoundary(_ direction: QuickInputHistoryDirection) -> Bool {
        guard selectedRange().length == 0 else { return false }
        guard !string.isEmpty else { return true }
        guard let layoutManager, let textContainer else { return false }
        layoutManager.ensureLayout(for: textContainer)
        let length = (string as NSString).length
        let location = min(selectedRange().location, length)
        let hasTrailingLine = string.hasSuffix("\n") && !layoutManager.extraLineFragmentRect.isEmpty
        let caretRect: NSRect
        if location == length && hasTrailingLine {
            caretRect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
            caretRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let boundary: NSRect
        switch direction {
        case .older:
            boundary = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        case .newer:
            if hasTrailingLine {
                boundary = layoutManager.extraLineFragmentRect
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
                boundary = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
        }
        return abs(caretRect.minY - boundary.minY) < 0.5
    }

    private let localUndoManager = UndoManager()
    override var undoManager: UndoManager? { localUndoManager }

    func resetLocalUndoManager() {
        localUndoManager.removeAllActions()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let placeholderColor = textColor?.withAlphaComponent(0.42) ?? NSColor.placeholderTextColor
        placeholder.draw(
            at: placeholderDrawingOrigin(),
            withAttributes: [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: placeholderColor,
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
        return NSPoint(
            x: localCaretRect.maxX + Self.placeholderCaretGap,
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

    func commitMarkedTextForSubmission() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
        didChangeText()
    }

    func syncWithBoundDraftIfNeeded() {
        (delegate as? AgentQuickInputTextEditor.Coordinator)?.syncFromBindingIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if controlJNewlineEnabled(), !hasMarkedText(),
           event.keyCode == 38,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.control] {
            insertText("\n", replacementRange: selectedRange())
            return
        }
        if [UInt16(126), 125].contains(event.keyCode), !hasMarkedText(),
           event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
           let onNavigateHistory {
            let direction: QuickInputHistoryDirection = event.keyCode == 126 ? .older : .newer
            let snapshot = QuickInputDraftSnapshot(text: string, selection: selectedRange())
            switch onNavigateHistory(direction, snapshot, isOnHistoryBoundary(direction), event.isARepeat) {
            case .restore(let snapshot): restoreHistorySnapshot(snapshot); return
            case .consumed: return
            case .unhandled: break
            }
        }
        if onNavigateHistory == nil, event.keyCode == 126,
           event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
           string.isEmpty, !hasMarkedText(),
           onRecallHistory?() == true {
            return
        }
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
            modifiers: event.modifierFlags,
            hasMarkedText: hasMarkedText()
        ) {
            let handled = performMovementSelector?(movement.selector)
                ?? tryToPerform(movement.selector, with: nil)
            if handled { return }
        }
        if handleComposerCommand(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleComposerCommand(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if let file = pasteboard.imagePasteURL() {
            let insertPath: (String) -> Void = { [weak self] path in
                guard let self else { return }
                self.insertText(path, replacementRange: self.selectedRange())
            }
            if let onPasteImage {
                onPasteImage(file, insertPath)
            } else {
                insertPath(Ghostty.Shell.escape(file.path))
            }
            return
        }
        super.paste(sender)
    }

    private func handleComposerCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command, .shift, .option, .control,
        ])
        if event.keyCode == 36 || event.keyCode == 76 {
            if modifiers == [.command] {
                commitMarkedTextForSubmission()
                onSend?()
                syncWithBoundDraftIfNeeded()
                return true
            }
            if modifiers == [.command, .option] {
                commitMarkedTextForSubmission()
                onQueue?()
                syncWithBoundDraftIfNeeded()
                return true
            }
            return false
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
        case .undo:
            if localUndoManager.canUndo {
                localUndoManager.undoSafely()
            }
        case .redo:
            if localUndoManager.canRedo {
                localUndoManager.redoSafely()
            }
        case nil: return false
        }
        return true
    }
}
