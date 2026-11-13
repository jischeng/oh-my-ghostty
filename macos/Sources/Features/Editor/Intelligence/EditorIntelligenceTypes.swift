import Foundation

/// 1-based line and 1-based UTF-16 column in an editor document.
public struct EditorPosition: Codable, Equatable, Hashable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = max(1, line)
        self.column = max(1, column)
    }

    public var zeroBasedLine: Int {
        max(0, line - 1)
    }

    public var zeroBasedColumn: Int {
        max(0, column - 1)
    }

    public static func fromZeroBased(line: Int, character: Int) -> EditorPosition {
        EditorPosition(line: max(1, line + 1), column: max(1, character + 1))
    }
}

/// 1-based inclusive start / exclusive-or-cursor end range shared with the Monaco JS bridge.
public struct EditorRange: Codable, Equatable, Hashable, Sendable {
    public let start: EditorPosition
    public let end: EditorPosition

    public init(start: EditorPosition, end: EditorPosition) {
        self.start = start
        if end.line < start.line || (end.line == start.line && end.column < start.column) {
            self.end = start
        } else {
            self.end = end
        }
    }

    public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.init(
            start: EditorPosition(line: startLine, column: startColumn),
            end: EditorPosition(line: endLine, column: endColumn)
        )
    }

    public var startLine: Int { start.line }
    public var startColumn: Int { start.column }
    public var endLine: Int { end.line }
    public var endColumn: Int { end.column }

    /// Converts to OMG's `EditorTextLocation` for `EditorWorkspace.open(path:filesystem:location:)`.
    var textLocation: EditorTextLocation {
        EditorTextLocation(
            startLine: start.line,
            column: start.column,
            endLine: end.line > start.line ? end.line : nil
        )
    }

    public var bridgeDictionary: [String: Int] {
        [
            "startLine": start.line,
            "startColumn": start.column,
            "endLine": end.line,
            "endColumn": end.column
        ]
    }
}

/// Target location for Go-to-Definition and Find-References results.
public struct EditorDefinitionLocation: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let range: EditorRange
    public let preview: String?

    public init(path: String, range: EditorRange, preview: String? = nil) {
        self.path = path
        self.range = range
        self.preview = preview
    }

    public var bridgeDictionary: [String: Any] {
        var dict: [String: Any] = [
            "path": path,
            "startLine": range.startLine,
            "startColumn": range.startColumn,
            "endLine": range.endLine,
            "endColumn": range.endColumn,
            "range": range.bridgeDictionary
        ]
        if let preview {
            dict["preview"] = preview
        }
        return dict
    }
}

/// Markdown hover card payload returned to Monaco's `HoverProvider`.
public struct EditorHoverInfo: Codable, Equatable, Hashable, Sendable {
    public let markdown: String
    public let range: EditorRange?

    public init(markdown: String, range: EditorRange? = nil) {
        self.markdown = markdown
        self.range = range
    }

    public var bridgeDictionary: [String: Any] {
        var dict: [String: Any] = ["markdown": markdown]
        if let range {
            dict["range"] = range.bridgeDictionary
            dict["startLine"] = range.startLine
            dict["startColumn"] = range.startColumn
            dict["endLine"] = range.endLine
            dict["endColumn"] = range.endColumn
        }
        return dict
    }
}

/// Diagnostic marker pushed by LSP (`textDocument/publishDiagnostics`) or static checks.
public struct EditorDiagnostic: Codable, Equatable, Hashable, Sendable {
    public enum Severity: String, Codable, Equatable, Hashable, Sendable {
        case error
        case warning
        case info
        case hint

        /// Monaco `MarkerSeverity` numeric value (`Hint = 1, Info = 2, Warning = 4, Error = 8`).
        public var monacoSeverity: Int {
            switch self {
            case .error: 8
            case .warning: 4
            case .info: 2
            case .hint: 1
            }
        }

        public static func fromLSP(_ code: Int?) -> Severity {
            switch code {
            case 1: .error
            case 2: .warning
            case 3: .info
            case 4: .hint
            default: .info
            }
        }
    }

    public let severity: Severity
    public let message: String
    public let source: String?
    public let range: EditorRange

    public init(severity: Severity, message: String, source: String? = nil, range: EditorRange) {
        self.severity = severity
        self.message = message
        self.source = source
        self.range = range
    }

    public var bridgeDictionary: [String: Any] {
        var dict: [String: Any] = [
            "severity": severity.rawValue,
            "monacoSeverity": severity.monacoSeverity,
            "message": message,
            "startLine": range.startLine,
            "startColumn": range.startColumn,
            "endLine": range.endLine,
            "endColumn": range.endColumn,
            "range": range.bridgeDictionary
        ]
        if let source {
            dict["source"] = source
        }
        return dict
    }
}

/// Document or workspace symbol used by `⌘⇧O` Go-to-Symbol, outline, and hover/definition fallback.
public struct EditorDocumentSymbol: Codable, Equatable, Hashable, Sendable {
    public enum SymbolKind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case file
        case module
        case namespace
        case package
        case `class`
        case method
        case property
        case field
        case constructor
        case `enum`
        case interface
        case function
        case variable
        case constant
        case string
        case number
        case boolean
        case array
        case object
        case key
        case null
        case enumMember
        case `struct`
        case event
        case `operator`
        case typeParameter
        case `protocol`
        case trait
        case heading

