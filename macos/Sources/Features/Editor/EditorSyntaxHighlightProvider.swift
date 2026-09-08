import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

/// Adapts Tree-sitter captures to the pinned editor's limited color slots.
/// Its function/method slot aliases variables; typeAlternate is the separate
/// attributes slot. Keep this compatibility mapping at the OMG boundary.
@MainActor
final class EditorSyntaxHighlightProvider: HighlightProviding {
    private let parser = TreeSitterClient()
    private var isPython = false
    private static let pythonBuiltins = try? NSRegularExpression(
        pattern: #"\b(?:self|cls|int|float|bool|str|bytes|tuple|list|dict|set|frozenset|object|None|True|False)\b"#
    )

    static func renderTheme(_ source: EditorTheme) -> EditorTheme {
        var theme = source
        theme.attributes = source.commands
        theme.variables = source.text
        return theme
    }

    static func renderCapture(_ capture: CaptureName?) -> CaptureName? {
        switch capture {
        case .function, .method: return .typeAlternate
        case .constructor, .typeAlternate: return .type
        default: return capture
        }
    }

    static func resolvedHighlights(_ highlights: [HighlightRange]) -> [HighlightRange] {
        // The dependency can return both a specific capture and @variable for
        // the same token. Resolve those before the style store's last-write wins.
        func priority(_ capture: CaptureName?) -> Int {
            switch capture {
            case .variable, .parameter, .property, nil: return 0
            case .constructor, .type, .typeAlternate: return 1
            default: return 2
            }
        }
        var tokens: [NSRange: HighlightRange] = [:]
        for highlight in highlights {
            if let previous = tokens[highlight.range], priority(previous.capture) >= priority(highlight.capture) {
                continue
            }
            tokens[highlight.range] = highlight
        }
        return tokens.values.sorted { $0.range.location < $1.range.location }.map {
            HighlightRange(range: $0.range, capture: renderCapture($0.capture))
        }
    }

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        isPython = codeLanguage.id == .python
        parser.setUp(textView: textView, codeLanguage: codeLanguage)
    }

    func willApplyEdit(textView: TextView, range: NSRange) {
        parser.willApplyEdit(textView: textView, range: range)
    }

    func applyEdit(textView: TextView, range: NSRange, delta: Int,
                   completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void) {
        parser.applyEdit(textView: textView, range: range, delta: delta, completion: completion)
    }

    func queryHighlightsFor(textView: TextView, range: NSRange,
                            completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void) {
        let source = textView.string as NSString
        parser.queryHighlightsFor(textView: textView, range: range) { [self] result in
            completion(result.map { highlights in
                var resolved = Self.resolvedHighlights(highlights)
                if isPython, NSMaxRange(range) <= source.length {
                    // The pinned capture enum drops constant.builtin. Add the
                    // Python builtins only outside strings and comments.
                    Self.pythonBuiltins?.enumerateMatches(in: source as String, range: range) { match, _, _ in
                        guard let match, !resolved.contains(where: {
                            ($0.capture == .string || $0.capture == .comment) &&
                                NSIntersectionRange($0.range, match.range).length > 0
                        }) else { return }
                        let word = source.substring(with: match.range)
                        resolved.removeAll { $0.range == match.range }
                        resolved.append(HighlightRange(range: match.range,
                            capture: ["None", "True", "False"].contains(word) ? .number : .typeAlternate))
                    }
                }
                return resolved.sorted { $0.range.location < $1.range.location }
            })
        }
    }
}
