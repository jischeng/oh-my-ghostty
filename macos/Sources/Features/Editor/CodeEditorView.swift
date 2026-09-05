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

    @State private var cursorPositions: [CursorPosition] = []
    @State private var editorCoordinator = EditorCoordinator()
    @State private var isFindVisible = false
    @State private var findText = ""
    @FocusState private var isFindFocused: Bool

    init(
        text: Binding<String>,
        fileURL: URL?,
        isEditable: Bool = true,
        isActive: Bool = true,
        onSave: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onOpen: @escaping () -> Void = {}
    ) {
        self._text = text
        self.fileURL = fileURL
        self.isEditable = isEditable
        self.isActive = isActive
        self.onSave = onSave
        self.onClose = onClose
        self.onOpen = onOpen
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
                Button(action: presentFind) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .padding(10)
                .help("Find")
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
        HStack(spacing: 6) {
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($isFindFocused)
                .onSubmit(findNext)
                .onExitCommand {
                    isFindVisible = false
                    isFindFocused = false
                }

            Button(action: findPrevious) {
                Image(systemName: "chevron.up")
            }
            .help("Previous Match")

            Button(action: findNext) {
                Image(systemName: "chevron.down")
            }
            .help("Next Match")

            Button {
                isFindVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Find")
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
        guard !findText.isEmpty else { return }

        let source = text as NSString
        let current = cursorPositions.first?.range ?? NSRange(location: 0, length: 0)
        let start = current.location == NSNotFound
            ? 0
            : searchingForward ? NSMaxRange(current) : current.location
        let primaryRange = searchingForward
            ? NSRange(location: min(start, source.length), length: max(0, source.length - min(start, source.length)))
            : NSRange(location: 0, length: min(start, source.length))
        let options: NSString.CompareOptions = searchingForward ? [] : [.backwards]

        var match = source.range(of: findText, options: options, range: primaryRange)
        if match.location == NSNotFound {
            match = source.range(
                of: findText,
                options: options,
                range: NSRange(location: 0, length: source.length)
            )
        }
        guard match.location != NSNotFound else { return }
        editorCoordinator.scrollNextSelectionToVisible()
        cursorPositions = [CursorPosition(range: match)]
    }
}

@MainActor
private final class EditorCoordinator: @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private var cachedLanguage: CodeLanguage?
    private var shouldScrollNextSelection = false

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
    }

    func setActive(_ isActive: Bool) {
        guard !isActive,
              let textView = controller?.textView,
              textView.window?.firstResponder === textView else { return }
        textView.window?.makeFirstResponder(nil)
    }

    func scrollNextSelectionToVisible() {
        shouldScrollNextSelection = true
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        guard shouldScrollNextSelection else { return }
        shouldScrollNextSelection = false
        controller.textView.scrollSelectionToVisible()
    }

    func destroy() {
        controller = nil
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
