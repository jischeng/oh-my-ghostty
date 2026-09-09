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
    @State private var files: [GitDiffFile] = []
    @State private var selected: GitDiffFile?
    @State private var document: GitDiffDocument?
    @State private var before = ""
    @State private var after = ""
    @State private var lineMap = GitDiffLineMap("")
    @State private var error: String?
    @State private var sourceError: String?
    @State private var loading = true
    @State private var mode = "Side by Side"
    @State private var presentation = GitDiffPresentation(before: "", after: "", patch: "")
    @State private var scroll = GitDiffScrollLink()
    @State private var linkedScrolling = true
    @State private var reloadVersion = 0
    private let service = GitDiffService()

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
                Button { reloadVersion += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh diff").disabled(loading)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }.padding(8)
            if !files.isEmpty {
                Menu {
                    ForEach(files) { file in
                        Button(file.displayPath) { selected = file }
                    }
                } label: {
                    Text(selected?.displayPath ?? "Select file")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 8)

            }
            Divider()
            if loading { ProgressView().padding() }
            if let error { Text(error).foregroundStyle(.red).padding() }
            if let document, !loading {
                if document.isBinary || document.isTruncated {
                    Text(document.summary ?? document.text).padding()
                } else if let sourceError {
                    Text(sourceError).foregroundStyle(.secondary).padding()
                    GitDiffTextView(text: document.text)
                } else if mode == "Side by Side" {
                    HSplitView {
                        sourcePane("Before", text: before, path: document.file.oldPath ?? document.file.path, side: 0)
                        sourcePane("After", text: after, path: document.file.path, side: 1)
                    }
                } else {
                    CodeEditorView(text: .constant(presentation.text),
                                   fileURL: URL(fileURLWithPath: document.file.path, isDirectory: false),
                                   diffLines: presentation.highlights,
                                   isEditable: false, isActive: isActive, isSurfaceFocused: actions.isSurfaceFocused,
                                   terminalTheme: theme, onFocus: actions.focus, onClose: close, onOpen: actions.open,
                                   onNextDocument: actions.nextDocument, onPreviousDocument: actions.previousDocument,
                                   onSaveAll: actions.saveAll, onHide: actions.hide)
                        .id("inline-\(selected?.id ?? "")")
                }
            } else if !loading && error == nil {
                Text("No changed files").foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GitDiffFallbackCommands(
            isActive: isActive && (loading || document == nil || document?.isBinary == true ||
                                  document?.isTruncated == true || sourceError != nil),
            actions: actions, close: close
        ))
        .task {
            do {
                let list = try await service.listFiles(for: request.repository, target: request.target)
                try Task.checkCancellation()
                files = list.files
                selected = request.file.flatMap { requested in files.first { $0.id == requested.id } } ?? files.first
                loading = false
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; loading = false }
        }
        .onChange(of: linkedScrolling) { scroll.enabled = $0 }
        .task(id: "\(selected?.id ?? "")-\(reloadVersion)") {
            guard let selected else { return }
            document = nil
            error = nil
            sourceError = nil
            loading = true
            do {
                let diff = try await service.loadDiff(for: selected, repository: request.repository, target: request.target)
                try Task.checkCancellation()
                document = diff
                lineMap = GitDiffLineMap(diff.text)
                if !diff.isBinary && !diff.isTruncated {
                    do {
                        let versions = try await service.sourceVersions(for: selected, repository: request.repository,
                                                                        target: request.target)
                        try Task.checkCancellation()
                        before = versions.before
                        after = versions.after
                        presentation = GitDiffPresentation(before: before, after: after, patch: diff.text)
                        scroll.presentation = presentation
                        if !presentation.isConsistent {
                            sourceError = "Source snapshots do not match this patch. Refresh to retry; the patch is shown below."
                        }
                    } catch is CancellationError { return
                    } catch { sourceError = error.localizedDescription }
                }
                loading = false
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; loading = false }
        }
    }

    private func sourcePane(_ title: String, text: String, path: String, side: Int) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption).padding(6)
                .frame(maxWidth: .infinity)
                .background(title == "Before" ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            GitDiffLinkedEditor(text: text, path: path,
                                highlights: title == "Before" ? lineMap.before : lineMap.after,
                                isActive: isActive, theme: theme, link: scroll, side: side, actions: actions, close: close)
                .id("\(selected?.id ?? "")-\(title)")
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
