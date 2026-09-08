import AppKit
import Foundation
import SwiftUI

/// Semantic category for code completion items.
public enum CompletionItemKind: String, Codable, Sendable, CaseIterable {
    case keyword
    case function
    case variable
    case type
    case property
    case snippet
    case text

    public var symbol: String {
        switch self {
        case .keyword: "K"
        case .function: "f"
        case .variable: "v"
        case .type: "T"
        case .property: "p"
        case .snippet: "S"
        case .text: "w"
        }
    }

    public var color: Color {
        switch self {
        case .keyword: .purple
        case .function: .blue
        case .variable: .red
        case .type: .yellow
        case .property: .cyan
        case .snippet: .orange
        case .text: .secondary
        }
    }
}

/// A candidate suggestion presented in the completion popup.
public struct CompletionItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let label: String
    public let insertText: String
    public let kind: CompletionItemKind
    public let detail: String?
    public let score: Double

    public init(
        label: String,
        insertText: String? = nil,
        kind: CompletionItemKind = .text,
        detail: String? = nil,
        score: Double = 0
    ) {
        self.id = UUID()
        self.label = label
        self.insertText = insertText ?? label
        self.kind = kind
        self.detail = detail
        self.score = score
    }

    public static func == (lhs: CompletionItem, rhs: CompletionItem) -> Bool {
        lhs.label == rhs.label && lhs.insertText == rhs.insertText && lhs.kind == rhs.kind
    }
}

/// Context snapshot passed to pluggable completion providers.
public struct CompletionContext: Sendable {
    public let documentText: String
    public let cursorOffset: Int
    public let prefix: String
    public let lineText: String
    public let language: String?
    public let fileURL: URL?

    var memberReceiver: String? {
        Self.memberReceiver(in: documentText as NSString, prefixStart: cursorOffset - prefix.utf16.count)
    }

    static func memberReceiver(in text: NSString, prefixStart: Int) -> String? {
        guard prefixStart > 1, prefixStart <= text.length,
              text.character(at: prefixStart - 1) == 46 else { return nil }
        let beforeDot = text.substring(to: prefixStart - 1)
        guard let range = beforeDot.range(of: #"[\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}_$][\p{L}\p{N}_$]*)*$"#,
                                         options: .regularExpression) else { return nil }
        return String(beforeDot[range])
    }

    public init(
        documentText: String,
        cursorOffset: Int,
        prefix: String,
        lineText: String,
        language: String?,
        fileURL: URL?
    ) {
        self.documentText = documentText
        self.cursorOffset = cursorOffset
        self.prefix = prefix
        self.lineText = lineText
        self.language = language
        self.fileURL = fileURL
    }
}

/// Pluggable completion source protocol.
///
/// Implement this protocol to add custom completion sources such as LSP,
/// buffer word extractors, snippet engines, or remote plugin bridges.
public protocol CompletionProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var priority: Int { get }

    func provideCompletions(context: CompletionContext) async -> [CompletionItem]
}

/// Fast word completion provider that extracts unique identifier tokens from the current buffer.
public struct BufferWordCompletionProvider: CompletionProvider, Sendable {
    public let id = "builtin.buffer"
    public let name = "Buffer Words"
    public let priority = 50

    public init() {}

