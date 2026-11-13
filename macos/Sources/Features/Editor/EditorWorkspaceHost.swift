import AppKit
import SwiftUI
import CodeEditSourceEditor

private struct EditorTerminalControllerKey: EnvironmentKey {
    static let defaultValue: TerminalController? = nil
}

extension EnvironmentValues {
    var editorTerminalController: TerminalController? {
        get { self[EditorTerminalControllerKey.self] }
        set { self[EditorTerminalControllerKey.self] = newValue }
    }
}

struct EditorPaneContainer<Terminal: View>: View {
    @Environment(\.editorTerminalController) private var controller
    let surfaceView: Ghostty.SurfaceView
    @ViewBuilder var terminal: () -> Terminal

    var body: some View {
        if let controller {
            EditorWorkspaceHost(controller: controller, surfaceView: surfaceView, terminal: terminal)
        } else {
            terminal()
        }
    }
}

/// The editor occupies one existing split leaf; its terminal remains alive underneath.
struct EditorWorkspaceHost<Terminal: View>: View {
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @ObservedObject var controller: TerminalController
    @ObservedObject private var workspace: EditorWorkspace
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    private let terminal: Terminal

    init(controller: TerminalController, surfaceView: Ghostty.SurfaceView, @ViewBuilder terminal: () -> Terminal) {
        self.controller = controller
        self.surfaceView = surfaceView
        self.workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: surfaceView.id)
        self.terminal = terminal()
    }

    private var isChinese: Bool {
        SettingsStrings(language: settings.language).isChinese
    }

    private var selectedMarkdownDocument: EditorDocument? {
        guard workspace.gitDiff == nil,
              let selectedID = workspace.selectedID,
              let document = workspace.documents.first(where: { $0.id == selectedID }),
              document.isMarkdown else { return nil }
        return document
    }

    var body: some View {
        NativeEditorContentDeck(items: [
            .init(id: .terminal, content: AnyView(VStack(spacing: 0) {
                if surfaceView.runtimeDescriptor == nil {
                    SSHRecoveryBanner(controller: controller, surface: surfaceView)
                }
                terminal
            }.overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    if !workspace.isVisible, !workspace.documents.isEmpty || !workspace.gitDiffs.isEmpty {
                        EditorCollapsedPill(workspace: workspace, isChinese: isChinese) {
                            if controller.focusedSurface !== surfaceView {
                                controller.focusedSurface = surfaceView
                            }
                            workspace.isVisible = true
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                    SessionRuntimeRecoveryBanner(controller: controller, surface: surfaceView)
                }
            })),
            .init(id: .workspace, content: AnyView(editor
                .simultaneousGesture(TapGesture().onEnded {
                    if controller.focusedSurface !== surfaceView {
                        controller.focusedSurface = surfaceView
                    }
                })))
        ], selectedID: workspace.isVisible ? .workspace : .terminal) { selected in
            if selected == .terminal, controller.focusedSurface === surfaceView,
               surfaceView.window?.isKeyWindow == true {
                Ghostty.moveFocus(to: surfaceView)
            }
        }
        .onChange(of: workspace.isVisible) { visible in
            if visible {
                if controller.focusedSurface !== surfaceView {
                    controller.focusedSurface = surfaceView
                }
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents, id: \.id) { document in
                                EditorDocumentTab(
                                    document: document,
                                    isSelected: workspace.gitDiff == nil && workspace.selectedID == document.id,
                                    select: {
                                        workspace.gitDiff = nil
                                        workspace.selectedID = document.id
                                    },
                                    close: { close(document) }
                                )
                                .id(document.id)
                            }
                            ForEach(workspace.gitDiffs) { request in
                                HStack(spacing: 6) {
                                    Button { workspace.selectGitDiff(request) } label: {
                                        Label(request.tabTitle, systemImage: "arrow.left.arrow.right")
                                            .lineLimit(1)
                                    }
                                    Button { workspace.closeGitDiff(request) } label: {
                                        Image(systemName: "xmark").font(.caption2)
                                    }.help(GitL10n.text("Close Diff"))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(workspace.gitDiff?.id == request.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .help(request.repository.worktreePath + " — " + request.tabTitle)
                                .id(request.id)
                            }
                        }
                    }
                    .onChange(of: workspace.gitDiff?.id) { selected in
                        if let selected { proxy.scrollTo(selected) }
                    }
                    .onChange(of: workspace.selectedID) { selected in
                        if let selected { proxy.scrollTo(selected) }
                    }
                }
                HStack(spacing: 4) {
                    if let markdownDocument = selectedMarkdownDocument {
                        EditorMarkdownModeSwitch(document: markdownDocument, isChinese: isChinese)
                            .padding(.trailing, 2)
                    }
                    EditorToolbarIconButton(
                        tooltip: isChinese ? "打开文件… (⌘O)" : "Open File… (⌘O)",
                        accessibilityLabel: "Open File",
                        icon: EditorOpenFileIcon(),
                        action: openFile
                    )
                    EditorToolbarIconButton(
                        tooltip: isChinese ? "收起编辑器 (⇧⎋)" : "Collapse Editor (⇧⎋)",
                        accessibilityLabel: "Hide Editor",
                        icon: EditorCodexCollapseIcon(),
                        action: { workspace.isVisible = false }
                    )
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            if let error = workspace.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { workspace.errorMessage = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
            }
            if workspace.isLoading {
                ProgressView("Opening file…").padding(8)
            }
            NativeEditorContentDeck(items: documentItems, selectedID: selectedContentID)
        }
        .background(EditorBackdrop(color: appearanceTheme.background, opacity: appearanceOpacity, blur: appearanceBlur,
                                   usesWindowBlur: settings.editorSettings.followsOMG,
                                   windowChromeFill: followsOMGBackdropFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code Editor")
    }

    private var selectedContentID: EditorContentKey {
        if let request = workspace.gitDiff { return .diff(request.id) }
        if let id = workspace.selectedID { return .document(id) }
        return .empty
    }

    private var documentItems: [EditorContentItem] {
        var items = workspace.documents.map { document in
            let selected = workspace.gitDiff == nil && workspace.selectedID == document.id
            return EditorContentItem(id: .document(document.id), content: AnyView(
                EditorDocumentView(
                    document: document,
                    isActive: selected && workspace.isVisible,
                    isSurfaceFocused: {
                        (controller.focusedSurface ?? controller.surfaceTree.first) === surfaceView
                    },
                    terminalBackground: appearanceTheme.background,
                    terminalBackgroundOpacity: appearanceOpacity,
                    terminalTheme: appearanceTheme,
                    onFocus: {
                        if controller.focusedSurface !== surfaceView {
                            controller.focusedSurface = surfaceView
                        }
                    },
                    save: { Task { await workspace.save(document) } },
                    close: { close(document) },
                    open: openFile,
                    nextDocument: { workspace.selectAdjacentDocument(offset: 1) },
                    previousDocument: { workspace.selectAdjacentDocument(offset: -1) },
                    saveAll: { Task { await workspace.saveAll() } },
                    onHide: { workspace.isVisible = false },
                    openLink: { href in openMarkdownLink(href, document: document) }
                )
            ))
        }
        items += workspace.gitDiffs.map { request in
            let selected = workspace.gitDiff?.id == request.id
            return EditorContentItem(id: .diff(request.id), content: AnyView(
                GitEditorDiffView(request: request, theme: appearanceTheme, isActive: selected && workspace.isVisible,
                    actions: GitDiffEditorActions(
                        openFile: { file, directory in openGitFile(file, repository: request.repository, directory: directory) },
                        selectFile: { file in workspace.updateGitDiffFile(file, for: request.id) },
                        hide: { workspace.isVisible = false },
                        open: openFile,
                        nextDocument: { workspace.selectAdjacentDocument(offset: 1) },
                        previousDocument: { workspace.selectAdjacentDocument(offset: -1) },
                        saveAll: { Task { await workspace.saveAll() } },
                        focus: { controller.focusedSurface = surfaceView },
                        isSurfaceFocused: { (controller.focusedSurface ?? controller.surfaceTree.first) === surfaceView }
                    )) {
                    workspace.closeGitDiff(request)
                }
            ))
        }
        if workspace.documents.isEmpty && workspace.gitDiffs.isEmpty {
            items.append(.init(id: .empty, content: AnyView(VStack(spacing: 12) {
                Image(systemName: "doc.text").font(.largeTitle)
                Text("Open a file from Files or choose Open File.")
                Button("Open File", action: openFile)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity))))
        }
        return items
    }

    private func openGitFile(_ file: GitDiffFile, repository: GitRepositoryIdentity, directory: Bool) {
        guard let session = controller.paneSessionContext(for: surfaceView) else { return }
        let context = InspectorPaneContext(tabID: controller.tabSessionID, surfaceID: surfaceView.id,
            title: session.presentationTitle, workingDirectory: repository.worktreePath,
            workspace: session.workspace, session: session)
        do { try GitFileActions.open(file, repository: repository, context: context, directory: directory) } catch { workspace.errorMessage = error.localizedDescription }
    }

    private func close(_ document: EditorDocument) {
        Task { await workspace.close(document, window: controller.window) }
    }

    private var appearanceTheme: EditorTheme {
        if settings.editorSettings.followsOMG {
            return controller.ghostty.config.editorTheme(background: NSColor(terminalColor))
        }
        if let name = settings.editorThemeName, let theme = EditorCatalogThemes.shared.theme(named: name) {
            return theme
        }
        return settings.editorSyntaxTheme.preset
    }

    private var appearanceOpacity: Double {
        settings.editorSettings.followsOMG ? terminalOpacity : settings.editorOpacity
    }

    private var appearanceBlur: OhMyGhosttyBackgroundBlur {
        guard settings.editorSettings.followsOMG else { return settings.editorBlur }
        return controller.ghostty.config.editorBackgroundBlur
    }

    private var followsOMGBackdropFill: NSColor? {
        guard settings.editorSettings.followsOMG else { return nil }
        let windowIsOpaque = controller.window?.styleMask.contains(.fullScreen) == true || controller.isBackgroundOpaque
        return NSColor(OMGThemeBackground.matchingChrome(
            color: terminalColor,
            opacity: terminalOpacity,
            windowIsOpaque: windowIsOpaque,
            colorspaceIsDisplayP3: controller.ghostty.config.windowColorspaceIsDisplayP3,
            linearBlending: controller.ghostty.config.usesLinearAlphaBlending,
            usesWindowGlass: surfaceView.derivedConfig.backgroundBlur.isGlassStyle
        ))
    }

    private var terminalColor: Color {
        if let bg = surfaceView.backgroundColor {
            return bg
        }
        let configBg = surfaceView.derivedConfig.backgroundColor
        if configBg != Color(NSColor.windowBackgroundColor) {
            return configBg
        }
        if controller.terminalBackgroundColor != Color(NSColor.windowBackgroundColor) {
            return controller.terminalBackgroundColor
        }
        return configBg
    }

    private var terminalOpacity: Double {
        let opacity = surfaceView.derivedConfig.backgroundOpacity
        if opacity < 1.0 { return opacity }
        if controller.terminalBackgroundOpacity < 1.0 { return controller.terminalBackgroundOpacity }
        return opacity
    }

    private func openFile() {
        EditorMenuController.shared.openFile(in: controller, surface: surfaceView)
    }

    private func openMarkdownLink(_ href: String, document: EditorDocument) {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:"),
           let url = URL(string: trimmed) {
            NSWorkspace.shared.open(url)
            return
        }
        let docDir = (document.path as NSString).deletingLastPathComponent
        let candidate: String
        if !lower.hasPrefix("file:"), !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), docDir.hasPrefix("/") {
            candidate = docDir == "/" ? "/" + trimmed : docDir + "/" + trimmed
        } else {
            candidate = trimmed
        }
        _ = TerminalPathOpener.open(candidate, from: surfaceView, baseDirectory: docDir)
    }
}

