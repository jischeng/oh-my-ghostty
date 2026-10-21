import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftTreeSitter

/// A Tree-sitter highlight provider that follows Zed's capture model.
///
/// Zed queries languages with dotted, hierarchy-aware capture names
/// (`property.json_key`, `string.escape`, `punctuation.delimiter`) and resolves
/// each name against the theme by walking dot-separated prefixes from longest to
/// shortest. `CodeEditSourceEditor` instead funnels every capture through
/// `CaptureName`, a fixed 21-case enum whose `fromString` returns nil for
/// anything it does not know — so those captures are dropped and the tokens fall
/// back to plain text.
///
/// This provider keeps the editor's pipeline but replaces the query and the
/// name resolution for languages where the pinned grammars are too coarse. It
/// runs the same query files Zed ships, keeps the dotted capture names intact,
/// and maps them onto the slots the pinned theme can actually express.
@MainActor
final class EditorSyntaxHighlightProvider: HighlightProviding {
    private let parser = TreeSitterClient()
    private var isPython = false
    private static let pythonBuiltins = try? NSRegularExpression(
        pattern: #"\b(?:self|cls|int|float|bool|str|bytes|tuple|list|dict|set|frozenset|object|None|True|False)\b"#
    )

    // Dotted-capture querying for languages whose stock highlighting is coarse.
    private var dottedParser: Parser?
    private var dottedQuery: Query?
    private var cachedDottedText: String?
    private var cachedDottedCaptures: [HighlightRange] = []

    /// Capture names, in Zed's spelling, that this provider resolves itself.
    ///
    /// Keyed by the grammar this checkout ships, which is what the tree is
    /// parsed with; the query text is copied from Zed's grammars so the two
    /// stay comparable. Zed's own files also carry `@punctuation.*`, which the
    /// pinned theme cannot express, so they are listed but mapped to nil.
    private static let queries: [TreeSitterLanguage: String] = [
        .json: """
        (comment) @comment
        (string) @string
        (escape_sequence) @string.escape
        (pair
          key: (string) @property.json_key)
        (number) @number
        [
          (true)
          (false)
        ] @boolean
        (null) @constant.builtin
        [
          ","
          ":"
        ] @punctuation.delimiter
        [
          "{"
          "}"
          "["
          "]"
        ] @punctuation.bracket
        """,
        .yaml: """
        (boolean_scalar) @boolean
        (null_scalar) @constant.builtin
        [
          (double_quote_scalar)
          (single_quote_scalar)
          (block_scalar)
          (string_scalar)
        ] @string
        (escape_sequence) @string.escape
        [
          (integer_scalar)
          (float_scalar)
        ] @number
        (comment) @comment
        [
          (anchor_name)
          (alias_name)
          (tag)
        ] @type
        key: (flow_node
          [
            (plain_scalar
              (string_scalar))
            (double_quote_scalar)
            (single_quote_scalar)
          ] @property)
        [
          ","
          "-"
          ":"
          ">"
          "?"
          "|"
        ] @punctuation.delimiter
        [
          "["
          "]"
          "{"
          "}"
        ] @punctuation.bracket
        [
          "*"
          "&"
          "---"
          "..."
        ] @punctuation.special
        """,
    ]

    /// Adapts Zed's capture vocabulary to the editor's fixed slots.
    ///
    /// Resolution walks the dotted prefixes longest-first, exactly as
    /// `SyntaxTheme::highlight_id` does in Zed, so `property.json_key` finds
    /// `property` and `string.escape` finds `string` when no more specific slot
    /// exists. A nil result means the theme has nothing to say and the token
    /// keeps whatever the grammar already gave it.
    /// Exposed for tests; production callers go through the query path.
    static func slot(for captureName: String) -> CaptureName? {
        func lookup(_ name: String) -> CaptureName? {
            switch name {
            case "property", "property.json_key": return .type
            case "string.escape": return .number
            case "string": return .string
            case "number": return .number
            case "boolean": return .boolean
            case "constant.builtin", "constant": return .variableBuiltin
            case "comment": return .comment
            case "type": return .type
            case "keyword": return .keyword
            case "function", "function.method": return .typeAlternate
            case "variable": return .variable
            default: return nil
            }
        }
        var prefix = captureName
        while true {
            if let slot = lookup(prefix) { return slot }
            guard let dot = prefix.lastIndex(of: ".") else { return nil }
            prefix = String(prefix[prefix.startIndex..<dot])
        }
    }

