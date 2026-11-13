import AppKit

enum EditorAction: Hashable {
    case cut, copy, paste, selectAll, selectLine, undo, redo
    case find, replace, goToLine, findNext, findPrevious, documentSymbols
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
    enum Profile: String {
        case idea
        case vscode
    }

    static let idea = EditorKeymap(profile: .idea)
    static let vscode = EditorKeymap(profile: .vscode)

    let profile: Profile
    let actions: [EditorKeyStroke: EditorAction]

    init(profile: Profile) {
        self.profile = profile
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
            .init(key: "p", modifiers: .command): .open,
            .init(key: "o", modifiers: [.command, .shift]): .documentSymbols,
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
