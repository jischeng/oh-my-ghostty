import AppKit
import CodeEditSourceEditor
import CodeEditTextView

enum EditorAction: Hashable {
    case cut, copy, paste, selectAll, selectLine, undo, redo
    case find, replace, goToLine, findNext, findPrevious
    case save, saveAll, close, open, nextDocument, previousDocument
    case hide
    case duplicateLine, deleteLine, moveLineUp, moveLineDown, indent, outdent, toggleLineComment
    case insertLineBelow
    case deleteWordBackward, deleteWordForward, deleteToBeginningOfLine, deleteToEndOfLine
    case moveWordLeft, moveWordRight, selectWordLeft, selectWordRight
    case moveToLineStart, moveToLineEnd, selectToLineStart, selectToLineEnd
    case moveToDocumentStart, moveToDocumentEnd, selectToDocumentStart, selectToDocumentEnd
}

struct EditorKeyStroke: Hashable {
    static let tab = "\t"
    static let backspace = "\u{8}"
    static let escape = "\u{1b}"
    static let delete = "\u{f728}"
    static let upArrow = "\u{f700}"
    static let downArrow = "\u{f701}"
    static let leftArrow = "\u{f702}"
    static let rightArrow = "\u{f703}"

    let key: String
    let modifiers: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift]).rawValue
    }

    init(event: NSEvent) {
        self.init(
            key: Self.key(for: event),
            modifiers: event.modifierFlags
        )
    }

    private static func key(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: "\r"
        case 48: tab
        case 51: backspace
        case 53: escape
        case 117: delete
        case 123: leftArrow
        case 124: rightArrow
        case 125: downArrow
        case 126: upArrow
        default: event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }
}

struct EditorKeymap {
    enum Profile { case idea, vscode }

    static let idea = EditorKeymap(profile: .idea)
    static let vscode = EditorKeymap(profile: .vscode)

    let actions: [EditorKeyStroke: EditorAction]

