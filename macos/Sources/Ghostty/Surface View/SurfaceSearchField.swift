import AppKit
import SwiftUI

extension Ghostty {
    /// Single-line, AppKit-backed search field for the terminal search overlay.
    ///
    /// The field is a real `NSTextView` rather than a SwiftUI `TextField` or an
    /// `NSTextField`. A text view resolves the standard editing key bindings
    /// itself — Option+Arrow word movement, Option+Delete word deletion,
    /// Command+Arrow, the Edit menu, and input methods all work — whereas the
    /// window's shared field editor does not resolve the Option-modified
    /// bindings inside a terminal window. The quick input composer uses the same
    /// approach.
    struct SurfaceSearchField: NSViewRepresentable {
        /// The search needle, including the selection the overlay wants applied.
        @Binding var needle: OSSurfaceView.SearchState.Needle

        /// Incremented by the overlay whenever the field should take focus.
        let focusRequest: Int

        let onSubmit: () -> Void
        let onSubmitShift: () -> Void
        let onCancel: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = FieldScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .none

            let editor = Editor()
            editor.delegate = context.coordinator
            editor.isRichText = false
            editor.importsGraphics = false
            editor.drawsBackground = false
            editor.isEditable = true
            editor.isSelectable = true
            editor.allowsUndo = true
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.usesFindBar = false
            editor.font = .systemFont(ofSize: NSFont.systemFontSize)
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            // Single line: grow horizontally instead of wrapping, and let the
            // scroll view keep the caret visible.
            editor.isVerticallyResizable = false
            editor.isHorizontallyResizable = true
            editor.minSize = NSSize(width: 0, height: 0)
            editor.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.widthTracksTextView = false
            editor.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            editor.autoresizingMask = [.height]
            editor.frame = NSRect(x: 0, y: 0, width: 0, height: editor.singleLineHeight)
            editor.string = needle.text
            editor.placeholder = "Search"

            scrollView.documentView = editor
            context.coordinator.editor = editor
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            context.coordinator.parent = self
            context.coordinator.sync()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: NSScrollView,
            context: Context
        ) -> CGSize? {
            let height = (nsView.documentView as? Editor)?.singleLineHeight ?? NSFont.systemFontSize
            return CGSize(width: proposal.width ?? 180, height: height)
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: SurfaceSearchField
            weak var editor: Editor?

            /// The last needle selection applied to the editor, so we only write it
            /// once per request instead of fighting the caret.
            private var appliedSelection: Range<String.Index>?

            /// The last focus request handled.
            private var appliedFocusRequest = Int.min

            /// True while we are pushing model state into the editor.
            private var isSyncing = false

            init(_ parent: SurfaceSearchField) {
                self.parent = parent
            }

            func sync() {
                guard let editor else { return }

                // Text can change outside of typing: restoring the find
                // pasteboard, a new search, or an external find.
                if !editor.hasMarkedText(), editor.string != parent.needle.text {
                    isSyncing = true
                    editor.string = parent.needle.text
                    isSyncing = false
                }

                let wantsFocus = appliedFocusRequest != parent.focusRequest
                if wantsFocus { appliedFocusRequest = parent.focusRequest }

                if wantsFocus {
                    focus(editor)
                } else if appliedSelection != parent.needle.selection {
                    appliedSelection = parent.needle.selection
                    applySelection(editor)
                }
            }

            /// Takes focus and applies any selection that came with the needle.
            ///
            /// The field can be created before it is in a window, and the surface
            /// view may still hold first responder, so retry until the field
            /// actually owns the keyboard.
            private func focus(_ editor: Editor, attempt: Int = 0) {
                guard let window = editor.window else { return retryFocus(editor, attempt: attempt) }
                window.makeFirstResponder(editor)
                guard window.firstResponder === editor else {
                    return retryFocus(editor, attempt: attempt)
                }
                applySelection(editor)
            }

            private func retryFocus(_ editor: Editor, attempt: Int) {
                guard attempt < 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.focus(editor, attempt: attempt + 1)
                }
            }

            private func applySelection(_ editor: Editor) {
                guard let selection = parent.needle.selection else { return }
                editor.setSelectedRange(NSRange(selection, in: parent.needle.text))
            }

            func textDidChange(_ notification: Foundation.Notification) {
                guard !isSyncing, let editor, editor.string != parent.needle.text else { return }

                var needle = parent.needle
                needle.text = editor.string
                // The edit consumed whatever selection the overlay applied.
                needle.selection = nil
                appliedSelection = nil
                parent.needle = needle
            }

            func textView(
                _ textView: NSTextView,
                shouldChangeTextIn affectedCharRange: NSRange,
                replacementString: String?
            ) -> Bool {
                // The needle is single line: never let a paste insert newlines.
                guard let replacementString,
                      replacementString.contains("\n") || replacementString.contains("\r") else {
                    return true
                }
                let single = replacementString
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                textView.insertText(single, replacementRange: affectedCharRange)
                return false
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.insertNewline(_:)):
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        parent.onSubmitShift()
                    } else {
                        parent.onSubmit()
                    }
                    return true

                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCancel()
                    return true

                default:
                    return false
                }
            }
        }
    }
}

extension Ghostty.SurfaceSearchField {
    /// The text view, configured as a single-line field.
    final class Editor: NSTextView {
        var placeholder = "" {
            didSet { needsDisplay = true }
        }

        /// The height of one line of text, including the container inset.
        var singleLineHeight: CGFloat {
            let font = self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = layoutManager?.defaultLineHeight(for: font)
                ?? (font.ascender - font.descender + font.leading)
            return ceil(lineHeight + textContainerInset.height * 2)
        }

        /// A search field reads as a text field to accessibility clients even
        /// though it is backed by a text view.
        override func accessibilityRole() -> NSAccessibility.Role? { .textField }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
            placeholder.draw(
                at: placeholderDrawingOrigin(),
                withAttributes: [
                    .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.placeholderTextColor,
                ])
        }

        private func placeholderDrawingOrigin() -> NSPoint {
            let containerOrigin = textContainerOrigin
            let fallback = NSPoint(
                x: containerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: containerOrigin.y)
            guard let window else { return fallback }

            var actualRange = NSRange(location: NSNotFound, length: 0)
            let screenRect = firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: &actualRange)
            let localCaretRect = convert(window.convertFromScreen(screenRect), from: nil)
            guard localCaretRect.origin.x.isFinite else { return fallback }
            let devicePixel = 1 / max(window.backingScaleFactor, 1)
            return NSPoint(x: localCaretRect.maxX + devicePixel, y: containerOrigin.y)
        }
    }

    /// Scroll view that reports a single line of height to SwiftUI.
    final class FieldScrollView: NSScrollView {
        override var intrinsicContentSize: NSSize {
            let height = (documentView as? Editor)?.singleLineHeight ?? NSFont.systemFontSize
            return NSSize(width: NSView.noIntrinsicMetric, height: height)
        }
    }
}
