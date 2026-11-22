import AppKit

/// Turns the Markdown that Agents answer in into blocks a transcript row can
/// lay out natively: styled prose, and code or tables in a monospaced box.
///
/// This is a reader for chat output, not a full Markdown implementation. It
/// styles what is unambiguous and leaves everything else as written, so text
/// that merely resembles Markdown is never mangled.
enum AgentHistoryMarkdown {
    enum Block: Equatable {
        case prose(NSAttributedString)
        /// Fenced code or a pipe table, shown verbatim in a fixed-width font.
        case code(String)
    }

    static let bodySize: CGFloat = 12.5
    static let codeSize: CGFloat = 11.5

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var fence: String?
        var table: [String] = []

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose = []
            if !joined.isEmpty { blocks.append(.prose(attributedProse(joined))) }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            // A lone line with pipes is prose; a table has a header rule.
            if table.count >= 2, isTableRule(table[1]) {
                flushProse()
                let aligned = alignedTable(table)
                let width = aligned.split(separator: "\n").map { displayWidth(String($0)) }.max() ?? 0
                // An Inspector is narrow. A table that fits stays a table;
                // a wide one reads better as one labelled record per row.
                blocks.append(width <= maximumTableColumns ? .code(aligned) : .prose(tableRecords(table)))
            } else {
                prose.append(contentsOf: table)
            }
            table = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.dropFirst(open.count).allSatisfy({ $0 == open.first }) {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            let marker = trimmed.prefix { $0 == "`" || $0 == "~" }
            if marker.count >= 3, Set(marker).count == 1 {
                flushTable()
                flushProse()
                fence = String(marker)
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                table.append(trimmed)
                continue
            }
            flushTable()
            prose.append(line)
        }
        flushTable()
        // An unterminated fence, as in a truncated message, is still code.
        if fence != nil, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    // MARK: Tables

