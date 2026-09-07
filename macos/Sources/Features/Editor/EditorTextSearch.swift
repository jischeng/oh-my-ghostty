import Foundation
import CodeEditTextView

private final class ProgrammaticReplaceDelegate: NSObject, TextViewDelegate {
    weak var upstream: TextViewDelegate?

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
        upstream?.textView(textView, didReplaceContentsIn: range, with: string)
    }
}

@MainActor
enum EditorTextEditing {
    /// Applies a replacement as one CodeEditTextView mutation, so one undo restores the full operation.
    @discardableResult
    static func replace(on textView: TextView, ranges: [NSRange], with replacement: String) -> Bool {
        guard textView.isEditable, !ranges.isEmpty else { return false }
        let ranges = EditorTextSearch.rangesForReplacement(ranges)
        guard let first = ranges.last, let last = ranges.first else { return false }
        let cover = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard cover.location >= 0, NSMaxRange(cover) <= textView.textStorage.length else { return false }

        let originalDelegate = textView.delegate
        let bypassDelegate = ProgrammaticReplaceDelegate(upstream: originalDelegate)
        textView.delegate = bypassDelegate
        defer {
            textView.delegate = originalDelegate
        }

        if ranges.count == 1 {
            textView.replaceCharacters(in: first, with: replacement)
            return true
        }

        let combined = NSMutableString(string: (textView.string as NSString).substring(with: cover))
        for range in ranges {
            let relative = NSRange(location: range.location - cover.location, length: range.length)
            combined.replaceCharacters(in: relative, with: replacement)
        }
        textView.replaceCharacters(in: cover, with: combined as String)
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
