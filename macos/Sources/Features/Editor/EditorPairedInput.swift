import AppKit
import CodeEditTextView

/// One literal edit for all carets, sharing the editor's programmatic edit and undo path.
@MainActor
enum EditorPairedInput {
    private static let pairs: [String: String] = ["\"": "\"", "'": "'", "(": ")", "[": "]", "{": "}"]

    @discardableResult
    static func apply(_ character: String, backspace: Bool = false, enabled: Bool, on textView: TextView) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        guard backspace || pairs[character] != nil || pairs.values.contains(character) else { return false }
        let source = textView.string as NSString
        let selections = textView.selectionManager.textSelections.map(\.range).sorted { $0.location < $1.location }
        guard !selections.isEmpty else { return false }
        var edits: [(range: NSRange, text: String, caret: Int)] = []
        for selection in selections {
            guard selection.location != NSNotFound, selection.location >= 0, NSMaxRange(selection) <= source.length else { return false }
            let location = selection.location
            let next = location < source.length ? source.substring(with: NSRange(location: location, length: 1)) : ""
            if backspace {
                guard enabled, selection.length == 0, location > 0 else { return false }
                let previous = source.substring(with: NSRange(location: location - 1, length: 1))
                guard pairs[previous] == next else { return false }
                edits.append((NSRange(location: location - 1, length: 2), "", 0))
            } else if enabled, selection.length == 0, pairs.values.contains(character), next == character {
                edits.append((NSRange(location: location + 1, length: 0), "", 0))
            } else if enabled, let closing = pairs[character] {
                let previous = location > 0 ? source.substring(with: NSRange(location: location - 1, length: 1)) : ""
                let quotedWord = (character == "'" || character == "\"") && previous.unicodeScalars.contains {
                    CharacterSet.alphanumerics.contains($0) || $0 == "_"
                }
                if previous == "\\" || (selection.length == 0 && quotedWord) {
                    edits.append((selection, character, character.utf16.count))
                } else {
                    let selected = source.substring(with: selection)
                    edits.append((selection, character + selected + closing, character.utf16.count))
                }
            } else {
                edits.append((selection, character, character.utf16.count))
            }
        }
        var delta = 0
        let carets = edits.map { edit -> NSRange in
            let caret = NSRange(location: edit.range.location + delta + edit.caret, length: 0)
            delta += edit.text.utf16.count - edit.range.length
            return caret
        }
        let mutations = edits.filter { $0.range.length > 0 || !$0.text.isEmpty }.map { (range: $0.range, text: $0.text) }
        if !mutations.isEmpty {
            guard EditorTextEditing.apply(on: textView, edits: mutations) else { return false }
        }
        EditorNativeTextActions.select(carets, on: textView)
        return true
    }
}
