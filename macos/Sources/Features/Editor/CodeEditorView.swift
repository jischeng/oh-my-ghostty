import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
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
    @StateObject private var completionState = CompletionState()
    @State private var isCursorPushed = false
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
        ZStack(alignment: .topLeading) {
            CodeEditSourceEditor(
                $text,
                language: editorCoordinator.language(fileURL: fileURL, text: text),
                theme: resolvedTheme,
                font: resolvedFont,
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
            .onHover { inside in
                if inside && !isCursorPushed {
                    isCursorPushed = true
                    NSCursor.iBeam.push()
                } else if !inside && isCursorPushed {
                    isCursorPushed = false
                    NSCursor.pop()
                }
            }

            if completionState.isPresented && !completionState.candidates.isEmpty {
                EditorCompletionPopupView(state: completionState) { item in
                    editorCoordinator.commit(completion: item)
                }
                .offset(x: completionState.presentationPoint.x, y: completionState.presentationPoint.y)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isActive, isFindVisible {
                findBar
                    .padding(8)
            }
        }
        .background(Color.clear)
        .onDisappear {
            if isCursorPushed {
                isCursorPushed = false
                NSCursor.pop()
            }
        }
        .onAppear {
            editorCoordinator.setCompletionState(completionState)
            editorCoordinator.setFileURL(fileURL)
            configureCommands()
            editorCoordinator.setActive(isActive)
        }
        .onChange(of: isActive) { isActive in
            configureCommands()
            editorCoordinator.setActive(isActive)
            if !isActive {
                isFindVisible = false
                completionState.dismiss()
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

    private var resolvedFont: NSFont {
        let size = editorSettings.fontSize
        switch editorSettings.fontFamily {
        case .jetbrainsMono:
            return NSFont(name: "JetBrainsMono-Regular", size: size)
                ?? NSFont(name: "JetBrains Mono", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfMono:
            return NSFont(name: "SFMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo-Regular", size: size)
                ?? NSFont(name: "Menlo", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .firaCode:
            return NSFont(name: "FiraCode-Regular", size: size)
                ?? NSFont(name: "Fira Code", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private var resolvedTheme: EditorTheme {
        var baseTheme: EditorTheme
        switch editorSettings.syntaxTheme {
        case .oneDark: baseTheme = .oneDark
        case .oneLight: baseTheme = .oneLight
        case .dracula: baseTheme = .dracula
        case .githubDark: baseTheme = .githubDark
        case .nord: baseTheme = .nord
        case .monokai: baseTheme = .monokai
        case .catppuccinMocha: baseTheme = .catppuccinMocha
        case .followTerminal: baseTheme = .adaptive(background: .clear, foreground: editorForeground)
        }
        baseTheme.background = .clear
        return baseTheme
    }

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
    private weak var completionState: CompletionState?
    private var completionTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var columnDragStart: CGPoint?
    private var fileURL: URL?
    private var cachedLanguage: CodeLanguage?
    private var isActive = false
    private var keymap = EditorKeymap(profile: .idea)
    private var findFieldFocused: () -> Bool = { false }
    private var onFocus: () -> Void = {}
    private var actionHandler: (EditorAction) -> Bool = { _ in false }

    func setCompletionState(_ state: CompletionState) {
        self.completionState = state
    }

    func setFileURL(_ fileURL: URL?) {
        self.fileURL = fileURL
    }

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
        if let path = fileURL?.path.lowercased() {
            if path.hasSuffix(".ghostty") || path.hasSuffix(".conf") || path.hasSuffix(".ini") || path.hasSuffix(".cfg") {
                cachedLanguage = .toml
                return .toml
            }
        }
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
        if let scrollView = controller.textView.enclosingScrollView {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.documentCursor = .iBeam
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            for subview in scrollView.subviews {
                for inner in subview.subviews where String(describing: type(of: inner)).contains("GutterView") {
                    inner.setValue(NSColor.clear, forKey: "backgroundColor")
                }
            }
        }
        controller.textView.selectionManager.selectionBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.65)
        installMouseMonitor()
        if isActive { registerCommands() }
        focusIfActive(onNextRunLoop: true)
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            guard let self, self.isActive, let textView = self.controller?.textView,
                  event.window === textView.window else {
                return event
            }
            if let scrollView = textView.enclosingScrollView {
                let locInScroll = scrollView.convert(event.locationInWindow, from: nil)
                if scrollView.bounds.contains(locInScroll) {
                    NSCursor.iBeam.set()
                }
            }
            let locInTextView = textView.convert(event.locationInWindow, from: nil)

            switch event.type {
            case .leftMouseDown:
                if event.modifierFlags.contains(.option), textView.bounds.contains(locInTextView) {
                    self.columnDragStart = locInTextView
                    self.handleColumnSelection(at: locInTextView, start: locInTextView)
                    return nil
                }
            case .leftMouseDragged:
                if let start = self.columnDragStart {
                    self.handleColumnSelection(at: locInTextView, start: start)
                    return nil
                }
            case .leftMouseUp:
                if self.columnDragStart != nil {
                    self.columnDragStart = nil
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func handleColumnSelection(at current: CGPoint, start: CGPoint) {
        guard let controller, let layoutManager = controller.textView.layoutManager else { return }
        let lineHeight = max(14, layoutManager.estimateLineHeight())
        let minY = min(start.y, current.y)
        let maxY = max(start.y, current.y)
        let isBox = abs(current.x - start.x) >= 6

        var ranges: [NSRange] = []
        var seen = Set<Int>()

        var y = minY + lineHeight / 2
        while y <= maxY + lineHeight / 2 {
            if isBox {
                if let o1 = layoutManager.textOffsetAtPoint(CGPoint(x: start.x, y: y)),
                   let o2 = layoutManager.textOffsetAtPoint(CGPoint(x: current.x, y: y)) {
                    let loc = min(o1, o2)
                    let len = abs(o2 - o1)
                    if !seen.contains(loc) {
                        seen.insert(loc)
                        ranges.append(NSRange(location: loc, length: len))
                    }
                }
            } else {
                if let offset = layoutManager.textOffsetAtPoint(CGPoint(x: start.x, y: y)) {
                    if !seen.contains(offset) {
                        seen.insert(offset)
                        ranges.append(NSRange(location: offset, length: 0))
                    }
                }
            }
            y += lineHeight
        }

        if !ranges.isEmpty {
            controller.textView.selectionManager.setSelectedRanges(ranges)
            controller.textView.setNeedsDisplay()
            NotificationCenter.default.post(
                name: TextSelectionManager.selectionChangedNotification,
                object: controller.textView.selectionManager
            )
        }
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
            DispatchQueue.main.async { applyFocus() }
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

    func textViewDidChangeText(controller: TextViewController) {
        updateCompletion(controller: controller)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        guard let completionState, completionState.isPresented else { return }
        guard let sel = controller.textView.selectionManager.textSelections.first?.range else {
            completionState.dismiss()
            return
        }
        if sel.location < completionState.prefixRange.location {
            completionState.dismiss()
        }
    }

    private func updateCompletion(controller: TextViewController) {
        guard isActive else {
            completionState?.dismiss()
            return
        }

        guard let textSelection = controller.textView.selectionManager.textSelections.first,
              textSelection.range.length == 0 else {
            completionState?.dismiss()
            return
        }

        let cursorLocation = textSelection.range.location
        let string = controller.textView.string as NSString
        guard cursorLocation <= string.length else {
            completionState?.dismiss()
            return
        }

        var wordStart = cursorLocation
        while wordStart > 0 {
            let char = string.character(at: wordStart - 1)
            if let scalar = UnicodeScalar(char),
               CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                wordStart -= 1
            } else {
                break
            }
        }

        let prefixLength = cursorLocation - wordStart
        guard prefixLength >= 1 else {
            completionState?.dismiss()
            return
        }

        let prefix = string.substring(with: NSRange(location: wordStart, length: prefixLength))
        let prefixRange = NSRange(location: wordStart, length: prefixLength)

        let lineIdx = controller.textView.layoutManager.textLineForOffset(cursorLocation)?.index ?? 0
        let estHeight = max(14, controller.textView.layoutManager.estimateLineHeight())
        let cursorRect: CGRect
        if let rect = controller.textView.layoutManager.rectForOffset(cursorLocation), rect.height > 0 {
            cursorRect = rect
        } else {
            cursorRect = CGRect(x: 40, y: CGFloat(lineIdx) * estHeight, width: 2, height: estHeight)
        }

        guard let scrollView = controller.textView.enclosingScrollView else { return }
        let originInScroll = controller.textView.convert(cursorRect.origin, to: scrollView)
        guard originInScroll.y >= 0 else { return }

        let popupX = max(12, min(originInScroll.x, scrollView.bounds.width - 260))
        var popupY = originInScroll.y + cursorRect.height + 4
        if popupY + 200 > scrollView.bounds.height, originInScroll.y > 210 {
            popupY = originInScroll.y - 195
        }
        let anchorPoint = CGPoint(x: popupX, y: max(8, popupY))

        // Immediately update existing candidates and prefix synchronously!
        if let completionState, completionState.isPresented {
            completionState.filter(prefix: prefix, prefixRange: prefixRange, at: anchorPoint)
        }

        let lineRange = string.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let lineText = string.substring(with: lineRange)
        let lang = self.cachedLanguage?.tsName.lowercased()

        let context = CompletionContext(
            documentText: controller.textView.string,
            cursorOffset: cursorLocation,
            prefix: prefix,
            lineText: lineText,
            language: lang,
            fileURL: self.fileURL
        )

        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000)
            guard !Task.isCancelled else { return }
            let candidates = await EditorCompletionEngine.shared.completions(for: context)
            guard !Task.isCancelled, let self, self.isActive else { return }

            self.completionState?.update(
                candidates: candidates,
                prefix: prefix,
                prefixRange: prefixRange,
                at: anchorPoint
            )
        }
    }

    func commit(completion: CompletionItem) {
        guard let controller,
              let completionState,
              completionState.isPresented else { return }

        let range = completionState.prefixRange
        let insertText = completion.insertText
        completionState.dismiss()

        guard range.location != NSNotFound,
              NSMaxRange(range) <= controller.textView.textStorage.length else { return }

        controller.textView.replaceCharacters(in: range, with: insertText)
        let newCursorPos = range.location + (insertText as NSString).length
        let newRange = NSRange(location: newCursorPos, length: 0)
        controller.setCursorPositions([CursorPosition(range: newRange)])
        controller.textView.selectionManager.setSelectedRange(newRange)
        controller.textView.scrollSelectionToVisible()
        controller.textView.updatedViewport(controller.textView.visibleRect)
        controller.textView.needsDisplay = true
    }

    func destroy() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        completionTask?.cancel()
        completionTask = nil
        completionState?.dismiss()
        completionState = nil
        EditorCommandRouter.shared.unregister(owner: self)
        controller = nil
        isActive = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isActive, let textView = controller?.textView,
              event.window === textView.window else { return false }

        if let completionState, completionState.isPresented, !completionState.candidates.isEmpty {
            switch event.keyCode {
            case 125: // Down arrow
                completionState.selectNext()
                return true
            case 126: // Up arrow
                completionState.selectPrevious()
                return true
            case 48: // Tab
                if let candidate = completionState.currentSelection {
                    commit(completion: candidate)
                    return true
                }
            case 36: // Enter / Return
                if let candidate = completionState.currentSelection {
                    commit(completion: candidate)
                    return true
                }
            case 53: // Escape
                completionState.dismiss()
                return true
            case 45 where event.modifierFlags.contains(.control): // Ctrl + N
                completionState.selectNext()
                return true
            case 35 where event.modifierFlags.contains(.control): // Ctrl + P
                completionState.selectPrevious()
                return true
            default:
                break
            }
        }

        guard let action = keymap.action(for: event) else { return false }
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
