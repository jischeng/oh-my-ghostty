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
    @Environment(\.gitCollectionColors) private var colors
    let request: GitEditorDiffRequest
    let theme: EditorTheme
    var isActive = true
    var actions = GitDiffEditorActions()
    let close: () -> Void
    @StateObject private var model: GitEditorDiffModel
    @AppStorage("git.diff.viewMode") private var mode = GitL10n.text("Side by Side")
    @State private var scroll = GitDiffScrollLink()
    @State private var linkedScrolling = true
    @State private var navigator = GitDiffReviewNavigator()
    @State private var pendingLanding: GitDiffReviewNavigator.Landing?
    @State private var navigationHint: String?
    @State private var hintTask: Task<Void, Never>?

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
                toolbarButton("chevron.left", help: GitL10n.text("Previous file"),
                              disabled: selectedFileIndex < 0 || model.files.count < 2) {
                    selectAdjacentFile(offset: -1)
                }
                toolbarButton("chevron.right", help: GitL10n.text("Next file"),
                              disabled: selectedFileIndex < 0 || model.files.count < 2) {
                    selectAdjacentFile(offset: 1)
                }
                Text(fileCounter)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                toolbarDivider
                toolbarButton("arrow.up", help: GitL10n.text("Previous change"), disabled: changeAnchors.isEmpty) {
                    selectChange(.previous)
                }
                toolbarButton("arrow.down", help: GitL10n.text("Next change"), disabled: changeAnchors.isEmpty) {
                    selectChange(.next)
                }
                Spacer()
                Text(model.selected?.displayPath ?? GitL10n.text("Select file"))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.selected?.displayPath ?? request.repository.worktreePath)
                    .layoutPriority(1)
                Spacer()
                if mode == GitL10n.text("Side by Side") {
                    toolbarButton("link",
                                  help: linkedScrolling ? GitL10n.text("Disable linked scrolling") : GitL10n.text("Enable linked scrolling"),
                                  selected: linkedScrolling,
                                  accessibilityValue: GitL10n.text(linkedScrolling ? "On" : "Off")) {
                        clearHint()
                        linkedScrolling.toggle()
                    }
                } else {
                    Color.clear.frame(width: 28, height: 24).accessibilityHidden(true)
                }
                fileMenu
                HStack(spacing: 0) {
                    toolbarButton("rectangle.split.2x1", help: GitL10n.text("Side-by-side Diff"),
                                  selected: mode == GitL10n.text("Side by Side"),
                                  accessibilityValue: mode == GitL10n.text("Side by Side") ? GitL10n.text("Selected") : "") {
                        clearHint()
                        mode = GitL10n.text("Side by Side")
                    }
                    toolbarButton("text.alignleft", help: GitL10n.text("Unified / Inline Diff"),
                                  selected: mode == GitL10n.text("Inline"),
                                  accessibilityValue: mode == GitL10n.text("Inline") ? GitL10n.text("Selected") : "") {
                        clearHint()
                        mode = GitL10n.text("Inline")
                    }
                }
                .padding(2)
                .background(Color(colors.text).opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(colors.text).opacity(0.18), lineWidth: 0.75))
                toolbarButton("pencil", help: GitL10n.text("Open in Editor"),
                              disabled: model.selected == nil || model.selected?.kind == .deleted) {
                    clearHint()
                    if let file = model.selected { actions.openFile(file, false) }
                }
                toolbarButton("arrow.clockwise", help: GitL10n.text("Refresh diff"), disabled: model.isLoading) {
                    clearHint()
                    model.reload()
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(toolbarSurface)
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
        .overlay(alignment: .top) {
            if let navigationHint {
                Text(navigationHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .padding(.top, 38)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .background(GitDiffFallbackCommands(
            isActive: isActive && (model.content?.presentation == nil || model.content?.sourceError != nil),
            actions: actions, close: close
        ))
        .onAppear { model.reload() }
        .onDisappear { model.cancel(); clearHint(); navigator.reset() }
        .onChange(of: linkedScrolling) { scroll.enabled = $0 }
        .onChange(of: model.content?.presentation) {
            scroll.presentation = $0 ?? GitDiffPresentation(before: "", after: "", patch: "")
            guard let presentation = $0 else { return }
            if let landing = pendingLanding {
                pendingLanding = nil
                if let index = navigator.land(landing, changeCount: presentation.changeAnchors.count) {
                    jump(to: presentation.changeAnchors[index], afterEditorReplacement: true)
                }
            } else {
                navigator.reset()
            }
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

    private var toolbarSurface: Color { Color.primary.opacity(0.025) }

    private func selectAdjacentFile(offset: Int) {
        pendingLanding = nil
        navigator.reset()
        clearHint()
        model.selectAdjacentFile(offset: offset)
    }

    private func selectChange(_ direction: GitDiffReviewNavigator.Direction) {
        guard let outcome = navigator.move(direction, changeCount: changeAnchors.count,
                                            fileCount: model.files.count) else { return }
        switch outcome {
        case .jump(let index):
            clearHint()
            jump(to: changeAnchors[index])
        case .hint(let hint):
            showHint(hint)
        case .openFile(let offset, let landing):
            clearHint()
            if model.files.count == 1 {
                if let index = navigator.land(landing, changeCount: changeAnchors.count) {
                    jump(to: changeAnchors[index])
                }
            } else {
                pendingLanding = landing
                model.selectAdjacentFile(offset: offset)
            }
        }
    }

    private func jump(to anchor: (before: Int?, after: Int?, inline: Int), afterEditorReplacement: Bool = false) {
        var lines: [Int: Int] = [:]
        if mode == GitL10n.text("Side by Side") {
            if let before = anchor.before { lines[0] = before }
            if let after = anchor.after { lines[1] = after }
        } else {
            lines[2] = anchor.inline
        }
        if afterEditorReplacement { scroll.queueJump(to: lines) } else { scroll.jump(to: lines) }
    }

    private func showHint(_ hint: GitDiffReviewNavigator.Hint) {
        let text = switch hint {
        case .previousFile: GitL10n.text("Reached the first change. Click again to open the previous file.")
        case .nextFile: GitL10n.text("Reached the last change. Click again to open the next file.")
        }
        navigationHint = text
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, navigationHint == text else { return }
            navigationHint = nil
            navigator.disarm()
        }
    }

    private func clearHint() {
        hintTask?.cancel()
        hintTask = nil
        navigationHint = nil
        navigator.disarm()
    }

    private func toolbarButton(_ image: String, help: String, disabled: Bool = false, selected: Bool = false,
                               accessibilityValue: String = "",
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(selected ? colors.accent : colors.secondary))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonStyle(GitToolbarButtonStyle(colors: colors, selected: selected))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(accessibilityValue)
        .disabled(disabled)
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 14).padding(.horizontal, 2)
    }

    private var fileMenu: some View {
        Menu {
            ForEach(model.files) { file in
                Button {
                    pendingLanding = nil
                    navigator.reset()
                    clearHint()
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
            GitToolbarMenuLabel(image: "list.bullet", colors: colors)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(GitToolbarButtonStyle(colors: colors, selected: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(GitL10n.text("Select file"))
        .accessibilityLabel(GitL10n.text("Select file"))
        .disabled(model.files.isEmpty)
    }

    private func sourcePane(_ title: String, text: String, path: String, highlights: [Int: Bool], side: Int) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(toolbarSurface)
                .overlay(alignment: .bottom) { Divider() }
            GitDiffLinkedEditor(text: text, path: path, highlights: highlights,
                                isActive: isActive, theme: theme, link: scroll, side: side, actions: actions, close: close)
                .id("\(model.selected?.id ?? "")-\(side)")
        }.frame(minWidth: 120)
    }
}

private struct GitToolbarMenuLabel: View {
    let image: String
    let colors: GitCollectionColors
    @State private var hovered = false

    var body: some View {
        Image(systemName: image)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(colors.secondary))
            .frame(width: 28, height: 24)
            .background(Color(colors.text).opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color(colors.text).opacity(hovered ? 0.22 : 0), lineWidth: 0.75))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
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