    init(profile: Profile) {
        var actions: [EditorKeyStroke: EditorAction] = [
            .init(key: "x", modifiers: .command): .cut,
            .init(key: "c", modifiers: .command): .copy,
            .init(key: "v", modifiers: .command): .paste,
            .init(key: "a", modifiers: .command): .selectAll,
            .init(key: "z", modifiers: .command): .undo,
            .init(key: "z", modifiers: [.command, .shift]): .redo,
            .init(key: "f", modifiers: .command): .find,
            .init(key: "g", modifiers: .command): .findNext,
            .init(key: "g", modifiers: [.command, .shift]): .findPrevious,
            .init(key: "w", modifiers: .command): .close,
            .init(key: "o", modifiers: .command): .open,
            .init(key: EditorKeyStroke.tab, modifiers: .control): .nextDocument,
            .init(key: EditorKeyStroke.tab, modifiers: [.control, .shift]): .previousDocument,
            .init(key: "/", modifiers: .command): .toggleLineComment,
            .init(key: "]", modifiers: .command): .indent,
            .init(key: "[", modifiers: .command): .outdent,
            .init(key: "s", modifiers: [.command, .shift]): .saveAll,
            .init(key: "\r", modifiers: .shift): .insertLineBelow,
            .init(key: EditorKeyStroke.escape, modifiers: .shift): .hide,

            // Option + Word operations (standard macOS text editing)
            .init(key: EditorKeyStroke.backspace, modifiers: .option): .deleteWordBackward,
            .init(key: EditorKeyStroke.delete, modifiers: .option): .deleteWordForward,
            .init(key: EditorKeyStroke.leftArrow, modifiers: .option): .moveWordLeft,
            .init(key: EditorKeyStroke.rightArrow, modifiers: .option): .moveWordRight,
            .init(key: EditorKeyStroke.leftArrow, modifiers: [.option, .shift]): .selectWordLeft,
            .init(key: EditorKeyStroke.rightArrow, modifiers: [.option, .shift]): .selectWordRight,

            // Command + Line/Document operations
            .init(key: EditorKeyStroke.leftArrow, modifiers: .command): .moveToLineStart,
            .init(key: EditorKeyStroke.rightArrow, modifiers: .command): .moveToLineEnd,
            .init(key: EditorKeyStroke.leftArrow, modifiers: [.command, .shift]): .selectToLineStart,
            .init(key: EditorKeyStroke.rightArrow, modifiers: [.command, .shift]): .selectToLineEnd,
            .init(key: EditorKeyStroke.upArrow, modifiers: .command): .moveToDocumentStart,
            .init(key: EditorKeyStroke.downArrow, modifiers: .command): .moveToDocumentEnd,
            .init(key: EditorKeyStroke.upArrow, modifiers: [.command, .shift]): .selectToDocumentStart,
            .init(key: EditorKeyStroke.downArrow, modifiers: [.command, .shift]): .selectToDocumentEnd,
        ]
        switch profile {
        case .idea:
            actions[.init(key: "r", modifiers: .command)] = .replace
            actions[.init(key: "l", modifiers: .command)] = .goToLine
            actions[.init(key: "s", modifiers: .command)] = .saveAll
            actions[.init(key: "d", modifiers: .command)] = .duplicateLine
            actions[.init(key: EditorKeyStroke.backspace, modifiers: .command)] = .deleteLine
            actions[.init(key: EditorKeyStroke.upArrow, modifiers: [.option, .shift])] = .moveLineUp
            actions[.init(key: EditorKeyStroke.downArrow, modifiers: [.option, .shift])] = .moveLineDown
            actions[.init(key: "]", modifiers: [.command, .shift])] = .nextDocument
            actions[.init(key: "[", modifiers: [.command, .shift])] = .previousDocument
        case .vscode:
            actions[.init(key: "f", modifiers: [.command, .option])] = .replace
            actions[.init(key: "g", modifiers: .control)] = .goToLine
            actions[.init(key: "s", modifiers: .command)] = .save
            actions[.init(key: "l", modifiers: .command)] = .selectLine
            actions[.init(key: EditorKeyStroke.downArrow, modifiers: [.option, .shift])] = .duplicateLine
            actions[.init(key: "k", modifiers: [.command, .shift])] = .deleteLine
            actions[.init(key: EditorKeyStroke.upArrow, modifiers: .option)] = .moveLineUp
            actions[.init(key: EditorKeyStroke.downArrow, modifiers: .option)] = .moveLineDown
            actions[.init(key: EditorKeyStroke.rightArrow, modifiers: [.command, .option])] = .nextDocument
            actions[.init(key: EditorKeyStroke.leftArrow, modifiers: [.command, .option])] = .previousDocument
        }
        self.actions = actions
    }

    func action(for event: NSEvent) -> EditorAction? { actions[EditorKeyStroke(event: event)] }
    func action(for stroke: EditorKeyStroke) -> EditorAction? { actions[stroke] }
}

@MainActor
final class EditorCommandRouter {
    static let shared = EditorCommandRouter()

    private final class Entry {
        weak var owner: AnyObject?
        let handler: (NSEvent) -> Bool

