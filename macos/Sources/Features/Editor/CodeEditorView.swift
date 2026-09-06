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
    @ObservedObject private var settings = OhMyGhosttySettings.shared

    let fileURL: URL?
    var isEditable = true
    var isActive = true
    var terminalBackground: NSColor = .textBackgroundColor
    var terminalBackgroundOpacity: Double = 1.0
    var terminalForeground: NSColor = .textColor
    var onFocus: () -> Void = {}
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
        terminalBackground: NSColor = .textBackgroundColor,
        terminalBackgroundOpacity: Double = 1.0,
        terminalForeground: NSColor = .textColor,
        onFocus: @escaping () -> Void = {},
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
        self.terminalBackground = terminalBackground
        self.terminalBackgroundOpacity = terminalBackgroundOpacity
        self.terminalForeground = terminalForeground
        self.onFocus = onFocus
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
                theme: .omg(background: editorBackground, foreground: editorForeground),
                font: .monospacedSystemFont(ofSize: editorSettings.fontSize, weight: .regular),
                tabWidth: editorSettings.tabWidth,
                lineHeight: 1.2,
                wrapLines: editorSettings.wordWrap,
                cursorPositions: $cursorPositions,
                useThemeBackground: true,
                highlightProviders: [TreeSitterClient(), MarkdownHighlightProvider()],
                contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                isEditable: isEditable && isActive,
                isSelectable: isActive,
                bracketPairHighlight: .flash,
                coordinators: [editorCoordinator]
            )
            .clipped()

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
        .background(
            editorSettings.backgroundMode == .followTerminal
                ? Color(nsColor: terminalBackground).opacity(terminalBackgroundOpacity)
                : Color(nsColor: .textBackgroundColor)
        )
        .onAppear {
            configureCommands()
            editorCoordinator.setActive(isActive)
        }
        .onChange(of: isActive) { isActive in
            configureCommands()
            editorCoordinator.setActive(isActive)
            if !isActive {
                isFindVisible = false
            }
        }
        .onChange(of: settings.editorKeymapPreset) { _ in configureCommands() }
        .onChange(of: findText) { query in
            guard barMode != .goToLine, !query.isEmpty else { return }
            selectMatch(searchingForward: true)
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
        if let selection = editorCoordinator.selectedRange,
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
        let current = editorCoordinator.selectedRange ?? NSRange(location: 0, length: 0)
        let matches = searchMatches
        guard let index = EditorTextSearch.matchIndex(
            in: matches, selection: current, searchingForward: searchingForward
        ) else { return }
        editorCoordinator.select(matches[index], focusEditor: false)
    }

    private var searchMatches: [NSRange] {
        EditorTextSearch.matches(in: text, query: findText, caseSensitive: caseSensitive)
    }

    private var matchSummary: String {
        let matches = searchMatches
        guard !matches.isEmpty else { return "0/0" }
        let selected = editorCoordinator.selectedRange
        let index = matches.firstIndex(of: selected ?? .notFound).map { $0 + 1 } ?? 0
        return "\(index)/\(matches.count)"
    }

    private func replaceCurrent() {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        let selection = editorCoordinator.selectedRange
        let nextIndex = EditorTextSearch.matchIndex(in: matches, selection: selection, searchingForward: true) ?? 0
        let range = matches.first(where: { $0 == selection }) ?? matches[nextIndex]
        editorCoordinator.replace(
            ranges: [range],
            with: replaceText,
            selectionAfterEdit: NSRange(location: range.location, length: (replaceText as NSString).length),
            focusEditor: false
        )
    }

    private func replaceAll() {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        let first = matches[0]
        editorCoordinator.replace(
            ranges: matches,
            with: replaceText,
            selectionAfterEdit: NSRange(location: first.location, length: (replaceText as NSString).length),
            focusEditor: false
        )
    }

    private func goToLine() {
        guard let target = EditorTextSearch.lineAndColumn(from: findText),
              let range = EditorTextSearch.range(forLine: target.line, column: target.column, in: text) else { return }
        leaveFindBar()
        editorCoordinator.select(range, focusEditor: true)
    }

    private func leaveFindBar() {
        isFindVisible = false
        isFindFocused = false
        editorCoordinator.focus()
    }

    private func configureCommands() {
        editorCoordinator.configure(
            keymap: editorSettings.keymap,
            findFieldFocused: { isFindFocused },
            onFocus: onFocus,
            actionHandler: { action in
            switch action {
            case .find: presentFind()
            case .replace: presentReplace()
            case .goToLine: presentGoToLine()
            case .findNext: findNext()
            case .findPrevious: findPrevious()
            case .save: onSave()
            case .saveAll: onSaveAll()
            case .close: onClose()
            case .open: onOpen()
            case .nextDocument: onNextDocument()
            case .previousDocument: onPreviousDocument()
            default: return false
            }
            return true
        })
    }

    private var editorSettings: EditorSettings { settings.editorSettings }

    private var editorBackground: NSColor {
        if editorSettings.backgroundMode == .followTerminal {
            return terminalBackground.withAlphaComponent(terminalBackgroundOpacity)
        } else {
            return .textBackgroundColor
        }
    }

    private var editorForeground: NSColor {
        editorSettings.backgroundMode == .followTerminal ? terminalForeground : .textColor
    }

    private enum BarMode { case find, replace, goToLine }
}

