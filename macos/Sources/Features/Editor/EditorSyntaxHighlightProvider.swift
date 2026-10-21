import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftTreeSitter

/// Layers text colors so the pinned editor's limited capture slots keep OMG's
/// command/variable distinction.
@MainActor
final class EditorSyntaxHighlightProvider: HighlightProviding {
    private let parser = TreeSitterClient()
    private var isPython = false
    private static let pythonBuiltins = try? NSRegularExpression(
        pattern: #"\b(?:self|cls|int|float|bool|str|bytes|tuple|list|dict|set|frozenset|object|None|True|False)\b"#
    )

    // Structural key detection for JSON and YAML.
    private var structuralParser: Parser?
    private var structuralLanguage: TreeSitterLanguage?
    private var cachedStructuralText: String?
    private var cachedStructuralCaptures: [HighlightRange] = []

    /// Node types whose `key` field should be painted as a key.
    private static let keyedNodeTypes: Set<String> = [
        "pair",                 // JSON
        "block_mapping_pair",   // YAML
        "flow_mapping",         // YAML
    ]

    /// Literal and escape nodes that `CaptureName` has no slot for.
    ///
    /// The grammars capture JSON/YAML `true`, `false` and `null` as
    /// `constant.builtin`, and string escapes as `escape`. `fromString` returns
    /// nil for both names, so those captures are silently dropped and the
    /// tokens render as plain text.
    /// JSON names these nodes after the literal itself; YAML uses `_scalar`.
    private static let booleanNodeTypes: Set<String> = ["true", "false", "boolean", "boolean_scalar"]
    private static let nullNodeTypes: Set<String> = ["null", "null_scalar"]
    private static let escapeNodeTypes: Set<String> = ["escape_sequence"]

    /// Normalizes a theme before it reaches the editor.
    ///
    /// The editor derives minimap contrast from `background.brightnessComponent`,
    /// which raises `NSInvalidArgumentException` for colors in the generic gray
    /// space (notably `NSColor.clear`) and terminates the process. The workspace
    /// paints one shared backdrop anyway, so pin a transparent sRGB background
    /// here rather than trusting every theme source to pick a usable space.
    static func renderTheme(_ source: EditorTheme) -> EditorTheme {
        var theme = source
        theme.background = EditorTheme.transparentBackground
        theme.attributes = source.commands
        theme.variables = source.text
        return theme
    }

    static func renderCapture(_ capture: CaptureName?) -> CaptureName? {
        switch capture {
        // Function/method share the variable slot, so keep them distinct by
        // routing them to the type-alt slot the theme maps to `attributes`.
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
        // The JSON and YAML grammars capture keys as `string.special.key` and
        // `property`, but `CaptureName.fromString` has no case for the former, so
        // that capture is dropped and the grammar's plain `(string) @string` rule
        // then paints the same node as a string value. Keys therefore had no way
        // to look different from values. Keep a second parser so keys can be
        // identified structurally and given their own slot.
        if codeLanguage.id == .json || codeLanguage.id == .yaml,
           let language = codeLanguage.language {
            let structural = Parser()
            if (try? structural.setLanguage(language)) != nil {
                structuralParser = structural
                structuralLanguage = codeLanguage.id
            } else {
                structuralParser = nil
                structuralLanguage = nil
            }
        } else {
            structuralParser = nil
            structuralLanguage = nil
        }
        cachedStructuralText = nil
        cachedStructuralCaptures = []
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
                var resolved = Self.resolvedHighlights(highlights)                // Give structural keys their own slot. The grammars report keys
                // as plain `string` (JSON) or `property` (YAML), and `property`
                // maps to the same color as values, so keys and values are
                // indistinguishable without this pass.
                if structuralLanguage != nil, NSMaxRange(range) <= source.length {
                    resolved = Self.applyStructuralCaptures(resolved, from: structuralCaptures(in: source),
                                                            in: range)
                }
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

    /// Structural captures for the current buffer, cached per document text.
    private func structuralCaptures(in source: NSString) -> [HighlightRange] {
        if let cachedStructuralText, cachedStructuralText == source as String {
            return cachedStructuralCaptures
        }
        guard let structuralParser, let tree = structuralParser.parse(source as String) else { return [] }
        var captured: [HighlightRange] = []
        Self.collectStructuralCaptures(node: tree.rootNode, into: &captured)
        cachedStructuralText = source as String
        cachedStructuralCaptures = captured
        return captured
    }

    private static func collectStructuralCaptures(node: Node?, into captured: inout [HighlightRange]) {
        guard let node else { return }
        if let type = node.nodeType {
            if keyedNodeTypes.contains(type),
               let key = node.child(byFieldName: "key"), key.isNamed, key.range.length > 0 {
                captured.append(HighlightRange(range: key.range, capture: .type))
            } else if booleanNodeTypes.contains(type) {
                captured.append(HighlightRange(range: node.range, capture: .boolean))
            } else if nullNodeTypes.contains(type) {
                captured.append(HighlightRange(range: node.range, capture: .variableBuiltin))
            } else if escapeNodeTypes.contains(type) {
                captured.append(HighlightRange(range: node.range, capture: .number))
            }
        }
        for index in 0..<node.childCount {
            collectStructuralCaptures(node: node.child(at: index), into: &captured)
        }
    }

    /// Merges structural captures over the grammar's own results.
    ///
    /// A key is also a string node, so the stock captures cover the exact same
    /// ranges. Those have to be dropped first: the style container resolves
    /// same-length runs by provider priority, not by the capture we send, so
    /// leaving both would let `@string` win.
    private static func applyStructuralCaptures(_ resolved: [HighlightRange],
                                                from structural: [HighlightRange],
                                                in range: NSRange) -> [HighlightRange] {
        let scoped = structural.filter { NSIntersectionRange($0.range, range).length > 0 }
        guard !scoped.isEmpty else { return resolved }
        let shadowed = Set(scoped.map { NSValue(range: $0.range) })
        var merged = resolved.filter { highlight in
            !shadowed.contains(NSValue(range: highlight.range))
                && !scoped.contains { NSIntersectionRange($0.range, highlight.range).length > 0 }
        }
        merged.append(contentsOf: scoped)
        return merged.sorted { $0.range.location < $1.range.location }
    }
}
