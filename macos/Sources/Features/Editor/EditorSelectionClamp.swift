import AppKit
import CodeEditTextView

/// Keeps editor selections inside the document while the text is changing.
///
/// `CEUndoManager` applies undo/redo by rewriting the text with
/// `skipUpdateSelection: true`, so the selections still describe the pre-edit
/// document. Each `replaceCharacters` call then scrolls those stale selections
/// into view. Undo wraps the whole batch in its own `beginEditing`, so the layout
/// manager's line storage has not caught up yet: it still describes the longer
/// document. `rectForOffset` only takes its end-of-document path when
/// `offset >= lineStorage.length`; below that it reads
/// `rangeOfComposedCharacterSequence(at: offset)`, and the stale last-line offset
/// points past the real string. That raises `NSInvalidArgumentException` and
/// terminates the process.
///
/// Trimming therefore has to happen after the text storage shrank but before the
/// scroll, which is exactly `TextViewDelegate.didReplaceContentsIn`. Ranges are
/// edited in place and no selection notification is posted, because repositioning
/// cursors mid-edit would re-enter the layout manager. `CEUndoManager` restores
/// the recorded selections once its step completes.
@MainActor
enum EditorSelectionClamp {
    /// Trims every selection so no caret can be resolved past the string.
    ///
    /// While the line storage is longer than the text (mid-batch), a caret at
    /// exactly `length` is still unsafe, so the bound drops one character back.
    @discardableResult
    static func trim(_ textView: TextView) -> Bool {
        let length = textView.textStorage.length
        let lineLength = textView.layoutManager.lineStorage.length
        let limit = (lineLength > length && length > 0) ? length - 1 : length
        var didTrim = false
        for selection in textView.selectionManager.textSelections {
            let range = selection.range
            guard range.location != NSNotFound, range.location >= 0 else { continue }
            let location = min(range.location, limit)
            let clamped = NSRange(location: location, length: max(0, min(range.length, limit - location)))
            guard clamped != range else { continue }
            selection.range = clamped
            didTrim = true
        }
        return didTrim
    }
}
