import AppKit
import SwiftUI

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
                        .fixedSize()
                        .padding(.top, 6)
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
        .onAppear {
            workspace.scheduleIdlePreload()
        }
        .onChange(of: workspace.isVisible) { visible in
            if visible {
                if controller.focusedSurface !== surfaceView {
                    controller.focusedSurface = surfaceView
                }
            }
        }
    }

    private var duplicateBasenames: Set<String> {
        var counts: [String: Int] = [:]
        for doc in workspace.documents {
            counts[(doc.path as NSString).lastPathComponent, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private func closeOthers(keeping kept: EditorDocument) {
        let others = workspace.documents.filter { $0.id != kept.id }
        Task {
            for doc in others {
                await workspace.close(doc, window: controller.window)
            }
        }
    }

    private var editor: some View {
        let duplicates = duplicateBasenames
        let docList = workspace.documents
        let diffList = workspace.gitDiffs
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(docList.enumerated()), id: \.element.id) { index, document in
                                let isSelected = workspace.gitDiff == nil && workspace.selectedID == document.id
                                let nextSelected: Bool = {
                                    if index + 1 < docList.count {
                                        return workspace.gitDiff == nil && workspace.selectedID == docList[index + 1].id
                                    }
                                    if let firstDiff = diffList.first {
                                        return workspace.gitDiff?.id == firstDiff.id
                                    }
                                    return true
                                }()
                                EditorDocumentTab(
                                    document: document,
                                    isSelected: isSelected,
                                    showsParentHint: duplicates.contains((document.path as NSString).lastPathComponent),
                                    showsTrailingSeparator: !isSelected && !nextSelected,
                                    isChinese: isChinese,
                                    actions: .init(
                                        select: {
                                            workspace.gitDiff = nil
                                            workspace.selectedID = document.id
                                        },
                                        close: { close(document) },
                                        closeOthers: docList.count > 1 ? { closeOthers(keeping: document) } : nil
                                    )
                                )
                                .id(document.id)
                            }
                            ForEach(Array(diffList.enumerated()), id: \.element.id) { index, request in
                                let isSelected = workspace.gitDiff?.id == request.id
                                let nextSelected = index + 1 < diffList.count
                                    ? workspace.gitDiff?.id == diffList[index + 1].id
                                    : true
                                EditorGitDiffTab(
                                    request: request,
                                    isSelected: isSelected,
                                    showsTrailingSeparator: !isSelected && !nextSelected,
                                    select: { workspace.selectGitDiff(request) },
                                    close: { workspace.closeGitDiff(request) }
                                )
                                .id(request.id)
                            }
                        }
                        .padding(.vertical, 1)
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
                        tooltip: isChinese ? "打开文件…" : "Open File…",
                        shortcut: "⌘O",
                        accessibilityLabel: "Open File",
                        icon: EditorOpenFileIcon(),
                        action: openFile
                    )
                    EditorToolbarIconButton(
                        tooltip: isChinese ? "收起编辑器" : "Collapse Editor",
                        shortcut: "⇧⎋",
                        accessibilityLabel: "Hide Editor",
                        icon: EditorCodexCollapseIcon(),
                        action: { workspace.isVisible = false }
                    )
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.02))
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
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
        if workspace.selectedDocument != nil { return .workbench }
        return .empty
    }

    private var documentItems: [EditorContentItem] {
        var items: [EditorContentItem] = []
        if !workspace.documents.isEmpty {
            items.append(EditorContentItem(id: .workbench, content: AnyView(
                EditorSharedWorkbenchPane(
                    workspace: workspace,
                    isSurfaceFocused: {
                        (controller.focusedSurface ?? controller.surfaceTree.first) === surfaceView
                    },
                    terminalBackground: appearanceTheme.background,
                    terminalTheme: appearanceTheme,
                    onFocus: {
                        if controller.focusedSurface !== surfaceView {
                            controller.focusedSurface = surfaceView
                        }
                    },
                    open: openFile,
                    close: { doc in close(doc) },
                    onHide: { workspace.isVisible = false },
                    onAskAgent: { request in sendAskAgentToQuickInput(request) },
                    onNavigateDefinition: { path, location in navigateToDefinition(path: path, location: location) },
                    openMarkdownLink: { href, document in openMarkdownLink(href, document: document) }
                )
            )))
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

    private func sendAskAgentToQuickInput(_ request: EditorAskAgentRequest) {
        let workingDirectory = controller.paneSessionContext(for: surfaceView)?.workingDirectory ?? surfaceView.pwd
        EditorQuickInputBridge.send(
            request,
            workingDirectory: workingDirectory,
            to: controller,
            surface: surfaceView
        )
    }

    private func navigateToDefinition(path: String, location: EditorTextLocation) {
        let filesystem: any WorkspaceFilesystem
        if let selectedFilesystem = workspace.selectedDocument?.filesystem {
            filesystem = selectedFilesystem
        } else {
            let session = controller.paneSessionContext(for: surfaceView) ?? .init(
                workingDirectory: surfaceView.pwd,
                terminalTitle: surfaceView.title
            )
            let context = InspectorPaneContext(
                tabID: controller.tabSessionID,
                surfaceID: surfaceView.id,
                title: session.presentationTitle,
                workingDirectory: session.workingDirectory,
                workspace: session.workspace,
                session: session
            )
            filesystem = WorkspaceFilesystemFactory.make(for: context)
        }
        workspace.open(path: path, filesystem: filesystem, location: location, externalFallback: false)
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
        let localHref = lower.hasPrefix("file:") ? trimmed : (trimmed.removingPercentEncoding ?? trimmed)
        let candidate: String
        if !lower.hasPrefix("file:"), !localHref.hasPrefix("/"), !localHref.hasPrefix("~"), docDir.hasPrefix("/") {
            candidate = docDir == "/" ? "/" + localHref : docDir + "/" + localHref
        } else {
            candidate = localHref
        }
        _ = TerminalPathOpener.open(candidate, from: surfaceView, baseDirectory: docDir)
    }
}

private struct EditorDocumentTab: View {
    struct Actions {
        let select: () -> Void
        let close: () -> Void
        let closeOthers: (() -> Void)?
    }

    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let showsParentHint: Bool
    let showsTrailingSeparator: Bool
    let isChinese: Bool
    let actions: Actions
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var anchorBox = EditorAnchorBox()

    private var filename: String {
        (document.path as NSString).lastPathComponent
    }

    private var parentFolder: String {
        ((document.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    private var tooltipText: String {
        let hostTitle = document.filesystem.descriptor.presentationTitle
        if hostTitle == "Local" || hostTitle.isEmpty {
            return document.path
        }
        return "\(hostTitle) — \(document.path)"
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: {
                    EditorHoverTooltipPresenter.shared.hide()
                    actions.select()
                }, label: {
                    HStack(spacing: 5.5) {
                        EditorFileIconView(filename: filename)
                            .opacity(isSelected || isHovered ? 1.0 : 0.82)
                        Text(filename)
                            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? Color.primary
                                    : (isHovered ? Color.primary.opacity(0.92) : Color.secondary)
                            )
                            .lineLimit(1)
                        if showsParentHint, !parentFolder.isEmpty, parentFolder != "/" {
                            Text(parentFolder)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)

                ZStack {
                    if document.isDirty && !isHovered && !isCloseHovered {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6.5, height: 6.5)
                    } else {
                        Button(action: {
                            EditorHoverTooltipPresenter.shared.hide()
                            actions.close()
                        }, label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(isCloseHovered ? Color.primary : Color.secondary)
                                .frame(width: 16, height: 16)
                                .background(
                                    isCloseHovered ? Color.primary.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        })
                        .buttonStyle(.plain)
                        .opacity(isCloseHovered ? 1.0 : (isHovered ? 0.82 : (isSelected ? 0.45 : 0.0)))
                        .allowsHitTesting(isSelected || isHovered || isCloseHovered)
                    }
                }
                .frame(width: 16, height: 16)
                .onHover { isCloseHovered = $0 }
            }
            .padding(.leading, 8.5)
            .padding(.trailing, 5.5)
            .padding(.vertical, 4.5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.075)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.11) : Color.clear,
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
            .background(EditorAnchorReader(box: anchorBox))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    EditorHoverTooltipPresenter.shared.schedule(
                        text: tooltipText,
                        shortcut: nil,
                        anchor: anchorBox,
                        delayMs: 420
                    )
                } else {
                    EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
                }
            }
            .onDisappear {
                EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
            }
            .contextMenu {
                Button(isChinese ? "关闭标签页" : "Close Tab") { actions.close() }
                if let closeOthers = actions.closeOthers {
                    Button(isChinese ? "关闭其他标签页" : "Close Other Tabs") { closeOthers() }
                }
                Divider()
                Button(isChinese ? "复制文件路径" : "Copy File Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.path, forType: .string)
                }
            }

            Rectangle()
                .fill(showsTrailingSeparator && !isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .frame(width: 1, height: 13)
                .padding(.leading, 2)
        }
        .accessibilityLabel(filename)
    }
}

