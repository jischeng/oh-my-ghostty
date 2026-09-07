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

    var body: some View {
        ZStack {
            terminal
                .opacity(workspace.isVisible ? 0 : 1)
                .allowsHitTesting(!workspace.isVisible)
                .accessibilityHidden(workspace.isVisible)
            if !workspace.documents.isEmpty || workspace.isVisible {
                editor
                    .opacity(workspace.isVisible ? 1 : 0)
                    .allowsHitTesting(workspace.isVisible)
                    .accessibilityHidden(!workspace.isVisible)
                    .simultaneousGesture(TapGesture().onEnded {
                        if controller.focusedSurface !== surfaceView {
                            controller.focusedSurface = surfaceView
                        }
                    })
            }
        }
        .overlay(alignment: .topTrailing) {
            if !workspace.isVisible, !workspace.documents.isEmpty {
                Button("Editor") {
                    if controller.focusedSurface !== surfaceView {
                        controller.focusedSurface = surfaceView
                    }
                    workspace.isVisible = true
                }.padding(8)
            }
        }
        .onChange(of: workspace.isVisible) { visible in
            if visible {
                if controller.focusedSurface !== surfaceView {
                    controller.focusedSurface = surfaceView
                }
            } else if controller.focusedSurface === surfaceView {
                controller.focusSurface(surfaceView)
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents, id: \.id) { document in
                                EditorDocumentTab(
                                    document: document,
                                    isSelected: workspace.selectedID == document.id,
                                    select: { workspace.selectedID = document.id },
                                    close: { close(document) }
                                )
                                .id(document.id)
                            }
                        }
                    }
                    .onChange(of: workspace.selectedID) { selected in
                        if let selected { proxy.scrollTo(selected) }
                    }
                }
                documentMenu
                Button(action: openFile) { Image(systemName: "folder.badge.plus") }
                    .help("Open File")
                Button { workspace.isVisible = false } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Back to Terminal")
            }
            .buttonStyle(.borderless)
            .padding(6)
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
            if !workspace.documents.isEmpty {
                ZStack {
                    ForEach(workspace.documents, id: \.id) { document in
                        let selected = workspace.selectedID == document.id
                        EditorDocumentView(
                            document: document,
                            isActive: selected && workspace.isVisible,
                            isSurfaceFocused: {
                                (controller.focusedSurface ?? controller.surfaceTree.first) === surfaceView
                            },
                            terminalBackground: NSColor(terminalColor),
                            terminalBackgroundOpacity: terminalOpacity,
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
                            saveAll: { Task { await workspace.saveAll() } }
                        )
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.largeTitle)
                    Text("Open a file from Files or choose Open File.")
                    Button("Open File", action: openFile)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            OhMyGhosttySettings.shared.editorBackgroundMode == .followTerminal
                ? terminalColor.opacity(terminalOpacity)
                : Color(nsColor: .textBackgroundColor).opacity(terminalOpacity)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code Editor")
    }

    private func close(_ document: EditorDocument) {
        Task { await workspace.close(document, window: controller.window) }
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

    private var documentMenu: some View {
        Menu {
            ForEach(workspace.documents, id: \.id) { document in
                Button(document.path) { workspace.selectedID = document.id }
            }
            Divider()
            Button("Save All") { Task { await workspace.saveAll() } }
                .disabled(workspace.documents.isEmpty)
            Button("Reload File") {
                if let document = workspace.selectedDocument {
                    Task { await workspace.reload(document, window: controller.window) }
                }
            }
            .disabled(workspace.selectedDocument == nil)
            Button("Close All Files") { Task { await workspace.closeAll(window: controller.window) } }
                .disabled(workspace.documents.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("File Actions and Open Files")
    }

    private func openFile() {
        EditorMenuController.shared.openFile(in: controller, surface: surfaceView)
    }
}

private struct EditorDocumentTab: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if document.isDirty { Circle().frame(width: 6, height: 6) }
                    Text((document.path as NSString).lastPathComponent).lineLimit(1)
                }
            }
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .help("Close File")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .help(document.filesystem.descriptor.presentationTitle + " — " + document.path)
    }
}

private struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    var isSurfaceFocused: () -> Bool = { true }
    let terminalBackground: NSColor
    let terminalBackgroundOpacity: Double
    let onFocus: () -> Void
    let save: () -> Void
    let close: () -> Void
    let open: () -> Void
    let nextDocument: () -> Void
    let previousDocument: () -> Void
    let saveAll: () -> Void

    @State private var isPreviewMode = false

    private var isMarkdownDocument: Bool {
        document.path.hasSuffix(".md") || document.path.hasSuffix(".markdown")
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
                    isEditable: true,
                    isActive: isActive,
                    isPreview: isMarkdownDocument && isPreviewMode,
                    isSurfaceFocused: isSurfaceFocused,
                    terminalBackground: terminalBackground,
                    terminalBackgroundOpacity: terminalBackgroundOpacity,
                    terminalForeground: contrastingForeground,
                    onFocus: onFocus,
                    onSave: save,
                    onClose: close,
                    onOpen: open,
                    onNextDocument: nextDocument,
                    onPreviousDocument: previousDocument,
                    onSaveAll: saveAll
                )
                .id(document.contentGeneration)
                .opacity((isMarkdownDocument && isPreviewMode) ? 0 : 1)
                .allowsHitTesting(!(isMarkdownDocument && isPreviewMode))

                if isMarkdownDocument && isPreviewMode {
                    MarkdownPreviewView(
                        text: document.text,
                        fileURL: URL(fileURLWithPath: document.path),
                        isRemote: document.filesystem.descriptor.kind == .ssh,
                        filesystem: document.filesystem,
                        terminalBackground: terminalBackground,
                        terminalBackgroundOpacity: terminalBackgroundOpacity,
                        foregroundColor: contrastingForeground
                    )
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

                if isMarkdownDocument {
                    Picker("", selection: $isPreviewMode) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 120)
                }

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
        .onChange(of: isActive) { active in
            if !active {
                document.flushAutoSave()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            document.flushAutoSave()
        }
    }

    private var contrastingForeground: NSColor {
        guard let color = terminalBackground.usingColorSpace(.deviceRGB) else { return .textColor }
        let luminance = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
        return luminance < 0.5 ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }
}