    private static let wordPattern = try? NSRegularExpression(pattern: #"[\p{L}_$][\p{L}\p{N}_$]*"#)

    public func provideCompletions(context: CompletionContext) async -> [CompletionItem] {
        let prefix = context.prefix
        if let receiver = context.memberReceiver {
            let members = memberCompletions(context: context, receiver: receiver)
            if !members.isEmpty { return members }
        }
        guard !prefix.isEmpty || context.memberReceiver != nil, !Task.isCancelled else { return [] }

        let text = context.documentText
        var frequencies: [String: Int] = [:]
        var minOffsets: [String: Int] = [:]

        let nsText = text as NSString
        let lowerPrefix = prefix.lowercased()
        let cursorStart = max(0, context.cursorOffset - prefix.utf16.count)
        Self.wordPattern?.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            // Do not suggest the incomplete token being typed as its own source.
            guard match.range != NSRange(location: cursorStart, length: prefix.utf16.count) else { return }
            let word = nsText.substring(with: match.range)
            guard word.lowercased().hasPrefix(lowerPrefix) else { return }
            frequencies[word, default: 0] += 1
            let distance = abs(match.range.location - context.cursorOffset)
            minOffsets[word] = min(minOffsets[word] ?? Int.max, distance)
        }
        guard !Task.isCancelled else { return [] }

        var results: [CompletionItem] = []

        for (word, count) in frequencies {
            let lowerWord = word.lowercased()
            if lowerWord.hasPrefix(lowerPrefix) {
                let exactPrefix = word.hasPrefix(prefix)
                let distance = minOffsets[word] ?? 5000
                let distanceScore = max(0, 1.0 - Double(distance) / 10_000.0)
                let freqScore = min(Double(count) * 0.1, 1.0)
                let score = (exactPrefix ? 100.0 : 80.0) + distanceScore * 10.0 + freqScore * 5.0
                results.append(CompletionItem(label: word, kind: .text, detail: "buffer", score: score))
            }
        }

        return results
    }

    private func memberCompletions(context: CompletionContext, receiver: String) -> [CompletionItem] {
        // A lexical fallback: only members seen on this receiver in this file.
        // It deliberately does not claim type inference or cross-file knowledge.
        let escaped = NSRegularExpression.escapedPattern(for: receiver)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_$.])"# + escaped + #"\.([\p{L}_$][\p{L}\p{N}_$]*)"#
        ) else { return [] }
        let text = context.documentText as NSString
        let typedRange = NSRange(location: context.cursorOffset - context.prefix.utf16.count,
                                 length: context.prefix.utf16.count)
        var names = Set<String>()
        regex.enumerateMatches(in: context.documentText, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match, match.range(at: 1) != typedRange else { return }
            let name = text.substring(with: match.range(at: 1))
            if name.lowercased().hasPrefix(context.prefix.lowercased()) { names.insert(name) }
        }
        return names.sorted().map { CompletionItem(label: $0, kind: .property, detail: "buffer", score: 100) }
    }
}

/// Static keyword completion provider for known programming languages.
public struct LanguageKeywordCompletionProvider: CompletionProvider, Sendable {
    public let id = "builtin.keywords"
    public let name = "Language Keywords"
    public let priority = 80

    public init() {}

