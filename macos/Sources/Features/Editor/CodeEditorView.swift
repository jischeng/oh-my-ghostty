import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// A lightweight native source editor surface for editable OMG documents.
///
/// Document loading and persistence intentionally remain with the caller. The
/// editor owns presentation state such as the current selection and find bar.
struct CodeEditorView: View {
    @Binding var text: String

    let fileURL: URL?
    var isEditable = true
    var isActive = true
    var onSave: () -> Void = {}
    var onClose: () -> Void = {}
    var onOpen: () -> Void = {}
    var onNextDocument: () -> Void = {}
    var onPreviousDocument: () -> Void = {}
    var onSaveAll: () -> Void = {}

    @State private var cursorPositions: [CursorPosition] = []
    @State private var editorCoordinator = EditorCoordinator()
    @State private var isFindVisible = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var barMode: BarMode = .find
    @FocusState private var isFindFocused: Bool

    init(
        text: Binding<String>,
        fileURL: URL?,
        isEditable: Bool = true,
        isActive: Bool = true,
        onSave: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onOpen: @escaping () -> Void = {},
        onNextDocument: @escaping () -> Void = {},
        onPreviousDocument: @escaping () -> Void = {},
        onSaveAll: @escaping () -> Void = {}
    ) {
        self._text = text
        self.fileURL = fileURL
        self.isEditable = isEditable
        self.isActive = isActive
        self.onSave = onSave
        self.onClose = onClose
        self.onOpen = onOpen
        self.onNextDocument = onNextDocument
        self.onPreviousDocument = onPreviousDocument
        self.onSaveAll = onSaveAll
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CodeEditSourceEditor(
                $text,
                language: editorCoordinator.language(fileURL: fileURL, text: text),
                theme: .omg,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                tabWidth: 4,
                lineHeight: 1.2,
                wrapLines: false,
                cursorPositions: $cursorPositions,
                isEditable: isEditable && isActive,
                isSelectable: isActive,
                bracketPairHighlight: .flash,
                coordinators: [editorCoordinator]
            )

            if isActive, isFindVisible {
                findBar
                    .padding(8)
            } else if isActive {
                Menu {
                    Button("Find", action: presentFind)
                    Button("Find and Replace", action: presentReplace)
                    Button("Go to Line", action: presentGoToLine)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(10)
                .help("Find and Navigate")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background {
            if isActive {
                EditorKeyCommands(actions: [
                    "x": { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) },
                    "f": presentFind,
                    "s": onSave,
                    "w": onClose,
                    "o": onOpen,
                ], modifiedActions: [
                    EditorShortcut(key: "f", modifiers: [.command, .option]): presentReplace,
                    EditorShortcut(key: "l", modifiers: .command): presentGoToLine,
                    EditorShortcut(key: "g", modifiers: .command): findNext,
                    EditorShortcut(key: "g", modifiers: [.command, .shift]): findPrevious,
                    EditorShortcut(key: "s", modifiers: [.command, .shift]): onSaveAll,
                    EditorShortcut(key: "\t", modifiers: .control): onNextDocument,
                    EditorShortcut(key: "\t", modifiers: [.control, .shift]): onPreviousDocument,
                ])
            }
        }
        .onAppear {
            editorCoordinator.setActive(isActive)
        }
        .onChange(of: isActive) { isActive in
            editorCoordinator.setActive(isActive)
            if !isActive {
                isFindVisible = false
            }
        }
    }

    private var findBar: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                TextField(barMode == .goToLine ? "Line:Column" : "Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 150, maxWidth: 180)
                .focused($isFindFocused)
                .onSubmit(barMode == .goToLine ? goToLine : findNext)
                .onExitCommand(perform: leaveFindBar)

                if barMode != .goToLine {
                    Text(matchSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28)
                    Button(action: findPrevious) { Image(systemName: "chevron.up") }
                        .help("Previous Match")
                    Button(action: findNext) { Image(systemName: "chevron.down") }
                        .help("Next Match")
                    Toggle("Aa", isOn: $caseSensitive)
                        .toggleStyle(.button)
                        .help("Match Case")
                }

                Button(action: leaveFindBar) {
                    Image(systemName: "xmark")
                }
                .help("Close")
            }

            if barMode == .replace {
                HStack(spacing: 4) {
                    TextField("Replace", text: $replaceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 90, idealWidth: 150, maxWidth: 180)
                        .onSubmit(replaceCurrent)
                    Button("Replace", action: replaceCurrent)
                    Button("All", action: replaceAll)
                }
                .controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(radius: 3, y: 1)
    }

    private func presentFind() {
        if let selection = cursorPositions.first?.range,
           selection.location != NSNotFound,
           selection.length > 0,
           let range = Range(selection, in: text) {
            findText = String(text[range])
        }
        barMode = .find
        isFindVisible = true
        isFindFocused = true
    }

    private func presentReplace() {
        presentFind()
        barMode = .replace
    }

    private func presentGoToLine() {
        barMode = .goToLine
        findText = ""
        isFindVisible = true
        isFindFocused = true
    }

    private func findNext() {
        selectMatch(searchingForward: true)
    }

    private func findPrevious() {
        selectMatch(searchingForward: false)
    }

    private func selectMatch(searchingForward: Bool) {
        let current = cursorPositions.first?.range ?? NSRange(location: 0, length: 0)
        let matches = searchMatches
        guard let index = EditorTextSearch.matchIndex(
            in: matches, selection: current, searchingForward: searchingForward
        ) else { return }
        editorCoordinator.select(matches[index])
    }

    private var searchMatches: [NSRange] {
        EditorTextSearch.matches(in: text, query: findText, caseSensitive: caseSensitive)
    }

    private var matchSummary: String {
        let matches = searchMatches
        guard !matches.isEmpty else { return "0/0" }
        let selected = cursorPositions.first?.range
        let index = matches.firstIndex(of: selected ?? .notFound).map { $0 + 1 } ?? 0
        return "\(index)/\(matches.count)"
    }

    private func replaceCurrent() {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        let selection = cursorPositions.first?.range
        let nextIndex = EditorTextSearch.matchIndex(in: matches, selection: selection, searchingForward: true) ?? 0
        let range = matches.first(where: { $0 == selection }) ?? matches[nextIndex]
        editorCoordinator.replace(
            ranges: [range],
            with: replaceText,
            selectionAfterEdit: NSRange(location: range.location, length: (replaceText as NSString).length)
        )
    }

    private func replaceAll() {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        let first = matches[0]
        editorCoordinator.replace(
            ranges: matches,
            with: replaceText,
            selectionAfterEdit: NSRange(location: first.location, length: (replaceText as NSString).length)
        )
    }

    private func goToLine() {
        guard let target = EditorTextSearch.lineAndColumn(from: findText),
              let range = EditorTextSearch.range(forLine: target.line, column: target.column, in: text) else { return }
        editorCoordinator.select(range)
        leaveFindBar()
    }

    private func leaveFindBar() {
        isFindVisible = false
        isFindFocused = false
        editorCoordinator.focus()
    }

    private enum BarMode { case find, replace, goToLine }
}

@MainActor
private final class EditorCoordinator: @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private var cachedLanguage: CodeLanguage?
    private var isActive = false