        /// Maps to Monaco's `languages.SymbolKind` enum values (0-based).
        public var monacoSymbolKind: Int {
            switch self {
            case .file: 0
            case .module: 1
            case .namespace: 2
            case .package: 3
            case .class: 4
            case .method: 5
            case .property: 6
            case .field: 7
            case .constructor: 8
            case .enum: 9
            case .interface, .protocol, .trait: 10
            case .function: 11
            case .variable: 12
            case .constant: 13
            case .string, .heading: 14
            case .number: 15
            case .boolean: 16
            case .array: 17
            case .object: 18
            case .key: 19
            case .null: 20
            case .enumMember: 21
            case .struct: 22
            case .event: 23
            case .operator: 24
            case .typeParameter: 25
            }
        }

        /// Maps from LSP 1-based `SymbolKind` integer (`1...26`).
        public static func fromLSP(_ code: Int) -> SymbolKind {
            switch code {
            case 1: .file
            case 2: .module
            case 3: .namespace
            case 4: .package
            case 5: .class
            case 6: .method
            case 7: .property
            case 8: .field
            case 9: .constructor
            case 10: .enum
            case 11: .interface
            case 12: .function
            case 13: .variable
            case 14: .constant
            case 15: .string
            case 16: .number
            case 17: .boolean
            case 18: .array
            case 19: .object
            case 20: .key
            case 21: .null
            case 22: .enumMember
            case 23: .struct
            case 24: .event
            case 25: .operator
            case 26: .typeParameter
            default: .variable
            }
        }
    }

    public let name: String
    public let detail: String?
    public let kind: SymbolKind
    public let range: EditorRange
    public let selectionRange: EditorRange

    public init(
        name: String,
        detail: String? = nil,
        kind: SymbolKind,
        range: EditorRange,
        selectionRange: EditorRange
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
    }

    public var bridgeDictionary: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "kind": kind.rawValue,
            "monacoKind": kind.monacoSymbolKind,
            "range": range.bridgeDictionary,
            "selectionRange": selectionRange.bridgeDictionary,
            "startLine": range.startLine,
            "startColumn": range.startColumn,
            "endLine": range.endLine,
            "endColumn": range.endColumn
        ]
        if let detail {
            dict["detail"] = detail
        }
        return dict
    }
}

/// Line-level Git working-tree diff classification for Monaco gutter bars.
public enum EditorGutterLineKind: String, Codable, Equatable, Hashable, Sendable {
    case added
    case modified
    case deleted
}

/// Canonical language detection shared by LSP, SymbolIndex, and Completion providers.
public enum EditorLanguageID {
    private static let extensionMap: [String: String] = [
        "swift": "swift",
        "zig": "zig",
        "zon": "zig",
        "rs": "rust",
        "go": "go",
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "typescriptreact",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascriptreact",
        "py": "python",
        "pyi": "python",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "c++": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "hxx": "cpp",
        "m": "objective-c",
        "mm": "objective-cpp",
        "md": "markdown",
        "markdown": "markdown",
        "sh": "shellscript",
        "bash": "shellscript",
        "zsh": "shellscript",
        "nu": "nushell",
        "json": "json",
        "jsonc": "jsonc",
        "toml": "toml",
        "yaml": "yaml",
        "yml": "yaml",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "sql": "sql",
        "xml": "xml",
        "plist": "xml",
        "lua": "lua",
        "rb": "ruby",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin"
    ]

    public static func detect(path: String, explicitHint: String? = nil) -> String {
        if let explicitHint {
            let trimmed = explicitHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty, trimmed != "plaintext" {
                return normalizeHint(trimmed)
            }
        }
        let filename = (path as NSString).lastPathComponent.lowercased()
        if filename == "makefile" || filename == "gnumakefile" {
            return "makefile"
        }
        if filename == "dockerfile" || filename.hasPrefix("dockerfile.") {
            return "dockerfile"
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return extensionMap[ext] ?? "plaintext"
    }

    public static func isIndexableSourceFile(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let lang = extensionMap[ext] else { return false }
        switch lang {
        case "swift", "zig", "rust", "go", "typescript", "typescriptreact",
             "javascript", "javascriptreact", "python", "c", "cpp",
             "objective-c", "objective-cpp", "markdown", "shellscript",
             "lua", "ruby", "java", "kotlin":
            return true
        default:
            return false
        }
    }

    /// Server grouping key so `.ts`/`.tsx`/`.js`/`.jsx` share one TS server per workspace,
    /// and `.c`/`.cpp`/`.h`/`.hpp` share one `clangd` server per workspace.
    public static func lspServerGroup(for languageID: String) -> String? {
        switch normalizeHint(languageID) {
        case "swift":
            return "swift"
        case "zig":
            return "zig"
        case "rust":
            return "rust"
        case "go":
            return "go"
        case "typescript", "typescriptreact", "javascript", "javascriptreact":
            return "typescript"
        case "python":
            return "python"
        case "c", "cpp", "objective-c", "objective-cpp":
            return "clangd"
        default:
            return nil
        }
    }

    public static func normalizeHint(_ hint: String) -> String {
        switch hint.lowercased() {
        case "ts": "typescript"
        case "tsx": "typescriptreact"
        case "js": "javascript"
        case "jsx": "javascriptreact"
        case "py": "python"
        case "rs": "rust"
        case "c++", "cxx", "cc": "cpp"
        case "sh", "bash", "zsh", "shell": "shellscript"
        case "md": "markdown"
        default: hint.lowercased()
        }
    }
}
