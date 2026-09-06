import AppKit
import CodeEditSourceEditor
import CodeEditTextView

enum EditorAction: Hashable {
    case cut, copy, paste, selectAll, selectLine, undo, redo
    case find, replace, goToLine, findNext, findPrevious
    case save, saveAll, close, open, nextDocument, previousDocument
    case duplicateLine, deleteLine, moveLineUp, moveLineDown, indent, outdent, toggleLineComment
    case insertLineBelow
}

struct EditorKeyStroke: Hashable {
    static let tab = "\t"
    static let backspace = "\u{8}"
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
    @discardableResult
    static func select(_ range: NSRange, on textView: TextView) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              NSMaxRange(range) <= textView.textStorage.length else { return false }
        textView.selectionManager.setSelectedRange(range)
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
            guard textView.isEditable,
                  let selection = textView.selectionManager.textSelections.first?.range else { return true }
            if selection.length > 0 {
                textView.cut(textView)
            } else if let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) {
                let source = textView.string as NSString
                let lineText = source.substring(with: lineRange)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lineText, forType: .string)
                textView.replaceCharacters(in: lineRange, with: "")
                select(NSRange(location: min(lineRange.location, textView.textStorage.length), length: 0), on: textView)
            }
            return true
        case .copy:
            guard let selection = textView.selectionManager.textSelections.first?.range else { return true }
            if selection.length > 0 {
                textView.copy(textView)
            } else if let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) {
                let source = textView.string as NSString
                let lineText = source.substring(with: lineRange)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lineText, forType: .string)
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
            guard textView.isEditable,
                  let selection = textView.selectionManager.textSelections.first?.range,
                  let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) else {
                return false
            }
            let source = textView.string as NSString
            var duplicate = source.substring(with: lineRange)
            var insertion = NSMaxRange(lineRange)
            if !duplicate.hasSuffix("\n") {
                duplicate = "\n" + duplicate
                insertion = source.length
            }
            textView.replaceCharacters(in: NSRange(location: insertion, length: 0), with: duplicate)
            select(
                NSRange(location: selection.location + duplicate.utf16.count, length: selection.length),
                on: textView
            )
        case .deleteLine:
            guard textView.isEditable,
                  let selection = textView.selectionManager.textSelections.first?.range,
                  let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) else {
                return false
            }
            textView.replaceCharacters(in: lineRange, with: "")
            select(
                NSRange(location: min(lineRange.location, textView.textStorage.length), length: 0),
                on: textView
            )
        case .moveLineUp:
            guard textView.isEditable,
                  let selection = textView.selectionManager.textSelections.first?.range,
                  let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) else {
                return false
            }
            guard lineRange.location > 0 else { return true }
            let source = textView.string as NSString
            let prevLineRange = source.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let currentLineText = source.substring(with: lineRange)
            let prevLineText = source.substring(with: prevLineRange)
            var newCurrentText = currentLineText
            var newPrevText = prevLineText
            if !newCurrentText.hasSuffix("\n") && newPrevText.hasSuffix("\n") {
                newCurrentText += "\n"
                newPrevText = String(newPrevText.dropLast())
            }
            let combinedRange = NSRange(location: prevLineRange.location, length: prevLineRange.length + lineRange.length)
            let swappedText = newCurrentText + newPrevText
            textView.replaceCharacters(in: combinedRange, with: swappedText)
            let offsetInLine = selection.location - lineRange.location
            let newSelectionLoc = prevLineRange.location + offsetInLine
            select(NSRange(location: newSelectionLoc, length: selection.length), on: textView)
        case .moveLineDown:
            guard textView.isEditable,
                  let selection = textView.selectionManager.textSelections.first?.range,
                  let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) else {
                return false
            }
            let source = textView.string as NSString
            let endOfLine = NSMaxRange(lineRange)
            guard endOfLine < source.length else { return true }
            let nextLineRange = source.lineRange(for: NSRange(location: endOfLine, length: 0))
            let currentLineText = source.substring(with: lineRange)
            let nextLineText = source.substring(with: nextLineRange)
            var newCurrentText = currentLineText
            var newNextText = nextLineText
            if !newNextText.hasSuffix("\n") && newCurrentText.hasSuffix("\n") {
                newNextText += "\n"
                newCurrentText = String(newCurrentText.dropLast())
            }
            let combinedRange = NSRange(location: lineRange.location, length: lineRange.length + nextLineRange.length)
            let swappedText = newNextText + newCurrentText
            textView.replaceCharacters(in: combinedRange, with: swappedText)
            let offsetInLine = selection.location - lineRange.location
            let newSelectionLoc = lineRange.location + (newNextText as NSString).length + offsetInLine
            select(NSRange(location: min(newSelectionLoc, textView.textStorage.length), length: selection.length), on: textView)
        case .insertLineBelow:
            guard textView.isEditable,
                  let selection = textView.selectionManager.textSelections.first?.range,
                  let lineRange = EditorTextSearch.lineRange(containing: selection, in: textView.string) else {
                return false
            }
            let source = textView.string as NSString
            let lineText = source.substring(with: lineRange)
            let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
            let hasNewline = lineText.hasSuffix("\n")
            let insertPos = hasNewline ? NSMaxRange(lineRange) - 1 : NSMaxRange(lineRange)
            let insertion = "\n" + indent
            textView.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: insertion)
            select(NSRange(location: insertPos + 1 + (indent as NSString).length, length: 0), on: textView)
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
