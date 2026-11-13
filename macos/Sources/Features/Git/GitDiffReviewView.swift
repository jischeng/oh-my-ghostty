import AppKit
import SwiftUI

/// Stable source ranges keep folding independent from displayed line numbers.
struct GitDiffReviewLayout {
    enum Item: Equatable {
        case row(Int)
        case folded(Range<Int>)
    }
    let items: [Item]

    init(rows: [GitDiffPresentation.Row], expanded: Set<Int>, context: Int = 3) {
        var visible = Set<Int>()
        for index in rows.indices where rows[index].added != nil {
            visible.formUnion(max(0, index - context)...min(rows.count - 1, index + context))
        }
        var result: [Item] = []
        var index = 0
        while index < rows.count {
            if visible.contains(index) {
                result.append(.row(index))
                index += 1
            } else {
                let start = index
                while index < rows.count && !visible.contains(index) { index += 1 }
                if expanded.contains(start) {
                    result += (start..<index).map(Item.row)
                } else {
                    result.append(.folded(start..<index))
                }
            }
        }
        items = result
    }
}

struct GitDiffReviewView: View {
    let presentation: GitDiffPresentation
    let before: String
    let after: String
    let path: String
    let theme: EditorTheme
    let split: Bool
    var selectedRow: Int?
    @AppStorage("git.diff.wordWrap") private var wordWrap = true
    @State private var measuredLineWidth: CGFloat = 0
    @Environment(\.gitCollectionColors) private var colors
    @State private var expanded: Set<Int> = []
    @State private var oldLines: [AttributedString] = []
    @State private var newLines: [AttributedString] = []

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let columnWidth = wordWrap
                    ? max(1, split ? (geometry.size.width - 1) / 2 : geometry.size.width)
                    : max(split ? (geometry.size.width - 1) / 2 : geometry.size.width,
                          measuredLineWidth + (split ? 72 : 148))
                let documentWidth = split ? columnWidth * 2 + 1 : columnWidth
                ScrollView(wordWrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(layout.items.enumerated()), id: \.offset) { _, item in
                            switch item {
                            case .folded(let range):
                                NativeActionButton(
                                    title: GitL10n.format("{0} unmodified lines", String(range.count)),
                                    symbol: range.lowerBound == 0 ? "chevron.up" : "chevron.down",
                                    help: GitL10n.text("Show unmodified lines"),
                                    style: .plain,
                                    height: 30,
                                    expands: true,
                                    action: { _ in expanded.insert(range.lowerBound) }
                                )
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                            case .row(let index):
                                line(presentation.rows[index], width: columnWidth).id(index)
                            }
                        }
                    }
                    .frame(width: documentWidth, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .onChange(of: selectedRow) { row in
                if let row { proxy.scrollTo(row, anchor: .center) }
            }
        }
        .task(id: before + "\0" + after) {
            expanded = []
            oldLines = []; newLines = []
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            measuredLineWidth = presentation.rows.reduce(CGFloat(0)) { width, row in
                max(width, ceil((row.text as NSString).size(withAttributes: [.font: font]).width))
            }
            let old = await highlighted(before)
            let new = await highlighted(after)
            guard !Task.isCancelled else { return }
            oldLines = old; newLines = new
        }
    }

    private var layout: GitDiffReviewLayout {
        GitDiffReviewLayout(rows: presentation.rows, expanded: expanded)
    }

    private func line(_ row: GitDiffPresentation.Row, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if split {
                source(row, old: true, width: width)
                source(row, old: false, width: width)
                    .padding(.leading, 1)
                    .overlay(alignment: .leading) { Color(colors.separator).frame(width: 1) }
            } else {
                number(row.beforeLine)
                number(row.afterLine)
                Text(row.added.map { $0 ? "+" : "−" } ?? " ")
                    .foregroundStyle(tint(row)).frame(width: 18)
                Text(attributed(row, old: row.added == false))
                    .textSelection(.enabled)
                    .frame(width: max(1, width - 148), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 18)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(width: split ? width * 2 + 1 : width, alignment: .leading)
        .frame(minHeight: 21, alignment: .top)
        .background(split ? Color.clear : tint(row).opacity(row.added == nil ? 0 : 0.12))
        .clipped()
    }

    private func source(_ row: GitDiffPresentation.Row, old: Bool, width: CGFloat) -> some View {
        let present = old ? row.beforeLine != nil : row.afterLine != nil
        return HStack(alignment: .top, spacing: 0) {
            number(old ? row.beforeLine : row.afterLine)
            Text(present ? attributed(row, old: old) : AttributedString(" "))
                .textSelection(.enabled)
                .frame(width: max(1, width - 72), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 21, alignment: .top)
        .background(tint(row).opacity(present && row.added != nil ? 0.12 : 0))
        .clipped()
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Color(colors.secondary).opacity(0.7))
            .frame(width: 48, alignment: .trailing).padding(.trailing, 8)
    }

    private func tint(_ row: GitDiffPresentation.Row) -> Color {
        Color(row.added.map { $0 ? colors.added : colors.deleted } ?? colors.text)
    }

    private func attributed(_ row: GitDiffPresentation.Row, old: Bool) -> AttributedString {
        let lines = old ? oldLines : newLines
        if let number = old ? row.beforeLine : row.afterLine, lines.indices.contains(number - 1) {
            return lines[number - 1]
        }
        var result = AttributedString(row.text.isEmpty ? " " : row.text)
        result.foregroundColor = Color(theme.text.color)
        return result
    }

    @MainActor private func highlighted(_ source: String) async -> [AttributedString] {
        GitDiffLexicalHighlighter.highlightLines(source: source, path: path, theme: theme)
    }
}

