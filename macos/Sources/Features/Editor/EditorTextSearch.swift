import Foundation
import CodeEditTextView

private final class ProgrammaticReplaceDelegate: NSObject, TextViewDelegate {
    weak var upstream: TextViewDelegate?
    var groupMutations = false
    var ownsUndoGroup = false

    init(upstream: TextViewDelegate?) {
        self.upstream = upstream
    }

    func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool {
        true
    }

    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        upstream?.textView(textView, willReplaceContentsIn: range, with: string)
    }

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        if groupMutations, !ownsUndoGroup, textView._undoManager?.isGrouping == false {
            textView._undoManager?.beginGrouping()
            ownsUndoGroup = true
        }
        upstream?.textView(textView, didReplaceContentsIn: range, with: string)
    }
}

@MainActor
enum EditorTextEditing {
    /// Literal replacements share one undo group without replacing untouched
    /// lines between carets (which can invalidate the native line layout cache).
    @discardableResult
    static func replace(on textView: TextView, ranges: [NSRange], with replacement: String) -> Bool {
        apply(on: textView, edits: ranges.map { ($0, replacement) })
    }

    @discardableResult
    static func apply(on textView: TextView, edits: [(range: NSRange, text: String)]) -> Bool {
        guard textView.isEditable, !edits.isEmpty else { return false }
        let edits = edits.sorted { $0.range.location < $1.range.location }
        guard edits.allSatisfy({ $0.range.location != NSNotFound && $0.range.location >= 0
            && NSMaxRange($0.range) <= textView.textStorage.length }) else { return false }
        for (first, second) in zip(edits, edits.dropFirst()) where NSMaxRange(first.range) > second.range.location {
            return false
        }
        let originalDelegate = textView.delegate
        let bypass = ProgrammaticReplaceDelegate(upstream: originalDelegate)
        bypass.groupMutations = edits.count > 1
        textView.delegate = bypass
        defer {
            if bypass.ownsUndoGroup { textView._undoManager?.endGrouping() }
            textView.delegate = originalDelegate
        }
        for edit in edits.reversed() {
            // Callers restore their final selections. Do not let intermediate
            // replacements remap stale multi-caret positions outside the buffer.
            textView.selectionManager.setSelectedRange(edit.range)
            textView.replaceCharacters(in: edit.range, with: edit.text)
        }
        return true
    }

}

/// UTF-16 based search and navigation helpers for the native editor.
enum EditorTextSearch {
    static func lineRange(containing selection: NSRange, in text: String) -> NSRange? {
        let source = text as NSString
        guard selection.location != NSNotFound,
              selection.location >= 0,
              NSMaxRange(selection) <= source.length else { return nil }
        // EOF after a newline is an empty line, not the preceding line.
        return source.lineRange(for: selection)
    }

    static func matches(in text: String, query: String, caseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [NSRange] = []
        var location = 0

        while location <= source.length {
            let searchRange = NSRange(location: location, length: source.length - location)
            let match = source.range(of: query, options: options, range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)
            location = NSMaxRange(match)
        }
        return matches
    }

    static func matchIndex(
        in matches: [NSRange],
        selection: NSRange?,
        searchingForward: Bool
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let selection, selection.location != NSNotFound else {
            return searchingForward ? 0 : matches.count - 1
        }
        if searchingForward {
            return matches.firstIndex { $0.location >= NSMaxRange(selection) } ?? 0
        }
        return matches.lastIndex { NSMaxRange($0) <= selection.location } ?? matches.count - 1
    }

    static func range(forLine line: Int, column: Int, in text: String) -> NSRange? {
        guard line > 0, column > 0 else { return nil }
        let source = text as NSString
        var lineStart = 0
        var currentLine = 1

        while currentLine < line {
            let newline = source.range(
                of: "\n",
                range: NSRange(location: lineStart, length: source.length - lineStart)
            )
            guard newline.location != NSNotFound else { return nil }
            lineStart = NSMaxRange(newline)
            currentLine += 1
        }

        let newline = source.range(
            of: "\n",
            range: NSRange(location: lineStart, length: source.length - lineStart)
        )
        let lineEnd = newline.location == NSNotFound ? source.length : newline.location
        let offset = min(column - 1, lineEnd - lineStart)
        var location = lineStart + offset
        if location < lineEnd {
            location = source.rangeOfComposedCharacterSequence(at: location).location
        }
        return NSRange(location: location, length: 0)
    }

    static func lineAndColumn(from input: String) -> (line: Int, column: Int)? {
        let components = input.split(separator: ":", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 2,
              let line = Int(components[0]), line > 0 else { return nil }
        let column = components.count == 2 ? Int(components[1]) : 1
        guard let column, column > 0 else { return nil }
        return (line, column)
    }

    static func rangesForReplacement(_ ranges: [NSRange]) -> [NSRange] {
        ranges.sorted(by: { $0.location > $1.location })
    }
}