private struct EditorDocumentTab: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if document.isDirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                    Text((document.path as NSString).lastPathComponent)
                        .lineLimit(1)
                }
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isCloseHovered ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background(isCloseHovered ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .onHover { isCloseHovered = $0 }
            .help("Close File")
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (isHovered ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovered = $0 }
        .help(document.filesystem.descriptor.presentationTitle + " — " + document.path)
    }
}

private struct EditorMarkdownModeSwitch: View {
    @ObservedObject var document: EditorDocument
    let isChinese: Bool

    var body: some View {
        Picker("", selection: $document.isPreviewMode) {
            Text("Edit").tag(false)
            Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 120)
        .help(isChinese ? "切换源码编辑 / Markdown 预览" : "Switch between Source Edit and Markdown Preview")
    }
}

private struct EditorToolbarIconButton<Icon: View>: View {
    let tooltip: String
    let accessibilityLabel: String
    let icon: Icon
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 16, height: 16)
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    isHovered ? Color.primary.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isHovered ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct EditorOpenFileIcon: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 16.0
            let scaleY = size.height / 16.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y * scaleY)
            }
            let stroke = StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)

            var doc = Path()
            doc.move(to: pt(9.4, 2.1))
            doc.addLine(to: pt(4.6, 2.1))
            doc.addQuadCurve(to: pt(3.4, 3.3), control: pt(3.4, 2.1))
            doc.addLine(to: pt(3.4, 12.7))
            doc.addQuadCurve(to: pt(4.6, 13.9), control: pt(3.4, 13.9))
            doc.addLine(to: pt(11.4, 13.9))
            doc.addQuadCurve(to: pt(12.6, 12.7), control: pt(12.6, 13.9))
            doc.addLine(to: pt(12.6, 5.3))
            doc.closeSubpath()
            context.stroke(doc, with: .foreground, style: stroke)

            var fold = Path()
            fold.move(to: pt(9.2, 2.2))
            fold.addLine(to: pt(9.2, 5.4))
            fold.addLine(to: pt(12.4, 5.4))
            context.stroke(fold, with: .foreground, style: stroke)

            var arrow = Path()
            arrow.move(to: pt(8.0, 11.4))
            arrow.addLine(to: pt(8.0, 7.3))
            arrow.move(to: pt(6.3, 8.9))
            arrow.addLine(to: pt(8.0, 7.2))
            arrow.addLine(to: pt(9.7, 8.9))
            context.stroke(arrow, with: .foreground, style: stroke)
        }
    }
}

