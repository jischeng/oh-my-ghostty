import Foundation

/// Turns raw model output into a tab-sized title: one clean line, no markdown,
/// quoting, or baked-in ellipses, bounded to `maxWidth` display columns (wide CJK
/// characters count as two). AppKit's `NSTextField` handles visual width truncation.
enum AITitleSanitizer {
    /// Guardrail against runaway model sentences; fits concise English or CJK titles cleanly.
    static let maxWidth = 36

    private static let titlePrefixes = ["title:", "标题：", "标题:", "会话标题：", "会话标题:"]

    static func sanitize(_ raw: String, maxWidth: Int = maxWidth) -> String? {
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var text = clean(String(line))
            guard !text.isEmpty else { continue }
            // Markdown first: removing a leading "*" as a list marker would orphan its pair.
            text = stripMarkdown(text)
            text = stripPrefixes(text)
            text = stripMarkdown(text)
            text = trimEdgePunctuation(text)
            guard !text.isEmpty else { continue }
            return truncate(text, maxWidth: maxWidth)
        }
        return nil
    }

    /// Removes control and invisible formatting characters, then collapses whitespace.
    private static func clean(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where !scalar.properties.isWhitespace, .format:
                continue
            case .control:
                scalars.append(" ")
            case .lineSeparator, .paragraphSeparator, .spaceSeparator:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func stripPrefixes(_ text: String) -> String {
        var text = text
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for prefix in titlePrefixes where lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                changed = true
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        // Backticks are handled as a wrapping pair in `stripMarkdown`.
        for marker in ["#", "-", "*", "•"] {
            while text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private static func stripMarkdown(_ text: String) -> String {
        var text = text
        // [label](target) keeps only the label.
        while let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]"),
              text.index(after: close) < text.endIndex, text[text.index(after: close)] == "(",
              let end = text[text.index(after: close)...].firstIndex(of: ")") {
            text.replaceSubrange(open...end, with: text[text.index(after: open)..<close])
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        var wrapped = Substring(text)
        var changed = true
        while changed {
            changed = false
            let quotes: [(Character, Character)] = [("\"" as Character, "\"" as Character),
                                                    ("'" as Character, "'" as Character),
                                                    ("“" as Character, "”" as Character),
                                                    ("‘" as Character, "’" as Character),
                                                    ("「" as Character, "」" as Character),
                                                    ("`" as Character, "`" as Character)]
            for (leading, trailing) in quotes
            where wrapped.count >= 2 && wrapped.first == leading && wrapped.last == trailing {
                wrapped = String(wrapped).dropFirst().dropLast()
                changed = true
            }
            for marker: Character in ["*", "_"]
            where wrapped.count >= 3 && wrapped.first == marker && wrapped.last == marker
                && wrapped.dropFirst().dropLast().contains(marker) == false
                && wrapped.dropFirst().first?.isWhitespace == false
                && wrapped.dropLast().last?.isWhitespace == false {
                wrapped = String(wrapped).dropFirst().dropLast()
                changed = true
            }
        }
        return wrapped.trimmingCharacters(in: .whitespaces)
    }

    private static func trimEdgePunctuation(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        let trailing: Set<Character> = [
            ".", "。", "…", "⋯", "!", "！", ",", "，", ";", "；", ":", "：", "、",
        ]
        while let last = text.last {
            if trailing.contains(last) || last.isWhitespace {
                text.removeLast()
            } else {
                break
            }
        }
        let leading: Set<Character> = [",", "，", ";", "；", ".", "…", "⋯"]
        while let first = text.first {
            if leading.contains(first) || first.isWhitespace {
                text.removeFirst()
            } else {
                break
            }
        }
        return text
    }

    private static func truncate(_ text: String, maxWidth: Int) -> String? {
        guard let bounded = truncateColumns(text, maxWidth: maxWidth) else { return nil }
        let cleaned = trimEdgePunctuation(bounded)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Truncates a single-line string to `maxWidth` display columns (wide CJK/emoji = 2,
    /// halfwidth = 1) without baking in an ellipsis, backing up to the start of a trailing
    /// halfwidth word (whitespace or CJK boundary) when cut mid-word.
    nonisolated static func truncateColumns(_ text: String, maxWidth: Int) -> String? {
        guard maxWidth > 0 else { return nil }
        guard width(text) > maxWidth else {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        var kept = ""
        var used = 0
        var firstDropped: Character?
        for character in text {
            let next = used + displayWidth(of: character)
            if next > maxWidth {
                firstDropped = character
                break
            }
            kept.append(character)
            used = next
        }
        if let lastKept = kept.last,
           let firstDropped,
           isHalfwidthWordCharacter(lastKept),
           isHalfwidthWordCharacter(firstDropped),
           let boundaryIndex = kept.lastIndex(where: { !isHalfwidthWordCharacter($0) }) {
            let splitIndex = kept[boundaryIndex].isWhitespace ? boundaryIndex : kept.index(after: boundaryIndex)
            let wordBounded = String(kept[..<splitIndex]).trimmingCharacters(in: .whitespaces)
            if !wordBounded.isEmpty {
                kept = wordBounded
            }
        }
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func isHalfwidthWordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && displayWidth(of: character) == 1
    }

    nonisolated static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + displayWidth(of: $1) }
    }

    nonisolated static func displayWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard !scalars.allSatisfy({ isZeroWidth($0.value) }) else { return 0 }
        return scalars.contains { isWide($0.value) } ? 2 : 1
    }

    nonisolated private static func isZeroWidth(_ value: UInt32) -> Bool {
        switch value {
        case 0x0300...0x036F, 0x200B...0x200F, 0x20D0...0x20FF, 0xFE00...0xFE0F, 0xFE20...0xFE2F:
            true
        default:
            false
        }
    }

    /// East Asian wide, fullwidth and emoji ranges; the same approximation the Quick Input uses.
    nonisolated private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3040...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE10...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }
}
