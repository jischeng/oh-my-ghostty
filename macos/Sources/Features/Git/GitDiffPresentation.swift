import AppKit
import Foundation

/// Builds an inline source view and bidirectional source-line anchors from Git's
/// bounded patch. No quadratic diff computation runs on the UI thread.
struct GitDiffPresentation: Equatable {
    struct Row: Equatable {
        let text: String
        let beforeLine: Int?
        let afterLine: Int?
        let added: Bool?
    }
    var rows: [Row] = []
    var beforeToAfter: [Int: Int] = [:]
    var afterToBefore: [Int: Int] = [:]
    var isConsistent = true
    var text: String { rows.map(\.text).joined(separator: "\n") }
    var highlights: [Int: Bool] {
        Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in row.added.map { (index, $0) } })
    }
    var beforeHighlights: [Int: Bool] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard row.added == false, let line = row.beforeLine else { return nil }
            return (line - 1, false)
        })
    }
    var afterHighlights: [Int: Bool] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard row.added == true, let line = row.afterLine else { return nil }
            return (line - 1, true)
        })
    }
    var changeAnchors: [(before: Int?, after: Int?, inline: Int)] {
        var anchors: [(before: Int?, after: Int?, inline: Int)] = []
        var inChange = false
        for (index, row) in rows.enumerated() {
            if row.added != nil {
                if !inChange {
                    anchors.append((row.beforeLine.map { $0 - 1 }, row.afterLine.map { $0 - 1 }, index))
                } else if anchors[anchors.count - 1].before == nil, let line = row.beforeLine {
                    anchors[anchors.count - 1].before = line - 1
                } else if anchors[anchors.count - 1].after == nil, let line = row.afterLine {
                    anchors[anchors.count - 1].after = line - 1
                }
                inChange = true
            } else {
                inChange = false
            }
        }
        return anchors
    }

    init(before: String, after: String, patch: String) {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var values = text.components(separatedBy: "\n")
            if values.last == "" { values.removeLast() }
            return values.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        }
        let old = lines(before)
        let new = lines(after)
        var oldIndex = 0
        var newIndex = 0
        var removed: [Int] = []
        var inserted: [Int] = []
        var inHunk = false
        func flush() {
            for (offset, index) in removed.enumerated() {
                beforeToAfter[index] = inserted.isEmpty ? max(0, min(newIndex, new.count - 1)) :
                    inserted[min(offset, inserted.count - 1)]
            }
            for (offset, index) in inserted.enumerated() {
                afterToBefore[index] = removed.isEmpty ? max(0, min(oldIndex, old.count - 1)) :
                    removed[min(offset, removed.count - 1)]
            }
            removed = []; inserted = []
        }
        func unchanged() {
            guard old.indices.contains(oldIndex), new.indices.contains(newIndex) else { isConsistent = false; return }
            if old[oldIndex] != new[newIndex] { isConsistent = false }
            beforeToAfter[oldIndex] = newIndex
            afterToBefore[newIndex] = oldIndex
            rows.append(Row(text: new[newIndex], beforeLine: oldIndex + 1, afterLine: newIndex + 1, added: nil))
            oldIndex += 1; newIndex += 1
        }
        // Split LF bytes, not Swift Characters: CRLF is a single grapheme.
        for raw in patch.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            if line.hasPrefix("@@ ") {
                flush()
                let fields = line.split(separator: " ")
                guard fields.count >= 3,
                      let oldStart = fields[1].dropFirst().split(separator: ",").first.flatMap({ Int($0) }),
                      let newStart = fields[2].dropFirst().split(separator: ",").first.flatMap({ Int($0) }) else {
                    isConsistent = false; continue
                }
                let oldParts = fields[1].dropFirst().split(separator: ",")
                let newParts = fields[2].dropFirst().split(separator: ",")
                let oldTarget = max(0, oldStart - (oldParts.last == "0" && oldParts.count > 1 ? 0 : 1))
                let newTarget = max(0, newStart - (newParts.last == "0" && newParts.count > 1 ? 0 : 1))
                while oldIndex < oldTarget && newIndex < newTarget && oldIndex < old.count && newIndex < new.count {
                    unchanged()
                }
                if oldIndex != oldTarget || newIndex != newTarget { isConsistent = false }
                inHunk = true
            } else if inHunk && line.hasPrefix("-") {
                guard old.indices.contains(oldIndex) else { isConsistent = false; continue }
                if old[oldIndex] != line.dropFirst() { isConsistent = false }
                rows.append(Row(text: old[oldIndex], beforeLine: oldIndex + 1, afterLine: nil, added: false))
                removed.append(oldIndex); oldIndex += 1
            } else if inHunk && line.hasPrefix("+") {
                guard new.indices.contains(newIndex) else { isConsistent = false; continue }
                if new[newIndex] != line.dropFirst() { isConsistent = false }
                rows.append(Row(text: new[newIndex], beforeLine: nil, afterLine: newIndex + 1, added: true))
                inserted.append(newIndex); newIndex += 1
            } else if inHunk && line.hasPrefix(" ") {
                flush(); unchanged()
            }
        }
        flush()
        while oldIndex < old.count && newIndex < new.count { unchanged() }
        if oldIndex != old.count || newIndex != new.count { isConsistent = false }
    }
}