    /// Query result for one capture, or nil when the theme cannot express it.
    private struct DottedCapture {
        let range: NSRange
        let capture: CaptureName?
    }

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
        dottedParser = nil
        dottedQuery = nil
        cachedDottedText = nil
        cachedDottedCaptures = []
        guard let source = Self.queries[codeLanguage.id],
              let language = codeLanguage.language,
              let query = try? Query(language: language, data: Data(source.utf8)) else { return }
        let dotted = Parser()
        guard (try? dotted.setLanguage(language)) != nil else { return }
        dottedParser = dotted
        dottedQuery = query
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
                if dottedQuery != nil, NSMaxRange(range) <= source.length {
                    resolved = Self.mergeDottedCaptures(resolved, from: dottedCaptures(in: source), in: range)
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

    /// Runs the dotted query over the buffer, cached per document text.
    private func dottedCaptures(in source: NSString) -> [DottedCapture] {
        if let cachedDottedText, cachedDottedText == source as String {
            return cachedDottedCaptures.map { DottedCapture(range: $0.range, capture: $0.capture) }
        }
        guard let dottedParser, let dottedQuery,
              let tree = dottedParser.parse(source as String) else { return [] }
        // Zed's queries deliberately capture the same node twice: a JSON key is
        // both `(string) @string` and `key: (string) @property.json_key`. Keep the
        // most specific name per range so the key slot wins over the string slot,
        // mirroring the prefix walk in `slot(for:)`.
        var best: [NSRange: (depth: Int, capture: CaptureName?)] = [:]
        for match in dottedQuery.execute(in: tree) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                let depth = name.split(separator: ".").count
                if let existing = best[capture.node.range], existing.depth >= depth { continue }
                best[capture.node.range] = (depth, Self.slot(for: name))
            }
        }
        let captures = best.map { DottedCapture(range: $0.key, capture: $0.value.capture) }
            .sorted { $0.range.location < $1.range.location }
        cachedDottedText = source as String
        cachedDottedCaptures = captures.compactMap { capture in
            capture.capture.map { HighlightRange(range: capture.range, capture: $0) }
        }
        return captures
    }

    /// Overlays the dotted query's captures on the stock ones.
    ///
    /// The dotted query is authoritative where it speaks: a key is also a string
    /// node, so the stock run covers the same range and the style container
    /// would otherwise resolve the tie by provider order, not by our intent.
    /// Captures that map to no slot are skipped so the grammar keeps styling
    /// those tokens.
    private static func mergeDottedCaptures(_ resolved: [HighlightRange],
                                            from dotted: [DottedCapture],
                                            in range: NSRange) -> [HighlightRange] {
        let scoped = dotted.filter {
            $0.capture != nil && NSIntersectionRange($0.range, range).length > 0
        }
        guard !scoped.isEmpty else { return resolved }
        let shadowed = Set(scoped.map { NSValue(range: $0.range) })
        var merged = resolved.filter { highlight in
            guard !shadowed.contains(NSValue(range: highlight.range)) else { return false }
            return !scoped.contains { NSIntersectionRange($0.range, highlight.range).length > 0 }
        }
        merged.append(contentsOf: scoped.map {
            HighlightRange(range: $0.range, capture: $0.capture ?? .string)
        })
        return merged.sorted { $0.range.location < $1.range.location }
    }
}