/// Codex-style inward corner brackets indicating collapse.
private struct EditorCodexCollapseIcon: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 16.0
            let scaleY = size.height / 16.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y * scaleY)
            }
            var path = Path()
            // Bottom-left inward corner (┐)
            path.move(to: pt(3.5, 9.5))
            path.addLine(to: pt(6.5, 9.5))
            path.addLine(to: pt(6.5, 12.5))
            // Top-right inward corner (└)
            path.move(to: pt(9.5, 3.5))
            path.addLine(to: pt(9.5, 6.5))
            path.addLine(to: pt(12.5, 6.5))
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// Codex-style outward corner brackets indicating expand.
private struct EditorCodexExpandIcon: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 16.0
            let scaleY = size.height / 16.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y * scaleY)
            }
            var path = Path()
            // Bottom-left outward corner (└)
            path.move(to: pt(4.0, 8.5))
            path.addLine(to: pt(4.0, 12.0))
            path.addLine(to: pt(7.5, 12.0))
            // Top-right outward corner (┐)
            path.move(to: pt(12.0, 7.5))
            path.addLine(to: pt(12.0, 4.0))
            path.addLine(to: pt(8.5, 4.0))
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

private struct EditorCollapsedPill: View {
    @ObservedObject var workspace: EditorWorkspace
    let isChinese: Bool
    let expand: () -> Void
    @State private var isHovered = false