struct GitDiffReviewNavigator: Equatable {
    enum Direction: Equatable { case previous, next }
    enum Landing: Equatable { case first, last }
    enum Hint: Equatable { case previousFile, nextFile }
    enum Outcome: Equatable {
        case jump(Int)
        case hint(Hint)
        case openFile(offset: Int, landing: Landing)
    }

    private(set) var changeIndex: Int?
    private(set) var armedDirection: Direction?

    mutating func reset() {
        changeIndex = nil
        armedDirection = nil
    }

    mutating func disarm() {
        armedDirection = nil
    }

    mutating func land(_ landing: Landing, changeCount: Int) -> Int? {
        armedDirection = nil
        guard changeCount > 0 else { changeIndex = nil; return nil }
        let index = landing == .first ? 0 : changeCount - 1
        changeIndex = index
        return index
    }

    mutating func move(_ direction: Direction, changeCount: Int, fileCount: Int) -> Outcome? {
        guard changeCount > 0, fileCount > 0 else { return nil }
        let current = changeIndex
        switch direction {
        case .next:
            let nextIndex = (current ?? -1) + 1
            if nextIndex < changeCount {
                let index = min(changeCount - 1, nextIndex)
                changeIndex = index
                armedDirection = nil
                return .jump(index)
            }
            if armedDirection == .next {
                reset()
                return .openFile(offset: 1, landing: .first)
            }
            armedDirection = .next
            return .hint(.nextFile)
        case .previous:
            let previousIndex = (current ?? changeCount) - 1
            if previousIndex >= 0 {
                let index = max(0, previousIndex)
                changeIndex = index
                armedDirection = nil
                return .jump(index)
            }
            if armedDirection == .previous {
                reset()
                return .openFile(offset: -1, landing: .last)
            }
            armedDirection = .previous
            return .hint(.previousFile)
        }
    }
}

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
                while index < rows.count && !visible.contains(index) {
                    index += 1
                }
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

/// Pure unified-patch line-number formatter for clipboard / diagnostic summaries.
enum GitDiffTextRenderer {
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff ") { inHunk = false }
            let isHunk = line.hasPrefix("@@")
            if isHunk {
                updateLineNumbers(from: line, old: &oldLine, new: &newLine)
                inHunk = true
            }
            let isMetadata = !inHunk && (
                line.hasPrefix("diff ") ||
                line.hasPrefix("index ") ||
                line.hasPrefix("---") ||
                line.hasPrefix("+++") ||
                line.hasPrefix("Binary files ")
            )
            let isAdded = inHunk && line.hasPrefix("+")
            let isDeleted = inHunk && line.hasPrefix("-")
            let hasLineNumber = inHunk && !isHunk && !isMetadata && !line.hasPrefix("\\")

            let oldNumber = hasLineNumber && !isAdded && !isHunk ? oldLine : nil
            let newNumber = hasLineNumber && !isDeleted && !isHunk ? newLine : nil
            if isAdded {
                newLine += 1
            } else if isDeleted {
                oldLine += 1
            } else if !isHunk && !isMetadata && !line.hasPrefix("\\") {
                oldLine += 1
                newLine += 1
            }

            let prefix = "\(number(oldNumber)) \(number(newNumber)) │ "
            let output = prefix + line + (index + 1 < lines.count ? "\n" : "")
            let foreground: NSColor = if isAdded {
                .systemGreen
            } else if isDeleted {
                .systemRed
            } else if isHunk {
                .systemBlue
            } else {
                .labelColor
            }
            let background: NSColor = if isAdded {
                NSColor.systemGreen.withAlphaComponent(0.08)
            } else if isDeleted {
                NSColor.systemRed.withAlphaComponent(0.08)
            } else {
                .clear
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: foreground,
                .backgroundColor: background
            ]
            result.append(NSAttributedString(string: output, attributes: attributes))
        }
        return result
    }

    private static func updateLineNumbers(from line: String, old: inout Int, new: inout Int) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }
        old = Int(parts[1].dropFirst().split(separator: ",", maxSplits: 1).first ?? "") ?? 0
        new = Int(parts[2].dropFirst().split(separator: ",", maxSplits: 1).first ?? "") ?? 0
    }

    private static func number(_ value: Int?) -> String {
        guard let value else { return "    " }
        let string = String(value)
        return String(repeating: " ", count: max(0, 4 - string.count)) + string
    }
}