private struct EditorGitDiffTab: View {
    let request: GitEditorDiffRequest
    let isSelected: Bool
    let showsTrailingSeparator: Bool
    let select: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var anchorBox = EditorAnchorBox()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: {
                    EditorHoverTooltipPresenter.shared.hide()
                    select()
                }, label: {
                    HStack(spacing: 5.5) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(request.tabTitle)
                            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? Color.primary
                                    : (isHovered ? Color.primary.opacity(0.92) : Color.secondary)
                            )
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)

                Button(action: {
                    EditorHoverTooltipPresenter.shared.hide()
                    close()
                }, label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(isCloseHovered ? Color.primary : Color.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            isCloseHovered ? Color.primary.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                })
                .buttonStyle(.plain)
                .opacity(isCloseHovered ? 1.0 : (isHovered ? 0.82 : (isSelected ? 0.45 : 0.0)))
                .allowsHitTesting(isSelected || isHovered || isCloseHovered)
                .onHover { isCloseHovered = $0 }
            }
            .padding(.leading, 8.5)
            .padding(.trailing, 5.5)
            .padding(.vertical, 4.5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.075)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.11) : Color.clear,
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
            .background(EditorAnchorReader(box: anchorBox))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    EditorHoverTooltipPresenter.shared.schedule(
                        text: request.repository.worktreePath + " — " + request.tabTitle,
                        shortcut: nil,
                        anchor: anchorBox,
                        delayMs: 420
                    )
                } else {
                    EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
                }
            }
            .onDisappear {
                EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
            }

            Rectangle()
                .fill(showsTrailingSeparator && !isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .frame(width: 1, height: 13)
                .padding(.leading, 2)
        }
    }
}