private enum GitDiffLexicalHighlighter {
    private static let keywords: Set<String> = [
        "import", "func", "let", "var", "struct", "class", "enum", "protocol", "extension",
        "actor", "return", "if", "else", "guard", "switch", "case", "default", "for", "while",
        "in", "where", "do", "try", "catch", "throw", "throws", "async", "await", "private",
        "public", "internal", "fileprivate", "open", "static", "final", "override", "mutating",
        "nonisolated", "some", "any", "init", "deinit", "defer", "self", "Self", "nil", "true",
        "false", "const", "pub", "fn", "comptime", "errdefer", "orelse", "unreachable", "type",
        "interface", "export", "from", "function", "new", "typeof", "void", "null", "undefined",
        "def", "lambda", "None", "True", "False", "impl", "trait", "mod", "use", "crate", "mut",
        "match", "package", "go", "select", "chan"
    ]

    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"(//[^\n]*|#(?!!\[)[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b0x[0-9a-fA-F_]+\b|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b)"#
    )

    static func highlightLines(source: String, path: String, theme: EditorTheme) -> [AttributedString] {
        guard !source.isEmpty else { return [AttributedString("")] }
        let nsSource = source as NSString
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: [.foregroundColor: theme.text.color]
        )
        let ext = (path as NSString).pathExtension.lowercased()
        let usesHashComments = ["py", "sh", "bash", "zsh", "nu", "yml", "yaml", "toml", "rb", "mk", "conf"]
            .contains(ext) || (path as NSString).lastPathComponent.lowercased() == "makefile"

        if let regex = tokenRegex {
            let fullRange = NSRange(location: 0, length: nsSource.length)
            regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.length > 0 else { return }
                let token = nsSource.substring(with: range)
                guard let first = token.first else { return }
                let color: NSColor?
                if token.hasPrefix("//") || token.hasPrefix("/*") {
                    color = theme.comments.color
                } else if first == "#" {
                    color = usesHashComments ? theme.comments.color : theme.keywords.color
                } else if first == "\"" || first == "'" || first == "`" {
                    color = theme.strings.color
                } else if first.isNumber {
                    color = theme.numbers.color
                } else if keywords.contains(token) {
                    color = theme.keywords.color
                } else if first.isUppercase {
                    color = theme.types.color
                } else {
                    let afterIndex = NSMaxRange(range)
                    if afterIndex < nsSource.length,
                       nsSource.character(at: afterIndex) == UInt16(UInt8(ascii: "(")) {
                        color = theme.commands.color
                    } else {
                        color = nil
                    }
                }
                if let color {
                    attributed.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }

        var offset = 0
        return source.components(separatedBy: "\n").map { line in
            let length = line.utf16.count
            defer { offset += length + 1 }
            guard offset + length <= attributed.length else {
                return AttributedString(line)
            }
            return AttributedString(
                attributed.attributedSubstring(from: NSRange(location: offset, length: length))
            )
        }
    }
}