    private var activeDocument: EditorDocument? {
        guard workspace.gitDiff == nil else { return nil }
        if let selectedID = workspace.selectedID,
           let selected = workspace.documents.first(where: { $0.id == selectedID }) {
            return selected
        }
        return workspace.documents.first
    }

    private var activeTitle: String {
        if let diff = workspace.gitDiff {
            return diff.tabTitle
        }
        if let doc = activeDocument {
            return (doc.path as NSString).lastPathComponent
        }
        if let firstDiff = workspace.gitDiffs.first {
            return firstDiff.tabTitle
        }
        return "Editor"
    }

    private var totalItemCount: Int {
        workspace.documents.count + workspace.gitDiffs.count
    }

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 7) {
                if let doc = activeDocument {
                    EditorCollapsedStatusDot(document: doc)
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Text(activeTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.88))

                if totalItemCount > 1 {
                    Text("\(totalItemCount)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.10), in: Capsule())
                }

                EditorCodexExpandIcon()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .background(
                (isHovered ? Color.accentColor.opacity(0.10) : Color.black.opacity(0.14)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.16),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isChinese ? "展开编辑器" : "Expand Editor")
        .accessibilityLabel("Editor")
    }
}

private struct EditorCollapsedStatusDot: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        Circle()
            .fill(document.isDirty ? Color.orange : Color.accentColor)
            .frame(width: 6, height: 6)
    }
}

private struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    var isSurfaceFocused: () -> Bool = { true }
    let terminalBackground: NSColor
    let terminalBackgroundOpacity: Double
    let terminalTheme: EditorTheme
    let onFocus: () -> Void
    let save: () -> Void
    let close: () -> Void
    let open: () -> Void
    let nextDocument: () -> Void
    let previousDocument: () -> Void
    let saveAll: () -> Void
    let onHide: () -> Void
    var openLink: (String) -> Void = { _ in }

    private var showsMarkdownPreview: Bool {
        document.isMarkdown && document.isPreviewMode
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = document.saveErrorMessage {
                HStack(alignment: .top) {
                    Label("Couldn’t save: " + error, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry Save", action: save)
                        .disabled(document.isSaving || document.isReloading)
                }
                .font(.callout)
                .padding(10)
                .background(Color.red.opacity(0.1))
            }
            ZStack(alignment: .topLeading) {
                CodeEditorView(
                    text: $document.text,
                    fileURL: URL(fileURLWithPath: document.path),
                    isEditable: !document.isRestoringFromGit,
                    isActive: isActive,
                    isPreview: showsMarkdownPreview,
                    isSurfaceFocused: isSurfaceFocused,
                    terminalBackground: terminalBackground,
                    terminalBackgroundOpacity: terminalBackgroundOpacity,
                    terminalForeground: terminalTheme.text.color,
                    terminalTheme: terminalTheme,
                    wordWrapOverride: document.isMarkdown ? true : nil,
                    onFocus: onFocus,
                    onSave: save,
                    onClose: close,
                    onOpen: open,
                    onNextDocument: nextDocument,
                    onPreviousDocument: previousDocument,
                    onSaveAll: saveAll,
                    onHide: onHide,
                    navigationRequest: document.pendingNavigation,
                    onConsumeNavigation: { document.consumeNavigation($0) }
                )
                .id(document.contentGeneration)
                .opacity(showsMarkdownPreview ? 0 : 1)
                .allowsHitTesting(!showsMarkdownPreview)

                if showsMarkdownPreview {
                    MarkdownPreviewView(
                        text: $document.text,
                        fileURL: URL(fileURLWithPath: document.path),
                        isRemote: document.filesystem.descriptor.kind == .ssh,
                        filesystem: document.filesystem,
                        terminalBackground: terminalBackground,
                        foregroundColor: terminalTheme.text.color,
                        isActive: isActive,
                        onFocus: onFocus,
                        onSave: save,
                        onSaveAll: saveAll,
                        onHide: onHide,
                        onOpenLink: openLink
                    )
                    .id(document.contentGeneration)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text(document.path).lineLimit(1).truncationMode(.middle)
                    .help(document.path)
                if document.filesystem.descriptor.kind == .ssh {
                    Label(document.filesystem.descriptor.displayName, systemImage: "network")
                }
                Spacer(minLength: 8)

                if document.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if document.isDirty {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onAppear {
            if document.pendingNavigation != nil && document.isPreviewMode {
                document.isPreviewMode = false
            }
        }
        .onChange(of: document.pendingNavigation) { navigation in
            if navigation != nil && document.isPreviewMode {
                document.isPreviewMode = false
            }
        }
        .onChange(of: isActive) { active in
            if !active {
                document.flushAutoSave()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            document.flushAutoSave()
        }
    }
}

/// Uses the same glass implementation as the terminal. A single backdrop avoids
/// multiplying opacity between the gutter, scroll view and surrounding controls.
struct EditorBackdrop: NSViewRepresentable {
    @Environment(\.controlActiveState) private var activeState
    let color: NSColor
    let opacity: Double
    let blur: OhMyGhosttyBackgroundBlur
    var usesWindowBlur = false
    var windowChromeFill: NSColor?

    var localEffect: OhMyGhosttyBackgroundBlur {
        // When following OMG, both ordinary Ghostty blur and macOS liquid glass
        // are already applied at the window level. Never stack a second
        // NSVisualEffectView or TerminalGlassView inside a split pane.
        usesWindowBlur ? .disabled : blur
    }

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ view: BackdropView, context: Context) {
        let blur = localEffect
        if context.coordinator.blur != blur {
            view.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.blur = blur
            let effect: NSView?
#if compiler(>=6.2)
            if #available(macOS 26.0, *), blur == .macosGlassRegular || blur == .macosGlassClear {
                effect = TerminalGlassView(topOffset: 0)
            } else {
                effect = blur == .disabled ? nil : NSVisualEffectView()
            }
#else
            effect = blur == .disabled ? nil : NSVisualEffectView()
#endif
            if let effect {
                effect.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(effect)
                NSLayoutConstraint.activate([
                    effect.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    effect.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    effect.topAnchor.constraint(equalTo: view.topAnchor),
                    effect.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
            }
        }
        if let windowChromeFill, blur == .disabled {
            view.fillColor = windowChromeFill
        } else {
            view.fillColor = blur == .disabled ? color.withAlphaComponent(opacity) : .clear
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view.subviews.first as? TerminalGlassView {
            glass.configure(style: blur == .macosGlassClear ? .clear : .regular,
                            backgroundColor: color, backgroundOpacity: opacity, cornerRadius: 0,
                            isKeyWindow: activeState != .inactive)
        }
#endif
        if let effect = view.subviews.first as? NSVisualEffectView {
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.wantsLayer = true
            effect.layer?.backgroundColor = color.withAlphaComponent(opacity).cgColor
        }
    }

    final class BackdropView: NSView {
        // AppKit can invalidate beyond an un-clipped view's bounds. Painting
        // dirtyRect into a shared backing store tinted neighbouring terminal
        // panes after split resizing/reordering. Own and clip the background.
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            clipsToBounds = true
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var fillColor: NSColor = .clear {
            didSet { layer?.backgroundColor = fillColor.cgColor }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var blur: OhMyGhosttyBackgroundBlur?
    }
}
