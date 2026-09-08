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

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
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
        parser.queryHighlightsFor(textView: textView, range: range) { result in
            completion(result.map { highlights in
                highlights.map { HighlightRange(range: $0.range, capture: Self.renderCapture($0.capture)) }
            })
        }
    }
}