        init(owner: AnyObject, handler: @escaping (NSEvent) -> Bool) {
            self.owner = owner
            self.handler = handler
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var registrationOrder: [ObjectIdentifier] = []

    func register(owner: AnyObject, handler: @escaping (NSEvent) -> Bool) {
        let identifier = ObjectIdentifier(owner)
        if entries[identifier] == nil { registrationOrder.append(identifier) }
        entries[identifier] = Entry(owner: owner, handler: handler)
    }

    func unregister(owner: AnyObject) {
        let identifier = ObjectIdentifier(owner)
        entries.removeValue(forKey: identifier)
        registrationOrder.removeAll { $0 == identifier }
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           let char = event.charactersIgnoringModifiers?.first,
           let digit = char.wholeNumberValue,
           (1...9).contains(digit) {
            if TerminalController.selectTab(digit: digit, in: event.window) {
                return true
            }
        }

        let deadIdentifiers = registrationOrder.filter { entries[$0]?.owner == nil }
        for identifier in deadIdentifiers {
            entries.removeValue(forKey: identifier)
        }
        registrationOrder.removeAll { deadIdentifiers.contains($0) }
        for identifier in registrationOrder where entries[identifier]?.handler(event) == true {
            return true
        }
        return false
    }
}

@MainActor
enum EditorNativeTextActions {
    static func uniqueLineRanges(for ranges: [NSRange], in text: String) -> [NSRange] {
        var rawRanges: [NSRange] = []
        for range in ranges {
            guard let lineRange = EditorTextSearch.lineRange(containing: range, in: text) else { continue }
            rawRanges.append(lineRange)
        }
        guard !rawRanges.isEmpty else { return [] }
        let sorted = rawRanges.sorted {
            if $0.location != $1.location {
                return $0.location < $1.location
            }
            return $0.length > $1.length
        }
        var merged: [NSRange] = []
        for lr in sorted {
            guard let last = merged.last else {
                merged.append(lr)
                continue
            }
            if lr.location == last.location && lr.length == last.length {
                continue
            }
            if lr.location < NSMaxRange(last) {
                let newEnd = max(NSMaxRange(last), NSMaxRange(lr))
                merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                merged.append(lr)
            }
        }
        return merged
    }

    private static func contiguousBlocks(from lineRanges: [NSRange]) -> [NSRange] {
        var blocks: [NSRange] = []
        for lr in lineRanges.sorted(by: { $0.location < $1.location }) {
            if let last = blocks.last, NSMaxRange(last) == lr.location {
                blocks[blocks.count - 1] = NSRange(location: last.location, length: last.length + lr.length)
            } else {
                blocks.append(lr)
            }
        }
        return blocks
    }

    @discardableResult
    static func select(_ range: NSRange, on textView: TextView) -> Bool {
        select([range], on: textView)
    }

    @discardableResult
    static func select(_ ranges: [NSRange], on textView: TextView) -> Bool {
        let validRanges = ranges.filter {
            $0.location != NSNotFound && $0.location >= 0 && NSMaxRange($0) <= textView.textStorage.length
        }
        guard !validRanges.isEmpty else { return false }
        textView.selectionManager.setSelectedRanges(validRanges)
        NotificationCenter.default.post(
            name: TextSelectionManager.selectionChangedNotification,
            object: textView.selectionManager
        )
        textView.scrollSelectionToVisible()
        textView.updatedViewport(textView.visibleRect)
        textView.needsDisplay = true
        return true
    }

    static func perform(_ action: EditorAction, on textView: TextView) -> Bool {
        switch action {
        case .cut:
            guard textView.isEditable else { return true }
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return true }
            let hasNonEmptySelection = selections.contains { $0.range.length > 0 }
            if hasNonEmptySelection {
                textView.cut(textView)
            } else {
                let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
                guard let first = lineRanges.first, let last = lineRanges.last else { return true }
                let source = textView.string as NSString
                let combinedText = lineRanges.map { source.substring(with: $0) }.joined()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(combinedText, forType: .string)

                var newCaretPositions: [Int] = []
                var cumulativeDeleted = 0
                for lr in lineRanges {
                    newCaretPositions.append(lr.location - cumulativeDeleted)
                    cumulativeDeleted += lr.length
                }

                let cover = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                let combined = NSMutableString(string: source.substring(with: cover))
                for lr in lineRanges.reversed() {
                    let relative = NSRange(location: lr.location - cover.location, length: lr.length)
                    combined.replaceCharacters(in: relative, with: "")
                }
                textView.replaceCharacters(in: cover, with: combined as String)

                let newSelections = newCaretPositions.map {
                    NSRange(location: min($0, textView.textStorage.length), length: 0)
                }
                select(newSelections, on: textView)
            }
            return true
        case .copy:
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return true }
            let hasNonEmptySelection = selections.contains { $0.range.length > 0 }
            if hasNonEmptySelection {
                textView.copy(textView)
            } else {
                let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
                guard !lineRanges.isEmpty else { return true }
                let source = textView.string as NSString
                let combinedText = lineRanges.map { source.substring(with: $0) }.joined()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(combinedText, forType: .string)
            }
            return true
        case .paste:
            guard textView.isEditable else { return true }
            textView.paste(textView)
            return true
        case .selectAll:
            textView.selectAll(nil)
            return true
        case .selectLine:
            textView.selectLine(nil)
            return true
        case .undo:
            if textView.undoManager?.canUndo == true {
                textView.undoManager?.undo()
            }
            return true
        case .redo:
            if textView.undoManager?.canRedo == true {
                textView.undoManager?.redo()
            }
            return true
        case .duplicateLine:
            guard textView.isEditable else { return false }
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return false }
            let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
            guard let first = lineRanges.first, let last = lineRanges.last else { return false }

