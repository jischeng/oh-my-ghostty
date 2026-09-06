import AppKit
import SwiftUI

@MainActor
final class EditorFilePicker: NSWindowController {
    private let parentWindow: NSWindow
    private let onOpen: (String) -> Void

    static func present(
        filesystem: any WorkspaceFilesystem,
        for parentWindow: NSWindow,
        onOpen: @escaping (String) -> Void
    ) {
        let picker = EditorFilePicker(
            filesystem: filesystem,
            parentWindow: parentWindow,
            onOpen: onOpen
        )
        guard let window = picker.window else { return }
        parentWindow.beginSheet(window) { _ in
            _ = picker
        }
    }

    private init(
        filesystem: any WorkspaceFilesystem,
        parentWindow: NSWindow,
        onOpen: @escaping (String) -> Void
    ) {
        self.parentWindow = parentWindow
        self.onOpen = onOpen
        let model = EditorFilePickerModel(filesystem: filesystem)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open Remote File — \(filesystem.descriptor.displayName)"
        super.init(window: panel)
        panel.contentViewController = NSHostingController(
            rootView: EditorFilePickerView(
                model: model,
                onCancel: { [weak self] in self?.finish() },
                onOpen: { [weak self] path in self?.finish(opening: path) }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func finish(opening path: String? = nil) {
        guard let window else { return }
        parentWindow.endSheet(window)
        if let path { onOpen(path) }
    }
}

@MainActor
final class EditorFilePickerModel: ObservableObject {
    @Published private(set) var directory: String
    @Published var pathInput: String = ""
    @Published private(set) var entries: [WorkspaceFileEntry] = []
    @Published var selection: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let filesystem: any WorkspaceFilesystem
    private var loadTask: Task<Void, Never>?

    init(filesystem: any WorkspaceFilesystem) {
        self.filesystem = filesystem
        let initialDir = filesystem.descriptor.workingDirectory
        self.directory = initialDir
        self.pathInput = initialDir
        load(initialDir)
    }

    var selectedEntry: WorkspaceFileEntry? {
        entries.first { $0.path == selection }
    }

    var canGoUp: Bool { directory != "/" }

    func open(_ entry: WorkspaceFileEntry, fileHandler: (String) -> Void) {
        if entry.isDirectory {
            load(entry.path)
        } else {
            fileHandler(entry.path)
        }
    }

    func goUp() {
        guard canGoUp else { return }
        let parent = (directory as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    func retry() {
        load(directory)
    }

    func navigate(to input: String, fileHandler: (String) -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: String
        if trimmed.hasPrefix("/") {
            target = (trimmed as NSString).standardizingPath
        } else {
            target = ((directory as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
        }
        if let file = entries.first(where: { $0.path == target && !$0.isDirectory }) {
            fileHandler(file.path)
            return
        }
        load(target)
    }

    func openSelection(fileHandler: (String) -> Void) {
        guard let selectedEntry else { return }
        open(selectedEntry, fileHandler: fileHandler)
    }

    private func load(_ path: String) {
        loadTask?.cancel()
        directory = path
        pathInput = path
        entries = []
        selection = nil
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await filesystem.listDirectory(at: path)
                guard !Task.isCancelled, directory == path else { return }
                entries = result
            } catch {
                guard !Task.isCancelled, directory == path else { return }
                entries = []
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled, directory == path else { return }
            isLoading = false
        }
    }
}

private struct EditorFilePickerView: View {
    @ObservedObject var model: EditorFilePickerModel
    let onCancel: () -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: model.goUp) {
                    Image(systemName: "chevron.up")
                }
                .help("Parent Directory")
                .disabled(!model.canGoUp || model.isLoading)

                TextField("Path", text: $model.pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        model.navigate(to: model.pathInput, fileHandler: onOpen)
                    }

                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if let errorMessage = model.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Could Not Open Directory").font(.headline)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: model.retry)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries, id: \.path, selection: $model.selection) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                        Text(entry.name).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.open(entry, fileHandler: onOpen)
                    }
                    .tag(entry.path)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    model.openSelection(fileHandler: onOpen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedEntry == nil || model.isLoading)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
    }
}