private struct EditorFileIconView: View {
    let filename: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let asset = MaterialFileIcons.assetName(
            for: filename,
            isDirectory: false,
            isLight: colorScheme == .light
        ), NSImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct EditorMarkdownModeSwitch: View {
    @ObservedObject var document: EditorDocument
    let isChinese: Bool
    @State private var anchorBox = EditorAnchorBox()

    var body: some View {
        Picker("", selection: $document.isPreviewMode) {
            Text("Edit").tag(false)
            Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 116)
        .background(EditorAnchorReader(box: anchorBox))
        .onHover { hovering in
            if hovering {
                EditorHoverTooltipPresenter.shared.schedule(
                    text: isChinese ? "切换源码编辑 / 预览" : "Switch Edit / Preview",
                    shortcut: nil,
                    anchor: anchorBox,
                    delayMs: 320
                )
            } else {
                EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
            }
        }
        .onDisappear {
            EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
        }
    }
}

private struct EditorToolbarIconButton<Icon: View>: View {
    let tooltip: String
    var shortcut: String?
    let accessibilityLabel: String
    let icon: Icon
    let action: () -> Void
    @State private var isHovered = false
    @State private var anchorBox = EditorAnchorBox()

    var body: some View {
        Button(action: {
            EditorHoverTooltipPresenter.shared.hide()
            action()
        }, label: {
            icon
                .frame(width: 16, height: 16)
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    isHovered ? Color.primary.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isHovered ? Color.primary.opacity(0.13) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        })
        .buttonStyle(.plain)
        .background(EditorAnchorReader(box: anchorBox))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                EditorHoverTooltipPresenter.shared.schedule(
                    text: tooltip,
                    shortcut: shortcut,
                    anchor: anchorBox,
                    delayMs: 120
                )
            } else {
                EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
            }
        }
        .onDisappear {
            EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
        }
        .help(shortcut.map { "\(tooltip) (\($0))" } ?? tooltip)
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
            path.move(to: pt(3.5, 9.5))
            path.addLine(to: pt(6.5, 9.5))
            path.addLine(to: pt(6.5, 12.5))
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
            path.move(to: pt(4.0, 8.5))
            path.addLine(to: pt(4.0, 12.0))
            path.addLine(to: pt(7.5, 12.0))
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
    @State private var anchorBox = EditorAnchorBox()

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

