import AppKit
import SwiftUI

/// File browsing changes the selected document; terminal cwd changes do not.
struct EditorWorkspaceHost<Terminal: View>: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject private var workspace: EditorWorkspace
    private let terminal: Terminal

    init(controller: TerminalController, @ViewBuilder terminal: () -> Terminal) {
        self.controller = controller
        self.workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID)
        self.terminal = terminal()
    }

    var body: some View {
        HSplitView {
            terminal.frame(minWidth: 240)
                .overlay(alignment: .topTrailing) {
                    if !workspace.isVisible, !workspace.documents.isEmpty {
                        Button { workspace.isVisible = true } label: {
                            Label("Editor", systemImage: "doc.text")
                        }.padding(8)
                    }
                }
            if workspace.isVisible || !workspace.documents.isEmpty {
                editor
                    .frame(minWidth: workspace.isVisible ? 320 : 0, idealWidth: workspace.isVisible ? 600 : 0)
                    .frame(maxWidth: workspace.isVisible ? .infinity : 0)
                    .clipped()
                    .opacity(workspace.isVisible ? 1 : 0)
                    .allowsHitTesting(workspace.isVisible)
                    .accessibilityHidden(!workspace.isVisible)
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(workspace.documents, id: \.id) { document in
                            EditorDocumentTab(
                                document: document,
                                isSelected: workspace.selectedID == document.id,
                                select: { workspace.selectedID = document.id },
                                close: { close(document) }
                            )
                        }
                    }
                }
                Button(action: openFile) { Image(systemName: "folder.badge.plus") }
                    .help("Open File")
                Button { workspace.isVisible = false } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Hide Editor")
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
                            save: { Task { await workspace.save(document) } },
                            close: { close(document) },
                            open: openFile
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
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code Editor")
    }

    private func close(_ document: EditorDocument) {
        Task { await workspace.close(document, window: controller.window) }
    }

    private func openFile() {
        EditorMenuController.shared.openFile(in: controller)
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
    let save: () -> Void
    let close: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorView(
                text: $document.text,
                fileURL: URL(fileURLWithPath: document.path),
                isActive: isActive,
                onSave: save,
                onClose: close,
                onOpen: open
            )
            Divider()
            HStack {
                Text(document.path).lineLimit(1).truncationMode(.middle)
                    .help(document.path)
                Spacer(minLength: 8)
                if document.filesystem.descriptor.kind == .ssh {
                    Label(document.filesystem.descriptor.displayName, systemImage: "network")
                }
                Button(document.isSaving ? "Saving…" : "Save", action: save)
                    .disabled(!document.isDirty || document.isSaving)
                    .help("Save (⌘S)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
    }
}

/// Intercept editor commands only while the first responder belongs to this
/// editor region, so terminal shortcuts retain their normal behavior.
struct EditorKeyCommands: NSViewRepresentable {
    let actions: [String: () -> Void]

    func makeNSView(context: Context) -> EditorCommandView {
        let view = EditorCommandView()
        view.actions = actions
        return view
    }

    func updateNSView(_ view: EditorCommandView, context: Context) {
        view.actions = actions
    }
}

final class EditorCommandView: NSView {
    var actions: [String: () -> Void] = [:]
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window,
                  let responder = window.firstResponder as? NSView,
                  !isHiddenOrHasHiddenAncestor,
                  bounds.width > 0,
                  bounds.intersects(convert(responder.bounds, from: responder)),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let action = actions[key] else { return event }
            action()
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
