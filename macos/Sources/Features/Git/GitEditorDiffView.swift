import AppKit
import SwiftUI
import CodeEditSourceEditor

struct GitEditorDiffRequest: Identifiable {
    let id = UUID()
    let repository: GitRepositoryIdentity
    let target: GitDiffTarget
    let file: GitDiffFile?
}

struct GitDiffEditorActions {
    var hide: () -> Void = {}
    var open: () -> Void = {}
    var nextDocument: () -> Void = {}
    var previousDocument: () -> Void = {}
    var saveAll: () -> Void = {}
    var focus: () -> Void = {}
    var isSurfaceFocused: () -> Bool = { true }
}

struct GitEditorDiffView: View {
    let request: GitEditorDiffRequest
    let theme: EditorTheme
    var isActive = true
    var actions = GitDiffEditorActions()
    let close: () -> Void
    @StateObject private var model: GitEditorDiffModel
    @State private var mode = "Side by Side"
    @State private var scroll = GitDiffScrollLink()
    @State private var linkedScrolling = true

    init(request: GitEditorDiffRequest, theme: EditorTheme, isActive: Bool = true,
         actions: GitDiffEditorActions = GitDiffEditorActions(), close: @escaping () -> Void) {
        self.request = request
        self.theme = theme
        self.isActive = isActive
        self.actions = actions
        self.close = close
        _model = StateObject(wrappedValue: GitEditorDiffModel(request: request))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(request.repository.sshConnection.map { "SSH · " + $0.destination + " · " + request.target.description }
                     ?? request.target.description)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .help(request.repository.worktreePath)
                Spacer()
                Picker("View", selection: $mode) {
                    Text("Side by Side").tag("Side by Side")
                    Text("Inline").tag("Inline")
                }.pickerStyle(.menu).labelsHidden().fixedSize()
                if mode == "Side by Side" {
                    Button { linkedScrolling.toggle() } label: {
                        Image(systemName: linkedScrolling ? "link" : "link.slash")
                    }.help(linkedScrolling ? "Disable linked scrolling" : "Enable linked scrolling")
                }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh diff").disabled(model.isLoading)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }.padding(8)
            if !model.files.isEmpty {
                Menu {
                    ForEach(model.files) { file in
                        Button(file.displayPath) { model.select(file) }
                    }
                } label: {
                    Text(model.selected?.displayPath ?? "Select file")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 8)

            }
            Divider()
            if model.isLoading { ProgressView().padding() }
            if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            if let content = model.content {
                let document = content.document
                if document.isBinary || document.isTruncated {
                    Text(document.summary ?? document.text).padding()
                } else if let sourceError = content.sourceError {
                    Text(sourceError).foregroundStyle(.secondary).padding()
                    GitDiffTextView(text: document.text)
                } else if let presentation = content.presentation {
                    if mode == "Side by Side" {
                        HSplitView {
                            sourcePane("Before", text: content.before, path: document.file.oldPath ?? document.file.path,
                                       highlights: presentation.beforeHighlights, side: 0)
                            sourcePane("After", text: content.after, path: document.file.path,
                                       highlights: presentation.afterHighlights, side: 1)
                        }
                    } else {
                        CodeEditorView(text: .constant(presentation.text),
                                       fileURL: URL(fileURLWithPath: document.file.path, isDirectory: false),
                                       diffLines: presentation.highlights,
                                       isEditable: false, isActive: isActive, isSurfaceFocused: actions.isSurfaceFocused,
                                       terminalTheme: theme, onFocus: actions.focus, onClose: close, onOpen: actions.open,
                                       onNextDocument: actions.nextDocument, onPreviousDocument: actions.previousDocument,
                                       onSaveAll: actions.saveAll, onHide: actions.hide)
                            .id("inline-\(model.selected?.id ?? "")")
                    }
                }
            } else if !model.isLoading && model.error == nil {
                Text("No changed files").foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GitDiffFallbackCommands(
            isActive: isActive && (model.content?.presentation == nil || model.content?.sourceError != nil),
            actions: actions, close: close
        ))
        .onAppear { model.reload() }
        .onDisappear { model.cancel() }
        .onChange(of: linkedScrolling) { scroll.enabled = $0 }
        .onChange(of: model.content?.presentation) { scroll.presentation = $0 ?? GitDiffPresentation(before: "", after: "", patch: "") }
    }

    private func sourcePane(_ title: String, text: String, path: String, highlights: [Int: Bool], side: Int) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption).padding(6)
                .frame(maxWidth: .infinity)
                .background(side == 0 ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            GitDiffLinkedEditor(text: text, path: path, highlights: highlights,
                                isActive: isActive, theme: theme, link: scroll, side: side, actions: actions, close: close)
                .id("\(model.selected?.id ?? "")-\(side)")
        }.frame(minWidth: 120)
    }
}

/// Loading, binary and error views have no CodeEditorView to own shortcuts.
private struct GitDiffFallbackCommands: NSViewRepresentable {
    let isActive: Bool
    let actions: GitDiffEditorActions
    let close: () -> Void

    final class Scope: NSView {
        var active = false
        var actions = GitDiffEditorActions()
        var close: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func handle(_ event: NSEvent) -> Bool {
            guard active, window != nil, event.window === window, actions.isSurfaceFocused(),
                  let action = OhMyGhosttySettings.shared.editorSettings.keymap.action(for: event) else { return false }
            switch action {
            case .hide: actions.hide()
            case .close: close()
            case .open: actions.open()
            case .nextDocument: actions.nextDocument()
            case .previousDocument: actions.previousDocument()
            case .saveAll: actions.saveAll()
            case .save: break
            default: return false
            }
            return true
        }
    }

    func makeNSView(context: Context) -> Scope {
        let view = Scope()
        EditorCommandRouter.shared.register(owner: view) { [weak view] event in view?.handle(event) ?? false }
        return view
    }
    func updateNSView(_ view: Scope, context: Context) {
        view.active = isActive
        view.actions = actions
        view.close = close
    }
    static func dismantleNSView(_ view: Scope, coordinator: ()) {
        EditorCommandRouter.shared.unregister(owner: view)
    }
}