    private static func cells(_ row: String) -> [String] {
        row.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableRule(_ row: String) -> Bool {
        let cells = cells(row)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    /// Pads columns so a table reads as one in a fixed-width font. East Asian
    /// wide characters occupy two columns.
    private static func alignedTable(_ rows: [String]) -> String {
        let table = rows.enumerated().filter { $0.offset != 1 }.map { cells($0.element).map(plainInline) }
        let columns = table.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in table {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], displayWidth(cell)) }
        }
        var lines: [String] = []
        for (index, row) in table.enumerated() {
            let padded = (0..<columns).map { column -> String in
                let cell = column < row.count ? row[column] : ""
                return cell + String(repeating: " ", count: widths[column] - displayWidth(cell))
            }
            lines.append(padded.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
            if index == 0 {
                lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Fixed-width columns that fit the default Inspector without wrapping.
    private static let maximumTableColumns = 40

    /// Each row as its first cell in bold, then `header: value` lines.
    private static func tableRecords(_ rows: [String]) -> NSAttributedString {
        let header = cells(rows[0])
        let font = NSFont.systemFont(ofSize: bodySize)
        let result = NSMutableAttributedString()
        for row in rows.dropFirst(2).map(cells) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let title = NSMutableParagraphStyle()
            title.lineSpacing = 2
            title.paragraphSpacingBefore = result.length > 0 ? 6 : 0
            let label = NSMutableAttributedString(attributedString: attributedInline(
                row.first ?? "", font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            ))
            label.addAttribute(.paragraphStyle, value: title, range: NSRange(location: 0, length: label.length))
            result.append(label)
            let detail = NSMutableParagraphStyle()
            detail.lineSpacing = 2
            detail.firstLineHeadIndent = 10
            detail.headIndent = 10
            for (index, cell) in row.enumerated().dropFirst() where !cell.isEmpty {
                let line = NSMutableAttributedString(string: "\n")
                if index < header.count, !header[index].isEmpty {
                    line.append(NSAttributedString(string: plainInline(header[index]) + "  ", attributes: [
                        .font: NSFont.systemFont(ofSize: bodySize - 1), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                line.append(attributedInline(cell, font: font))
                line.addAttribute(.paragraphStyle, value: detail, range: NSRange(location: 0, length: line.length))
                result.append(line)
            }
        }
        return result
    }

    private static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { width, scalar in
            let value = scalar.value
            let wide = (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) ||
                (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value) ||
                (0xFE30...0xFE4F).contains(value) || (0xFF00...0xFF60).contains(value) ||
                (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value)
            return width + (wide ? 2 : 1)
        }
    }

    /// Inline markup removed, for table cells that are shown as plain text.
    private static func plainInline(_ text: String) -> String {
        attributedInline(text, font: .systemFont(ofSize: bodySize)).string
    }

    // MARK: Prose

    private static func attributedProse(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            result.append(attributedLine(line))
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func attributedLine(_ line: String) -> NSAttributedString {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let content = line.dropFirst(indent.count)
        let depth = CGFloat(indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) })
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 3
        var font = NSFont.systemFont(ofSize: bodySize)
        var color = NSColor.labelColor
        var body = String(content)
        var lead = ""

        if let heading = headingLevel(body) {
            body = String(body.dropFirst(heading + 1))
            font = .systemFont(ofSize: bodySize + (heading == 1 ? 2.5 : heading == 2 ? 1.5 : 0.5), weight: .semibold)
            paragraph.paragraphSpacingBefore = 4
        } else if body.hasPrefix("> ") || body == ">" {
            body = String(body.dropFirst(body.hasPrefix("> ") ? 2 : 1))
            color = .secondaryLabelColor
            paragraph.firstLineHeadIndent = 10
            paragraph.headIndent = 10
        } else if let marker = listMarker(body) {
            lead = marker.display
            body = String(body.dropFirst(marker.length))
            let offset = depth * 3
            paragraph.firstLineHeadIndent = offset
            paragraph.headIndent = offset + (lead as NSString).size(withAttributes: [.font: font]).width
        } else if isRule(body) {
            return NSAttributedString(string: "────────", attributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }

        let result = NSMutableAttributedString(string: lead, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        result.append(attributedInline(body, font: font, color: color))
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let characters = line.filter { !$0.isWhitespace }
        guard characters.count >= 3, let first = characters.first, "-*_".contains(first) else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func listMarker(_ line: String) -> (display: String, length: Int)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            if line.hasPrefix(bullet + "[ ] ") { return ("☐ ", 6) }
            if line.hasPrefix(bullet + "[x] ") || line.hasPrefix(bullet + "[X] ") { return ("☑ ", 6) }
            return ("• ", 2)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (digits + ". ", digits.count + 2)
    }

    // MARK: Inline

    /// Styles code spans, strong and emphasized text, and links. Markers that
    /// are not closed on the same line are left as typed.
    static func attributedInline(
        _ text: String, font: NSFont, color: NSColor = .labelColor
    ) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let result = NSMutableAttributedString()
        let characters = Array(text)
        var plain = ""
        var index = 0

        func flush() {
            if !plain.isEmpty { result.append(NSAttributedString(string: plain, attributes: base)) }
            plain = ""
        }
        /// Index of the next `marker` at or after `start`. The search window
        /// is bounded so a line full of unmatched markers stays linear.
        func find(_ marker: [Character], from start: Int) -> Int? {
            let last = min(characters.count - marker.count, start + 800)
            guard start <= last else { return nil }
            for position in start...last {
                var matches = true
                for offset in marker.indices where characters[position + offset] != marker[offset] {
                    matches = false
                    break
                }
                if matches { return position }
            }
            return nil
        }

        while index < characters.count {
            let character = characters[index]
            if character == "`", let end = find(["`"], from: index + 1), end > index + 1 {
                flush()
                var attributes = base
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
                result.append(NSAttributedString(string: String(characters[(index + 1)..<end]), attributes: attributes))
                index = end + 1
            } else if character == "*", index + 1 < characters.count, characters[index + 1] == "*",
                      let end = find(["*", "*"], from: index + 2), end > index + 2,
                      !characters[index + 2].isWhitespace {
                flush()
                let inner = String(characters[(index + 2)..<end])
                let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                result.append(attributedInline(inner, font: bold, color: color))
                index = end + 2
            } else if character == "*", index + 1 < characters.count, !characters[index + 1].isWhitespace,
                      characters[index + 1] != "*", let end = find(["*"], from: index + 1), end > index + 1,
                      !characters[end - 1].isWhitespace {
                flush()
                let inner = String(characters[(index + 1)..<end])
                let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                result.append(attributedInline(inner, font: italic, color: color))
                index = end + 1
            } else if character == "[", let labelEnd = find(["]", "("], from: index + 1), labelEnd > index + 1,
                      let urlEnd = find([")"], from: labelEnd + 2) {
                let label = String(characters[(index + 1)..<labelEnd])
                let target = String(characters[(labelEnd + 2)..<urlEnd])
                flush()
                var attributes = base
                if target.hasPrefix("https://") || target.hasPrefix("http://"), let url = URL(string: target) {
                    attributes[.link] = url
                }
                attributes[.foregroundColor] = NSColor.linkColor
                let styled = NSMutableAttributedString(attributedString: attributedInline(label, font: font, color: color))
                styled.addAttributes(attributes.filter { $0.key != .font }, range: NSRange(location: 0, length: styled.length))
                result.append(styled)
                index = urlEnd + 1
            } else {
                plain.append(character)
                index += 1
            }
        }
        flush()
        return result
    }

    // MARK: Highlight

    /// Marks every occurrence of a search term.
    static func highlighting(_ text: NSAttributedString, term: String) -> NSAttributedString {
        guard !term.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let source = result.string as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.location < source.length {
            let range = source.range(of: term, options: .caseInsensitive, range: searchRange)
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45),
                .foregroundColor: NSColor.labelColor,
            ], range: range)
            let next = range.location + range.length
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return result
    }
}