            var selectionInfos: [(lineIndex: Int, offsetInLine: Int, length: Int)] = []
            for sel in selections {
                if let lineIdx = lineRanges.firstIndex(where: {
                    NSLocationInRange(sel.range.location, $0) || (sel.range.location == NSMaxRange($0) && $0.length > 0)
                }) {
                    selectionInfos.append((lineIdx, sel.range.location - lineRanges[lineIdx].location, sel.range.length))
                } else if let firstIdx = lineRanges.indices.first {
                    selectionInfos.append((firstIdx, 0, sel.range.length))
                }
            }

            let source = textView.string as NSString
            let cover = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            let combined = NSMutableString(string: source.substring(with: cover))
            var duplicateLengths: [Int: Int] = [:]

            for (idx, lr) in lineRanges.enumerated().reversed() {
                var duplicate = source.substring(with: lr)
                let relativeEnd = NSMaxRange(lr) - cover.location
                if !duplicate.hasSuffix("\n") {
                    duplicate = "\n" + duplicate
                }
                combined.insert(duplicate, at: relativeEnd)
                duplicateLengths[idx] = (duplicate as NSString).length
            }
            textView.replaceCharacters(in: cover, with: combined as String)

            var newSelections: [NSRange] = []
            for info in selectionInfos {
                let baseLine = lineRanges[info.lineIndex]
                var shift = 0
                for prevIdx in 0..<info.lineIndex {
                    shift += duplicateLengths[prevIdx] ?? 0
                }
                let dupLen = duplicateLengths[info.lineIndex] ?? 0
                let newLoc = baseLine.location + shift + dupLen + info.offsetInLine
                newSelections.append(NSRange(location: min(newLoc, textView.textStorage.length), length: info.length))
            }
            select(newSelections, on: textView)
            return true
        case .deleteLine:
            guard textView.isEditable else { return false }
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return false }
            let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
            guard let first = lineRanges.first, let last = lineRanges.last else { return false }

            var newCaretPositions: [Int] = []
            var cumulativeDeleted = 0
            for lr in lineRanges {
                newCaretPositions.append(lr.location - cumulativeDeleted)
                cumulativeDeleted += lr.length
            }

            let source = textView.string as NSString
            let cover = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            let combined = NSMutableString(string: source.substring(with: cover))
            for lr in lineRanges.reversed() {
                let relative = NSRange(location: lr.location - cover.location, length: lr.length)
                combined.replaceCharacters(in: relative, with: "")
            }
            textView.replaceCharacters(in: cover, with: combined as String)