    private var hasDirtyDocument: Bool {
        workspace.documents.contains(where: \.isDirty)
    }

    private var hoverTooltipText: String {
        let prefix = isChinese ? "展开编辑器" : "Expand Editor"
        if totalItemCount > 1 {
            return isChinese
                ? "\(prefix) · \(activeTitle) (共 \(totalItemCount) 个)"
                : "\(prefix) · \(activeTitle) (\(totalItemCount) open)"
        }
        return "\(prefix) · \(activeTitle)"
    }

    var body: some View {
        Button(action: {
            EditorHoverTooltipPresenter.shared.hide()
            expand()
        }, label: {
            ZStack(alignment: .topTrailing) {
                EditorCodexExpandIcon()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .frame(width: 28, height: 28)

                if hasDirtyDocument {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5.5, height: 5.5)
                        .padding(.top, 4.5)
                        .padding(.trailing, 4.5)
                } else if let doc = activeDocument {
                    EditorDirtySubscriptionView(document: doc)
                }
            }
            .frame(width: 28, height: 28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                isHovered ? Color.primary.opacity(0.09) : Color.black.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.primary.opacity(0.26) : Color.primary.opacity(0.13),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.14), radius: 4, x: 0, y: 1.5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        })
        .buttonStyle(.plain)
        .fixedSize()
        .background(EditorAnchorReader(box: anchorBox))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                EditorHoverTooltipPresenter.shared.schedule(
                    text: hoverTooltipText,
                    shortcut: "⇧⎋",
                    anchor: anchorBox,
                    delayMs: 120
                )
            } else {
                EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
            }
        }
        .onDisappear {
            EditorHoverTooltipPresenter.shared.cancel(anchor: anchorBox)
        }
        .help(hoverTooltipText)
        .accessibilityLabel("Editor")
    }
}

/// Subscribes to active document's dirty state so the compact expand button updates immediately.
private struct EditorDirtySubscriptionView: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        if document.isDirty {
            Circle()
                .fill(Color.orange)
                .frame(width: 5.5, height: 5.5)
                .padding(.top, 4.5)
                .padding(.trailing, 4.5)
        }
    }
}

private final class EditorAnchorBox {
    weak var view: NSView?
}

private struct EditorAnchorReader: NSViewRepresentable {
    let box: EditorAnchorBox

    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: PassThroughView, context: Context) {
        box.view = nsView
    }
}

@MainActor
private final class EditorHoverTooltipPresenter {
    static let shared = EditorHoverTooltipPresenter()

    private weak var activeBox: EditorAnchorBox?
    private var hoverTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<EditorFloatingTooltipBubble>?

    private init() {
        for name in [
            NSApplication.didResignActiveNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }

    func schedule(text: String, shortcut: String?, anchor: EditorAnchorBox, delayMs: UInt64) {
        hoverTask?.cancel()
        activeBox = anchor
        hoverTask = Task { @MainActor [weak self, weak anchor] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled, let self, let anchor, self.activeBox === anchor else { return }
            self.present(text: text, shortcut: shortcut, from: anchor)
        }
    }

    func cancel(anchor: EditorAnchorBox) {
        guard activeBox === anchor else { return }
        hide()
    }

    func hide() {
        hoverTask?.cancel()
        hoverTask = nil
        activeBox = nil
        panel?.orderOut(nil)
    }

    private func present(text: String, shortcut: String?, from box: EditorAnchorBox) {
        guard let anchorView = box.view,
              let window = anchorView.window,
              window.isVisible else { return }
        let rectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        guard screenRect.width > 0, screenRect.height > 0 else { return }

        let bubble = EditorFloatingTooltipBubble(text: text, shortcut: shortcut)
        let host: NSHostingView<EditorFloatingTooltipBubble>
        if let existing = hostingView {
            existing.rootView = bubble
            host = existing
        } else {
            let created = NSHostingView(rootView: bubble)
            hostingView = created
            host = created
        }
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))

