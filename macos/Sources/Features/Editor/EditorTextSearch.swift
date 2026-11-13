import Foundation

/// 1-based line and optional column / inclusive end-line target for opening files.
struct EditorTextLocation: Equatable, Sendable {
    let startLine: Int
    let column: Int?
    let endLine: Int?

    init(startLine: Int, column: Int? = nil, endLine: Int? = nil) {
        self.startLine = startLine
        self.column = column
        self.endLine = endLine
    }
}

/// UTF-16 based search and navigation helpers for the editor.
enum EditorTextSearch {
    static func selectionRange(for location: EditorTextLocation, in text: String) -> NSRange? {
        if let endLine = location.endLine {
            let firstLine = min(location.startLine, endLine)
            let lastLine = max(location.startLine, endLine)
            guard firstLine > 0,
                  let start = range(forLine: firstLine, column: 1, in: text) else {
                return nil
            }
            let source = text as NSString
            var lineStart = start.location
            var currentLine = firstLine
            while currentLine < lastLine {
                let newline = source.range(
                    of: "\n",
                    range: NSRange(location: lineStart, length: source.length - lineStart)
                )
                guard newline.location != NSNotFound else {
                    return NSRange(location: start.location, length: max(0, source.length - start.location))
                }
                lineStart = NSMaxRange(newline)
                currentLine += 1
            }
            let endNewline = source.range(
                of: "\n",
                range: NSRange(location: lineStart, length: source.length - lineStart)
            )
            let lineEnd = endNewline.location == NSNotFound ? source.length : endNewline.location
            return NSRange(location: start.location, length: max(0, lineEnd - start.location))
        }
        return range(forLine: location.startLine, column: max(1, location.column ?? 1), in: text)
    }

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