            let newSelections = newCaretPositions.map {
                NSRange(location: min($0, textView.textStorage.length), length: 0)
            }
            select(newSelections, on: textView)
            return true
        case .moveLineUp:
            guard textView.isEditable else { return false }
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return false }
            let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
            let blocks = contiguousBlocks(from: lineRanges)
            guard !blocks.isEmpty else { return false }

            var cursorOffsets: [(blockIdx: Int, offset: Int, length: Int)] = []
            for sel in selections {
                if let bIdx = blocks.firstIndex(where: {
                    NSLocationInRange(sel.range.location, $0) || sel.range.location == NSMaxRange($0)
                }) {
                    cursorOffsets.append((bIdx, sel.range.location - blocks[bIdx].location, sel.range.length))
                }
            }

            let original = textView.string as NSString
            let edited = NSMutableString(string: textView.string)
            var affected: NSRange?

            var newSelections: [NSRange] = []
            for block in blocks {
                guard block.location > 0 else {
                    for co in cursorOffsets where blocks[co.blockIdx].location == block.location {
                        newSelections.append(NSRange(location: block.location + co.offset, length: co.length))
                    }
                    continue
                }
                let source = edited as NSString
                let prevLineRange = source.lineRange(for: NSRange(location: block.location - 1, length: 0))
                let currentBlockText = source.substring(with: block)
                let prevLineText = source.substring(with: prevLineRange)
                var newBlockText = currentBlockText
                var newPrevText = prevLineText
                if !newBlockText.hasSuffix("\n") && newPrevText.hasSuffix("\n") {
                    newBlockText += "\n"
                    newPrevText = String(newPrevText.dropLast())
                }
                let combinedRange = NSRange(location: prevLineRange.location, length: prevLineRange.length + block.length)
                let swappedText = newBlockText + newPrevText
                edited.replaceCharacters(in: combinedRange, with: swappedText)
                affected = affected.map { NSUnionRange($0, combinedRange) } ?? combinedRange

                for co in cursorOffsets where blocks[co.blockIdx].location == block.location {
                    let newLoc = prevLineRange.location + co.offset
                    newSelections.append(NSRange(location: min(newLoc, textView.textStorage.length), length: co.length))
                }
            }
            if let affected, original.substring(with: affected) != edited.substring(with: affected) {
                EditorTextEditing.replace(on: textView, ranges: [affected], with: edited.substring(with: affected))
            }
            if !newSelections.isEmpty {
                select(newSelections, on: textView)
            }
            return true
        case .moveLineDown:
            guard textView.isEditable else { return false }
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return false }
            let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
            let blocks = contiguousBlocks(from: lineRanges)
            guard !blocks.isEmpty else { return false }

            var cursorOffsets: [(blockIdx: Int, offset: Int, length: Int)] = []
            for sel in selections {
                if let bIdx = blocks.firstIndex(where: {
                    NSLocationInRange(sel.range.location, $0) || sel.range.location == NSMaxRange($0)
                }) {
                    cursorOffsets.append((bIdx, sel.range.location - blocks[bIdx].location, sel.range.length))
                }
            }

            let original = textView.string as NSString
            let edited = NSMutableString(string: textView.string)
            var affected: NSRange?

            var newSelections: [NSRange] = []
            for block in blocks.reversed() {
                let source = edited as NSString
                let endOfBlock = NSMaxRange(block)
                guard endOfBlock < source.length else {
                    for co in cursorOffsets where blocks[co.blockIdx].location == block.location {
                        newSelections.append(NSRange(location: block.location + co.offset, length: co.length))
                    }
                    continue
                }
                let nextLineRange = source.lineRange(for: NSRange(location: endOfBlock, length: 0))
                let currentBlockText = source.substring(with: block)
                let nextLineText = source.substring(with: nextLineRange)
                var newBlockText = currentBlockText
                var newNextText = nextLineText
                if !newNextText.hasSuffix("\n") && newBlockText.hasSuffix("\n") {
                    newNextText += "\n"
                    newBlockText = String(newBlockText.dropLast())
                }
                let combinedRange = NSRange(location: block.location, length: block.length + nextLineRange.length)
                let swappedText = newNextText + newBlockText
                edited.replaceCharacters(in: combinedRange, with: swappedText)
                affected = affected.map { NSUnionRange($0, combinedRange) } ?? combinedRange

                for co in cursorOffsets where blocks[co.blockIdx].location == block.location {
                    let newLoc = block.location + (newNextText as NSString).length + co.offset
                    newSelections.append(NSRange(location: min(newLoc, textView.textStorage.length), length: co.length))
                }
            }
            if let affected, original.substring(with: affected) != edited.substring(with: affected) {
                EditorTextEditing.replace(on: textView, ranges: [affected], with: edited.substring(with: affected))
            }
            if !newSelections.isEmpty {
                select(newSelections.sorted(by: { $0.location < $1.location }), on: textView)
            }
            return true
        case .insertLineBelow:
            guard textView.isEditable else { return false }
            let selections = textView.selectionManager.textSelections
            guard !selections.isEmpty else { return false }
            let lineRanges = uniqueLineRanges(for: selections.map(\.range), in: textView.string)
            guard let first = lineRanges.first, let last = lineRanges.last else { return false }

            let source = textView.string as NSString
            let cover = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            let combined = NSMutableString(string: source.substring(with: cover))

            struct InsertionPlan {
                let relativePos: Int
                let insertionText: String
                let caretOffsetFromLineStart: Int
            }

            var plans: [InsertionPlan] = []
            for lr in lineRanges {
                let lineText = source.substring(with: lr)
                let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
                let hasNewline = lineText.hasSuffix("\n")
                if hasNewline {
                    let relativeInsertPos = NSMaxRange(lr) - cover.location
                    let insertion = indent + "\n"
                    let caretOffset = (lineText as NSString).length + (indent as NSString).length
                    plans.append(InsertionPlan(relativePos: relativeInsertPos, insertionText: insertion, caretOffsetFromLineStart: caretOffset))
                } else {
                    let relativeInsertPos = NSMaxRange(lr) - cover.location
                    let insertion = "\n" + indent
                    let caretOffset = (lineText as NSString).length + 1 + (indent as NSString).length
                    plans.append(InsertionPlan(relativePos: relativeInsertPos, insertionText: insertion, caretOffsetFromLineStart: caretOffset))
                }
            }

            for plan in plans.reversed() {
                combined.insert(plan.insertionText, at: plan.relativePos)
            }

            var newCarets: [Int] = []
            var cumulativeShift = 0
            for (idx, plan) in plans.enumerated() {
                let lr = lineRanges[idx]
                newCarets.append(lr.location + cumulativeShift + plan.caretOffsetFromLineStart)
                cumulativeShift += (plan.insertionText as NSString).length
            }

            textView.replaceCharacters(in: cover, with: combined as String)
            let newSelections = newCarets.sorted().map {
                NSRange(location: min($0, textView.textStorage.length), length: 0)
            }
            select(newSelections, on: textView)
            return true
        case .deleteWordBackward:
            textView.deleteWordBackward(nil)
        case .deleteWordForward:
            textView.deleteWordForward(nil)
        case .deleteToBeginningOfLine:
            textView.deleteToBeginningOfLine(nil)
        case .deleteToEndOfLine:
            textView.deleteToEndOfLine(nil)
        case .moveWordLeft:
            textView.moveWordLeft(nil)
        case .moveWordRight:
            textView.moveWordRight(nil)
        case .selectWordLeft:
            textView.moveWordLeftAndModifySelection(nil)
        case .selectWordRight:
            textView.moveWordRightAndModifySelection(nil)
        case .moveToLineStart:
            textView.moveToLeftEndOfLine(nil)
        case .moveToLineEnd:
            textView.moveToRightEndOfLine(nil)
        case .selectToLineStart:
            textView.moveToLeftEndOfLineAndModifySelection(nil)
        case .selectToLineEnd:
            textView.moveToRightEndOfLineAndModifySelection(nil)
        case .moveToDocumentStart:
            textView.moveToBeginningOfDocument(nil)
        case .moveToDocumentEnd:
            textView.moveToEndOfDocument(nil)
        case .selectToDocumentStart:
            textView.moveToBeginningOfDocumentAndModifySelection(nil)
        case .selectToDocumentEnd:
            textView.moveToEndOfDocumentAndModifySelection(nil)
        default: return false
        }
        return true
    }

    static func perform(_ action: EditorAction, on controller: TextViewController) -> Bool {
        switch action {
        case .indent, .outdent, .toggleLineComment:
            controller.setCursorPositions(
                controller.textView.selectionManager.textSelections.map { CursorPosition(range: $0.range) }
            )
            switch action {
            case .indent: controller.handleIndent()
            case .outdent: controller.handleIndent(inwards: true)
            case .toggleLineComment: controller.handleCommandSlash()
            default: break
            }
            return true
        default:
            return perform(action, on: controller.textView)
        }
    }
}