        let tooltipPanel: NSPanel
        if let existingPanel = panel {
            tooltipPanel = existingPanel
        } else {
            let created = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.level = .popUpMenu
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = true
            created.contentView = host
            panel = created
            tooltipPanel = created
        }

        tooltipPanel.appearance = window.effectiveAppearance
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        var originX = screenRect.maxX - size.width
        originX = min(max(originX, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6)
        var originY = screenRect.minY - size.height - 5
        if originY < visibleFrame.minY + 6 {
            originY = screenRect.maxY + 5
        }
        tooltipPanel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
        tooltipPanel.orderFront(nil)
    }
}

private struct EditorFloatingTooltipBubble: View {
    let text: String
    let shortcut: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if let shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(
                        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            }
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1)
        )
        .fixedSize()
    }
}

/// Routes "Ask Agent / Send to Quick Input" selections into the owning pane's QuickInput composer.
@MainActor
enum EditorQuickInputBridge {
    static func send(
        _ request: EditorAskAgentRequest,
        workingDirectory: String?,
        to controller: TerminalController,
        surface: Ghostty.SurfaceView
    ) {
        let prompt = request.formattedPrompt(workingDirectory: workingDirectory)
        guard !prompt.isEmpty else { return }
        if controller.focusedSurface !== surface {
            controller.focusedSurface = surface
        }
        if controller.quickInputModel.isEditingQueuedItem {
            controller.quickInputModel.cancelQueuedItemEdit()
        }
        controller.presentQuickInput(for: surface, requestFocus: true)
        controller.quickInputModel.useHistoryText(prompt, mode: .append)
    }
}

/// Shared single-WebView workbench pane backing all open code documents in an `EditorWorkspace`.
private struct EditorSharedWorkbenchPane: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var isSurfaceFocused: () -> Bool = { true }
    let terminalBackground: NSColor
    let terminalTheme: EditorTheme
    let onFocus: () -> Void
    let open: () -> Void
    let close: (EditorDocument) -> Void
    let onHide: () -> Void
    let onAskAgent: (EditorAskAgentRequest) -> Void
    let onNavigateDefinition: (String, EditorTextLocation) -> Void
    let openMarkdownLink: (String, EditorDocument) -> Void

    private var effectiveIsActive: Bool {
        workspace.gitDiff == nil && workspace.selectedDocument != nil && workspace.isVisible
    }

    private var resolvedTheme: EditorTheme {
        var theme = terminalTheme
        theme.background = EditorTheme.transparentBackground
        return theme
    }

    private var isDarkTheme: Bool {
        let srgb = terminalBackground.usingColorSpace(.sRGB) ?? terminalBackground
        if settings.editorSettings.followsOMG {
            return srgb.brightnessComponent < 0.55
        }
        if settings.editorSyntaxTheme == .oneLight {
            return false
        }
        return colorScheme == .dark || settings.editorSyntaxTheme != .oneLight
    }

    var body: some View {
        VStack(spacing: 0) {
            if let document = workspace.selectedDocument {
                EditorDocumentTopBanners(
                    document: document,
                    save: { Task { await workspace.save(document) } },
                    reloadFromDisk: { Task { try? await document.reload() } },
                    keepMyEdits: { document.keepLocalEditsAfterConflict() }
                )
            }
            ZStack(alignment: .topLeading) {
                MonacoWorkbenchSurface(controller: workspace.workbenchController)
                    .opacity(showsSelectedMarkdownPreview ? 0 : 1)
                    .allowsHitTesting(!showsSelectedMarkdownPreview)

                if let document = workspace.selectedDocument {
                    EditorActiveDocumentObserver(
                        workspace: workspace,
                        document: document,
                        isActive: effectiveIsActive,
                        isSurfaceFocused: isSurfaceFocused,
                        terminalBackground: terminalBackground,
                        resolvedTheme: resolvedTheme,
                        isDarkTheme: isDarkTheme,
                        onFocus: onFocus,
                        open: open,
                        close: { close(document) },
                        onHide: onHide,
                        onAskAgent: onAskAgent,
                        onNavigateDefinition: onNavigateDefinition,
                        openMarkdownLink: { href in openMarkdownLink(href, document) }
                    )
                    .id(document.id)
                }
            }
            if let document = workspace.selectedDocument {
                Divider()
                EditorDocumentStatusBar(document: document)
            }
        }
        .onAppear {
            workspace.workbenchController.isActive = effectiveIsActive
        }
        .onChange(of: workspace.selectedID) { [oldID = workspace.selectedID] newID in
            if let oldID, oldID != newID,
               let previous = workspace.documents.first(where: { $0.id == oldID }) {
                previous.flushAutoSave()
            }
        }
        .onChange(of: effectiveIsActive) { active in
            workspace.workbenchController.isActive = active
            if !active {
                workspace.selectedDocument?.flushAutoSave()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            workspace.selectedDocument?.flushAutoSave()
        }
    }

    private var showsSelectedMarkdownPreview: Bool {
        guard let document = workspace.selectedDocument else { return false }
        return document.isMarkdown && document.isPreviewMode
    }
}

