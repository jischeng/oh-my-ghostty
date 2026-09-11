import AppKit
import SwiftUI
import CodeEditSourceEditor

struct GitEditorDiffRequest: Identifiable {
    let id = UUID()
    let repository: GitRepositoryIdentity
    let target: GitDiffTarget
    let file: GitDiffFile?
    var tabTitle: String {
        let name = file.map { ($0.path as NSString).lastPathComponent } ?? GitL10n.text("Git Diff")
        return name + " · " + target.description
    }
}

struct GitDiffEditorActions {
    var openFile: (GitDiffFile, Bool) -> Void = { _, _ in }
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
    @AppStorage("git.diff.viewMode") private var mode = GitL10n.text("Side by Side")
    @State private var scroll = GitDiffScrollLink()
    @State private var linkedScrolling = true
    @State private var changeIndex = -1

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
            HStack(spacing: 4) {
                toolbarButton("chevron.left", help: GitL10n.text("Previous file"), disabled: selectedFileIndex <= 0) {
                    model.selectAdjacentFile(offset: -1)
                }
                toolbarButton("chevron.right", help: GitL10n.text("Next file"),
                              disabled: selectedFileIndex < 0 || selectedFileIndex >= model.files.count - 1) {
                    model.selectAdjacentFile(offset: 1)
                }
                Text(fileCounter)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                toolbarDivider
                toolbarButton("arrow.up", help: GitL10n.text("Previous change"), disabled: changeAnchors.isEmpty) {
                    selectChange(offset: -1)
                }
                toolbarButton("arrow.down", help: GitL10n.text("Next change"), disabled: changeAnchors.isEmpty) {
                    selectChange(offset: 1)
                }
                Spacer()
                Text(model.selected?.displayPath ?? GitL10n.text("Select file"))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.selected?.displayPath ?? request.repository.worktreePath)
                    .layoutPriority(1)
                Spacer()
                fileMenu
                viewMenu
                if mode == GitL10n.text("Side by Side") {
                    Button { linkedScrolling.toggle() } label: {
                        Image(systemName: linkedScrolling ? "link" : "link.slash")
                            .frame(width: 22, height: 20)
                            .foregroundStyle(linkedScrolling ? Color.accentColor : Color.secondary)
                            .background(linkedScrolling ? Color.accentColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(linkedScrolling ? GitL10n.text("Disable linked scrolling") : GitL10n.text("Enable linked scrolling"))
                    .accessibilityLabel(GitL10n.text("Linked scrolling"))
                    .accessibilityValue(GitL10n.text(linkedScrolling ? "On" : "Off"))
                }
                toolbarButton("pencil", help: GitL10n.text("Open in Editor"),
                              disabled: model.selected == nil || model.selected?.kind == .deleted) {
                    if let file = model.selected { actions.openFile(file, false) }
                }
                toolbarButton("arrow.clockwise", help: GitL10n.text("Refresh diff"), disabled: model.isLoading) {
                    model.reload()
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
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
                    if mode == GitL10n.text("Side by Side") {
                        HSplitView {
                            sourcePane(GitL10n.text("Before"), text: content.before, path: document.file.oldPath ?? document.file.path,
                                       highlights: presentation.beforeHighlights, side: 0)
                            sourcePane(GitL10n.text("After"), text: content.after, path: document.file.path,
                                       highlights: presentation.afterHighlights, side: 1)
                        }
                    } else {
                        GitDiffLinkedEditor(text: presentation.text, path: document.file.path,
                                            highlights: presentation.highlights, isActive: isActive,
                                            theme: theme, link: scroll, side: 2, actions: actions, close: close)
                            .id("inline-\(model.selected?.id ?? "")")
                    }
                }
            } else if !model.isLoading && model.error == nil {
                Text(GitL10n.text("No changed files")).foregroundStyle(.secondary).padding()
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
        .onChange(of: model.content?.presentation) {
            scroll.presentation = $0 ?? GitDiffPresentation(before: "", after: "", patch: "")
            changeIndex = -1
        }
    }

    private var selectedFileIndex: Int {
        guard let selected = model.selected else { return -1 }
        return model.files.firstIndex(of: selected) ?? -1
    }

    private var fileCounter: String {
        guard selectedFileIndex >= 0 else { return GitL10n.format("{0} files", String(model.files.count)) }
        return GitL10n.format("{0} / {1} files", String(selectedFileIndex + 1), String(model.files.count))
    }

    private var changeAnchors: [(before: Int?, after: Int?, inline: Int)] {
        model.content?.presentation?.changeAnchors ?? []
    }

    private func selectChange(offset: Int) {
        guard !changeAnchors.isEmpty else { return }
        if changeIndex < 0 {
            changeIndex = offset > 0 ? 0 : changeAnchors.count - 1
        } else {
            changeIndex = ((changeIndex + offset) % changeAnchors.count + changeAnchors.count) % changeAnchors.count
        }
        let anchor = changeAnchors[changeIndex]
        if mode == GitL10n.text("Side by Side") {
            var lines: [Int: Int] = [:]
            if let before = anchor.before { lines[0] = before }
            if let after = anchor.after { lines[1] = after }
            scroll.jump(to: lines)
        } else {
            scroll.jump(to: [2: anchor.inline])
        }
    }

    private func toolbarButton(_ image: String, help: String, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
        .disabled(disabled)
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 14).padding(.horizontal, 2)
    }

    private var fileMenu: some View {
        Menu {
            ForEach(model.files) { file in
                Button {
                    model.select(file)
                } label: {
                    if file == model.selected {
                        Label(file.displayPath, systemImage: "checkmark")
                    } else {
                        Text(file.displayPath)
                    }
                }
            }
            if let file = model.selected {
                Divider()
                Button(GitL10n.text("Open Folder in New Tab")) { actions.openFile(file, true) }
                Button(GitL10n.text("Copy Path")) {
                    if let path = try? GitFileActions.absolutePath(file, repository: request.repository) {
                        InspectorCopyMenu.copy(path, to: .general)
                    }
                }
                Button(GitL10n.text("Copy Relative Path")) { InspectorCopyMenu.copy(file.path, to: .general) }
            }
        } label: {
            Image(systemName: "list.bullet").frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(GitL10n.text("Select file"))
        .accessibilityLabel(GitL10n.text("Select file"))
        .disabled(model.files.isEmpty)
    }

    private var viewMenu: some View {
        Menu {
            Picker(GitL10n.text("View"), selection: $mode) {
                Label(GitL10n.text("Side by Side"), systemImage: "rectangle.split.2x1")
                    .tag(GitL10n.text("Side by Side"))
                Label(GitL10n.text("Inline"), systemImage: "text.alignleft")
                    .tag(GitL10n.text("Inline"))
            }
        } label: {
            Image(systemName: mode == GitL10n.text("Side by Side") ? "rectangle.split.2x1" : "text.alignleft")
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(GitL10n.text("View"))
        .accessibilityLabel(GitL10n.text("View"))
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