    private static let keywordsByLanguage: [String: [String]] = [
        "swift": [
            "import", "func", "var", "let", "struct", "class", "enum", "protocol", "extension",
            "init", "deinit", "self", "Self", "guard", "if", "else", "switch", "case", "default",
            "for", "while", "repeat", "break", "continue", "return", "throw", "throws", "try",
            "catch", "async", "await", "actor", "public", "private", "fileprivate", "internal",
            "open", "static", "mutating", "nonmutating", "weak", "unowned", "override", "final",
            "some", "any", "where"
        ],
        "python": [
            "def", "class", "import", "from", "as", "return", "yield", "if", "elif", "else",
            "for", "while", "break", "continue", "try", "except", "finally", "raise", "with",
            "assert", "async", "await", "lambda", "pass", "global", "nonlocal", "True", "False", "None"
        ],
        "rust": [
            "fn", "let", "mut", "struct", "enum", "trait", "impl", "pub", "mod", "use",
            "crate", "self", "Self", "if", "else", "match", "loop", "while", "for", "in",
            "return", "break", "continue", "async", "await", "move", "where", "type", "const",
            "static", "unsafe"
        ],
        "go": [
            "package", "import", "func", "return", "var", "const", "type", "struct", "interface",
            "if", "else", "switch", "case", "default", "for", "range", "break", "continue",
            "fallthrough", "go", "defer", "select", "chan", "map", "nil", "true", "false"
        ],
        "javascript": [
            "function", "const", "let", "var", "class", "interface", "type", "extends", "import",
            "export", "from", "default", "return", "if", "else", "switch", "case", "for", "while",
            "do", "break", "continue", "try", "catch", "finally", "throw", "new", "this", "async",
            "await", "yield", "typeof", "instanceof", "null", "undefined", "true", "false"
        ],
        "typescript": [
            "function", "const", "let", "var", "class", "interface", "type", "extends", "implements",
            "import", "export", "from", "default", "return", "if", "else", "switch", "case", "for",
            "while", "do", "break", "continue", "try", "catch", "finally", "throw", "new", "this",
            "async", "await", "yield", "typeof", "instanceof", "null", "undefined", "true", "false",
            "namespace", "declare", "readonly", "as", "keyof"
        ],
        "c": [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
            "enum", "extern", "float", "for", "goto", "if", "int", "long", "register", "return",
            "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
            "void", "volatile", "while"
        ],
        "cpp": [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
            "enum", "extern", "float", "for", "goto", "if", "int", "long", "register", "return",
            "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
            "void", "volatile", "while", "class", "namespace", "template", "typename", "public",
            "protected", "private", "virtual", "constexpr", "nullptr", "true", "false"
        ],
        "bash": [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until",
            "do", "done", "in", "function", "time", "return", "exit", "export", "local", "readonly"
        ]
    ]

    public func provideCompletions(context: CompletionContext) async -> [CompletionItem] {
        let prefix = context.prefix
        guard prefix.count >= 1, context.memberReceiver == nil else { return [] }

        let language = context.language?.lowercased() ?? ""
        let aliases = ["c++": "cpp", "cxx": "cpp", "js": "javascript", "jsx": "javascript",
                       "ts": "typescript", "tsx": "typescript", "sh": "bash", "shell": "bash"]
        let langKey = aliases[language] ?? language
        guard let keywordList = Self.keywordsByLanguage[langKey] else { return [] }

        let lowerPrefix = prefix.lowercased()
        var results: [CompletionItem] = []

        for kw in keywordList {
            let lowerKw = kw.lowercased()
            if lowerKw.hasPrefix(lowerPrefix) {
                let exactPrefix = kw.hasPrefix(prefix)
                let score = exactPrefix ? 150.0 : 120.0
                results.append(CompletionItem(label: kw, kind: .keyword, detail: "keyword", score: score))
            }
        }

        return results
    }
}

/// Pluggable completion coordination engine.
///
/// Maintains an ordered list of providers, queries them asynchronously,
/// deduplicates suggestions, and formats the ranked result set.
@MainActor
public final class EditorCompletionEngine {
    public static let shared = EditorCompletionEngine()

    private var providers: [any CompletionProvider] = []

    public init() {
        register(provider: BufferWordCompletionProvider())
        register(provider: LanguageKeywordCompletionProvider())
    }

    public func register(provider: any CompletionProvider) {
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
        providers.sort { $0.priority > $1.priority }
    }

    public func unregister(providerID: String) {
        providers.removeAll { $0.id == providerID }
    }

    public func completions(for context: CompletionContext) async -> [CompletionItem] {
        guard !context.prefix.isEmpty || context.memberReceiver != nil else { return [] }

        var results: [CompletionItem] = []
        var seenLabels = Set<String>()

        for provider in providers {
            guard !Task.isCancelled else { return [] }
            let items = await provider.provideCompletions(context: context)
            guard !Task.isCancelled else { return [] }
            for item in items where !seenLabels.contains(item.label) {
                seenLabels.insert(item.label)
                results.append(item)
            }
        }

        results.sort {
            $0.score == $1.score ? $0.label < $1.label : $0.score > $1.score
        }
        return Array(results.prefix(15))
    }
}