private struct EditorDocumentTopBanners: View {
    @ObservedObject var document: EditorDocument
    let save: () -> Void
    let reloadFromDisk: () -> Void
    let keepMyEdits: () -> Void

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
            if document.hasExternalDiskConflict {
                HStack(spacing: 10) {
                    Label("File changed on disk", systemImage: "arrow.triangle.2.circlepath.circle")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Button("Reload from Disk", action: reloadFromDisk)
                        .controlSize(.small)
                        .disabled(document.isSaving || document.isReloading)
                    Button("Keep My Edits", action: keepMyEdits)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.14))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("File changed on disk")
            }
        }
    }
}

private struct EditorDocumentStatusBar: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
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
}

private struct EditorActiveDocumentObserver: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var document: EditorDocument
    @ObservedObject private var settings = OhMyGhosttySettings.shared

    let isActive: Bool
    let isSurfaceFocused: () -> Bool
    let terminalBackground: NSColor
    let resolvedTheme: EditorTheme
    let isDarkTheme: Bool
    let onFocus: () -> Void
    let open: () -> Void
    let close: () -> Void
    let onHide: () -> Void
    let onAskAgent: (EditorAskAgentRequest) -> Void
    let onNavigateDefinition: (String, EditorTextLocation) -> Void
    let openMarkdownLink: (String) -> Void

    private var showsMarkdownPreview: Bool {
        document.isMarkdown && document.isPreviewMode
    }

    var body: some View {
        Group {
            if document.isMarkdown {
                MarkdownPreviewView(
                    text: $document.text,
                    fileURL: URL(fileURLWithPath: document.path),
                    isRemote: document.filesystem.descriptor.kind == .ssh,
                    filesystem: document.filesystem,
                    terminalBackground: terminalBackground,
                    foregroundColor: resolvedTheme.text.color,
                    isActive: isActive && showsMarkdownPreview,
                    onFocus: onFocus,
                    onSave: { Task { await workspace.save(document) } },
                    onSaveAll: { Task { await workspace.saveAll() } },
                    onHide: onHide,
                    onOpenLink: openMarkdownLink
                )
                .id("\(document.id.monacoURI)-\(document.contentGeneration)")
                .opacity(showsMarkdownPreview ? 1 : 0)
                .allowsHitTesting(showsMarkdownPreview)
            } else {
                Color.clear
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            if document.pendingNavigation != nil && document.isPreviewMode {
                document.isPreviewMode = false
            }
            syncDocumentToWorkbench(preserveView: true)
            applyPendingNavigation()
        }
        .onChange(of: document.text) { _ in
            pushModel(preserveView: true)
        }
        .onChange(of: document.contentGeneration) { _ in
            pushModel(preserveView: false)
        }
        .onChange(of: document.externalSyncRevision) { _ in
            pushModel(preserveView: true)
        }
        .onChange(of: document.isRestoringFromGit) { _ in
            syncDocumentToWorkbench(preserveView: true)
        }
        .onChange(of: document.isPreviewMode) { _ in
            syncActivation()
            if !document.isPreviewMode {
                applyPendingNavigation()
            }
        }
        .onChange(of: document.pendingNavigation) { navigation in
            if navigation != nil && document.isPreviewMode {
                document.isPreviewMode = false
            }
            applyPendingNavigation()
        }
        .onChange(of: isActive) { _ in
            syncActivation()
        }
        .onChange(of: settings.editorSettings) { _ in
            syncDocumentToWorkbench(preserveView: true)
        }
        .onChange(of: resolvedTheme) { _ in
            workspace.workbenchController.setTheme(resolvedTheme, isDark: isDarkTheme)
        }
    }

    private func syncDocumentToWorkbench(preserveView: Bool) {
        let workbench = workspace.workbenchController
        configureCallbacks(on: workbench)
        workbench.setTheme(resolvedTheme, isDark: isDarkTheme)
        workbench.setFont(
            family: settings.editorSettings.fontFamily,
            size: settings.editorSettings.fontSize
        )
        // Ensure all open tabs in the workspace have backing Monaco models ready.
        for openDoc in workspace.documents {
            let readOnly = openDoc.isRestoringFromGit
            workbench.openOrUpdateModel(
                uri: openDoc.id.monacoURI,
                path: openDoc.path,
                text: openDoc.text,
                readOnly: readOnly,
                preserveView: openDoc.id == document.id ? preserveView : true
            )
        }
        syncActivation()
    }

    private func pushModel(preserveView: Bool) {
        workspace.workbenchController.openOrUpdateModel(
            uri: document.id.monacoURI,
            path: document.path,
            text: document.text,
            readOnly: document.isRestoringFromGit,
            preserveView: preserveView
        )
    }

    private func syncActivation() {
        let workbench = workspace.workbenchController
        configureCallbacks(on: workbench)
        let editorSettings = settings.editorSettings
        let readOnly = document.isRestoringFromGit || showsMarkdownPreview
        let wordWrap = document.isMarkdown ? true : editorSettings.wordWrap
        let insertSpaces = !EditorLanguageMapping.usesHardTabs(forPath: document.path)
        workbench.isPreview = showsMarkdownPreview
        workbench.keymap = editorSettings.keymap
        workbench.isSurfaceFocused = isSurfaceFocused
        workbench.isActive = isActive
        workbench.activateModel(
            uri: document.id.monacoURI,
            readOnly: readOnly,
            wordWrap: wordWrap,
            tabSize: max(1, editorSettings.tabWidth),
            insertSpaces: insertSpaces,
            keymapProfile: editorSettings.keymapProfile
        )
    }

    private func configureCallbacks(on workbench: MonacoWorkbenchController) {
        workbench.onFocus = onFocus
        workbench.onAskAgent = onAskAgent
        workbench.onNavigateDefinition = onNavigateDefinition
        workbench.onTextChange = { [weak workspace] uri, updated in
            guard let doc = workspace?.documents.first(where: { $0.id.monacoURI == uri }),
                  doc.text != updated else { return }
            doc.text = updated
        }
        workbench.onCommand = { [weak workspace] action in
            guard let workspace else { return false }
            switch action {
            case .save:
                if let active = workspace.selectedDocument {
                    Task { await workspace.save(active) }
                }
            case .saveAll:
                Task { await workspace.saveAll() }
            case .close:
                close()
            case .open:
                open()
            case .nextDocument:
                workspace.selectAdjacentDocument(offset: 1)
            case .previousDocument:
                workspace.selectAdjacentDocument(offset: -1)
            case .hide:
                onHide()
            default:
                return false
            }
            return true
        }
    }

    private func applyPendingNavigation() {
        guard !showsMarkdownPreview, let request = document.pendingNavigation else { return }
        workspace.workbenchController.revealLocation(request.location, in: document.id.monacoURI)
        document.consumeNavigation(request.id)
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