    func language(fileURL: URL?, text: String) -> CodeLanguage {
        if let cachedLanguage { return cachedLanguage }
        let language: CodeLanguage = fileURL.map {
            .detectLanguageFrom(
                url: $0,
                prefixBuffer: String(text.prefix(2_048)),
                suffixBuffer: String(text.suffix(2_048))
            )
        } ?? .default
        cachedLanguage = language
        return language
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        focusIfActive(onNextRunLoop: true)
    }

    func setActive(_ isActive: Bool) {
        let didActivate = isActive && !self.isActive
        self.isActive = isActive
        if didActivate {
            focusIfActive(onNextRunLoop: true)
        } else if !isActive,
                  let textView = controller?.textView,
                  textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    func focus() {
        focusIfActive(onNextRunLoop: false)
    }

    private func focusIfActive(onNextRunLoop: Bool) {
        let applyFocus = { [weak self] in
            guard let self, isActive, let textView = controller?.textView,
                  let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        if onNextRunLoop {
            DispatchQueue.main.async(execute: applyFocus)
        } else {
            applyFocus()
        }
    }

    func select(_ range: NSRange) {
        guard let controller else { return }
        controller.setCursorPositions([CursorPosition(range: range)])
        controller.textView.scrollSelectionToVisible()
    }

    func replace(ranges: [NSRange], with replacement: String, selectionAfterEdit: NSRange) {
        guard let controller else { return }
        guard EditorTextEditing.replace(on: controller.textView, ranges: ranges, with: replacement) else { return }
        select(selectionAfterEdit)
    }

    func destroy() {
        controller = nil
        isActive = false
    }
}

private extension EditorTheme {
    static var omg: EditorTheme {
        EditorTheme(
            text: .textColor,
            insertionPoint: .textColor,
            invisibles: .tertiaryLabelColor,
            background: .textBackgroundColor,
            lineHighlight: .controlAccentColor.withAlphaComponent(0.08),
            selection: .selectedTextBackgroundColor,
            keywords: .systemPurple,
            commands: .systemTeal,
            types: .systemBlue,
            attributes: .systemOrange,
            variables: .textColor,
            values: .systemIndigo,
            numbers: .systemBlue,
            strings: .systemRed,
            characters: .systemRed,
            comments: .systemGreen
        )
    }
}