@MainActor
private final class EditorCoordinator: @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private var cachedLanguage: CodeLanguage?
    private var isActive = false
    private var keymap = EditorKeymap(profile: .idea)
    private var findFieldFocused: () -> Bool = { false }
    private var onFocus: () -> Void = {}
    private var actionHandler: (EditorAction) -> Bool = { _ in false }

    var selectedRange: NSRange? {
        controller?.textView.selectionManager.textSelections.first?.range
    }

    func configure(
        keymap: EditorKeymap,
        findFieldFocused: @escaping () -> Bool,
        onFocus: @escaping () -> Void,
        actionHandler: @escaping (EditorAction) -> Bool
    ) {
        self.keymap = keymap
        self.findFieldFocused = findFieldFocused
        self.onFocus = onFocus
        self.actionHandler = actionHandler
    }

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
        let scrollView = controller.textView.enclosingScrollView
        scrollView?.automaticallyAdjustsContentInsets = false
        scrollView?.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView?.documentCursor = .iBeam
        controller.textView.selectionManager.selectionBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.65)
        if isActive { registerCommands() }
        focusIfActive(onNextRunLoop: true)
    }

    func setActive(_ isActive: Bool) {
        let didActivate = isActive && !self.isActive
        self.isActive = isActive
        if didActivate {
            registerCommands()
            focusIfActive(onNextRunLoop: true)
        } else if !isActive {
            EditorCommandRouter.shared.unregister(owner: self)
            if let textView = controller?.textView,
               textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }
    }

    func focus() {
        focusIfActive(onNextRunLoop: false)
    }

    private func focusIfActive(onNextRunLoop: Bool) {
        let applyFocus = { [weak self] in
            guard let self, isActive, let textView = controller?.textView,
                  let window = textView.window else { return }
            if window.firstResponder !== textView {
                if window.makeFirstResponder(textView) {
                    onFocus()
                }
            }
        }
        if onNextRunLoop {
            DispatchQueue.main.async(execute: applyFocus)
        } else {
            applyFocus()
        }
    }

    func select(_ range: NSRange, focusEditor: Bool = true) {
        guard let controller, let textView = controller.textView else { return }
        if focusEditor {
            focus()
        }
        controller.setCursorPositions([CursorPosition(range: range)])
        EditorNativeTextActions.select(range, on: textView)
    }

    func replace(
        ranges: [NSRange],
        with replacement: String,
        selectionAfterEdit: NSRange,
        focusEditor: Bool
    ) {
        guard let controller else { return }
        guard EditorTextEditing.replace(on: controller.textView, ranges: ranges, with: replacement) else { return }
        select(selectionAfterEdit, focusEditor: focusEditor)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        // Selection movement inside the text view must not trigger view-model focus changes,
        // which would invalidate the SwiftUI graph during editing/layout.
    }

    func destroy() {
        EditorCommandRouter.shared.unregister(owner: self)
        controller = nil
        isActive = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isActive, let textView = controller?.textView,
              event.window === textView.window,
              let action = keymap.action(for: event) else { return false }
        let responder = textView.window?.firstResponder
        let isTextViewOrChild = responder === textView || (responder as? NSView)?.isDescendant(of: textView) == true
        let editingField = (responder as? NSTextView)?.isFieldEditor == true
        guard isTextViewOrChild || editingField else { return false }
        if editingField {
            switch action {
            case .cut, .copy, .paste, .selectAll, .selectLine, .undo, .redo,
                 .duplicateLine, .deleteLine, .moveLineUp, .moveLineDown, .indent, .outdent, .toggleLineComment:
                return false
            default: return actionHandler(action)
            }
        }
        guard let controller else { return false }
        return EditorNativeTextActions.perform(action, on: controller) || actionHandler(action)
    }

    private func registerCommands() {
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            self?.handle(event) ?? false
        }
    }
}

private extension EditorTheme {
    static func omg(background: NSColor, foreground: NSColor) -> EditorTheme {
        EditorTheme(
            text: foreground,
            insertionPoint: foreground,
            invisibles: .tertiaryLabelColor,
            background: background,
            lineHighlight: .controlAccentColor.withAlphaComponent(0.08),
            selection: .selectedTextBackgroundColor,
            keywords: .systemPurple,
            commands: .systemBlue,
            types: .systemMint,
            attributes: .systemOrange,
            variables: .systemTeal,
            values: .systemIndigo,
            numbers: .systemOrange,
            strings: .systemGreen,
            characters: .systemGreen,
            comments: .secondaryLabelColor
        )
    }
}
