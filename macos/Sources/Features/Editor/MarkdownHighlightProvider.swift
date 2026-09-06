import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation

/// A lightweight syntax highlight provider for Markdown files in the native editor.
@MainActor
final class MarkdownHighlightProvider: HighlightProviding {
    private weak var textView: TextView?
    private var isMarkdown = false

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        self.textView = textView
        self.isMarkdown = codeLanguage.id == .markdown || codeLanguage.id == .markdownInline
    }

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        guard isMarkdown else {
            completion(.success(IndexSet()))
            return
        }
        let fullLength = textView.textStorage.length
        completion(.success(IndexSet(integersIn: 0..<fullLength)))
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        guard isMarkdown,
              range.location != NSNotFound,
              NSMaxRange(range) <= textView.textStorage.length else {
            completion(.success([]))
            return
        }
        let string = textView.string as NSString
        let lineRange = string.lineRange(for: range)
        let slice = string.substring(with: lineRange)
        var results: [HighlightRange] = []

        let baseOffset = lineRange.location
        var lineStart = 0
        while lineStart < slice.utf16.count {
            let currentLineRange = (slice as NSString).lineRange(for: NSRange(location: lineStart, length: 0))
            let lineText = (slice as NSString).substring(with: currentLineRange)
            let trimmed = lineText.trimmingCharacters(in: .newlines)
            let lineGlobalOffset = baseOffset + currentLineRange.location

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                if hashes.count <= 6, trimmed.dropFirst(hashes.count).hasPrefix(" ") {
                    results.append(HighlightRange(
                        range: NSRange(location: lineGlobalOffset, length: hashes.count),
                        capture: .keyword
                    ))
                    let contentLen = (trimmed as NSString).length - hashes.count
                    if contentLen > 0 {
                        results.append(HighlightRange(
                            range: NSRange(location: lineGlobalOffset + hashes.count, length: contentLen),
                            capture: .type
                        ))
                    }
                }
            } else if trimmed.hasPrefix(">") {
                results.append(HighlightRange(
                    range: NSRange(location: lineGlobalOffset, length: (trimmed as NSString).length),
                    capture: .comment
                ))
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                results.append(HighlightRange(
                    range: NSRange(location: lineGlobalOffset, length: (trimmed as NSString).length),
                    capture: .keyword
                ))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                results.append(HighlightRange(
                    range: NSRange(location: lineGlobalOffset, length: 2),
                    capture: .keyword
                ))
            } else if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                let prefixLen = (trimmed.components(separatedBy: " ").first?.count ?? 0) + 1
                results.append(HighlightRange(
                    range: NSRange(location: lineGlobalOffset, length: prefixLen),
                    capture: .keyword
                ))
            }

            if lineText.contains("`") {
                let pattern = try? NSRegularExpression(pattern: "`([^`]+)`")
                let matches = pattern?.matches(
                    in: lineText,
                    range: NSRange(location: 0, length: (lineText as NSString).length)
                ) ?? []
                for match in matches {
                    results.append(HighlightRange(
                        range: NSRange(location: lineGlobalOffset + match.range.location, length: match.range.length),
                        capture: .string
                    ))
                }
            }

            if lineText.contains("[") && lineText.contains("](") {
                let pattern = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)")
                let matches = pattern?.matches(
                    in: lineText,
                    range: NSRange(location: 0, length: (lineText as NSString).length)
                ) ?? []
                for match in matches where match.numberOfRanges >= 3 {
                    let titleRange = match.range(at: 1)
                    let urlRange = match.range(at: 2)
                    results.append(HighlightRange(
                        range: NSRange(location: lineGlobalOffset + titleRange.location, length: titleRange.length),
                        capture: .string
                    ))
                    results.append(HighlightRange(
                        range: NSRange(location: lineGlobalOffset + urlRange.location, length: urlRange.length),
                        capture: .function
                    ))
                }
            }

            if lineText.contains("**") {
                let pattern = try? NSRegularExpression(pattern: "\\*\\*([^\\*]+)\\*\\*")
                let matches = pattern?.matches(
                    in: lineText,
                    range: NSRange(location: 0, length: (lineText as NSString).length)
                ) ?? []
                for match in matches {
                    results.append(HighlightRange(
                        range: NSRange(location: lineGlobalOffset + match.range.location, length: match.range.length),
                        capture: .type
                    ))
                }
            }

            lineStart = currentLineRange.location + currentLineRange.length
        }

        completion(.success(results))
    }
}
