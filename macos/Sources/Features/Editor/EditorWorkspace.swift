import AppKit
import Combine
import Foundation

@MainActor
final class EditorWorkspace: ObservableObject {
    @Published private(set) var documents: [EditorDocument] = []
    @Published var selectedID: EditorDocumentID?
    @Published var isVisible = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    private var openTask: Task<Void, Never>?

    var selectedDocument: EditorDocument? {
        documents.first { $0.id == selectedID }
    }

    func selectAdjacentDocument(offset: Int) {
        guard !documents.isEmpty else { return }
        let current = documents.firstIndex { $0.id == selectedID } ?? 0
        let index = ((current + offset) % documents.count + documents.count) % documents.count
        selectedID = documents[index].id
        isVisible = true
    }

    func saveAll() async -> Bool {
        for document in documents where document.isDirty || document.isSaving {
            guard await save(document) else { return false }
        }
        return true
    }

    func reload(_ document: EditorDocument, window: NSWindow?) async {
        guard !document.isSaving, !document.isReloading else { return }
        document.suspendAutoSave()
        defer { document.resumeAutoSave() }
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Reload \"\((document.path as NSString).lastPathComponent)\"?"
            alert.informativeText = "Reloading replaces your unsaved changes with the current file contents."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            let response: NSApplication.ModalResponse
            if let window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
        }
        do {
            try await document.reload()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(path: String, filesystem: any WorkspaceFilesystem) {
        isVisible = true
        errorMessage = nil
        openTask?.cancel()
        if let id = try? EditorDocumentID(descriptor: filesystem.descriptor, path: path),
           documents.contains(where: { $0.id == id }) {
            selectedID = id
            isLoading = false
            return
        }
        isLoading = true
        openTask = Task { [weak self] in
            do {
                let document = try await EditorDocument.open(path: path, filesystem: filesystem)
                guard !Task.isCancelled, let self else { return }
                documents.append(document)
                selectedID = document.id
                isLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func save(_ document: EditorDocument) async -> Bool {
        guard !document.isSaving else { return false }
        do {
            try await document.save()
            errorMessage = nil
            return !document.isDirty
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func close(_ document: EditorDocument, window: NSWindow?) async {
        guard await canClose(document, window: window) else { return }
        remove(document)
    }

    func closeAll(window: NSWindow?) async -> Bool {
        for document in documents {
            guard await canClose(document, window: window) else { return false }
            remove(document)
        }
        openTask?.cancel()
        isLoading = false
        return true
    }

    private func canClose(_ document: EditorDocument, window: NSWindow?) async -> Bool {
        guard !document.isSaving else { return false }
        guard document.isDirty else { return true }
        document.suspendAutoSave()
        defer { document.resumeAutoSave() }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\((document.path as NSString).lastPathComponent)\"?"
        alert.informativeText = "Your changes will be lost if you close without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return await save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func remove(_ document: EditorDocument) {
        document.suspendAutoSave()
        documents.removeAll { $0.id == document.id }
        if selectedID == document.id { selectedID = documents.last?.id }
        if documents.isEmpty { isVisible = false }
    }
}

@MainActor
final class EditorWorkspaceStore {
    static let shared = EditorWorkspaceStore()
    private var workspaces: [UUID: EditorWorkspace] = [:]
    private var owners: [UUID: UUID] = [:]
    private var closing = Set<UUID>()
    private var isResolvingTermination = false

    func workspace(for tabID: UUID, surfaceID: UUID) -> EditorWorkspace {
        owners[surfaceID] = tabID
        if let existing = workspaces[surfaceID] { return existing }
        let workspace = EditorWorkspace()
        workspaces[surfaceID] = workspace
        return workspace
    }

    func open(path: String, context: InspectorPaneContext, destination: EditorOpenDestination = .currentPane) {
        guard let controller = NSApp.windows.compactMap({ $0.windowController as? TerminalController })
            .first(where: { $0.tabSessionID == context.tabID }),
              let source = controller.surfaceTree.first(where: { $0.id == context.surfaceID })
                ?? controller.focusedSurface ?? controller.surfaceTree.first else { return }
        let targetController: TerminalController
        let target: Ghostty.SurfaceView
        switch destination {
        case .currentPane:
            targetController = controller
            target = source
        case .newTab:
            guard let created = TerminalController.newTab(controller.ghostty, from: controller.window),
                  let surface = created.surfaceTree.first else { return }
            targetController = created
            target = surface
        case .splitRight, .splitDown, .splitLeft, .splitUp:
            guard let surface = controller.newSplit(at: source, direction: destination.splitDirection) else { return }
            targetController = controller
            target = surface
        }
        targetController.focusedSurface = target
        workspace(for: targetController.tabSessionID, surfaceID: target.id).open(
            path: path,
            filesystem: WorkspaceFilesystemFactory.make(for: context)
        )
    }

    /// Called at the terminal's final close boundary, including programmatic closes.
    func prepareToClose(tabIDs: [UUID], window: NSWindow?, retry: @escaping () -> Void) -> Bool {
        let surfaceIDs = owners.compactMap { tabIDs.contains($0.value) ? $0.key : nil }
        return prepareToClose(surfaceIDs: surfaceIDs, window: window, retry: retry)
    }

    func prepareToClose(surfaceIDs: [UUID], window: NSWindow?, retry: @escaping () -> Void) -> Bool {
        let pending = surfaceIDs.filter { id in
            workspaces[id]?.documents.contains { $0.isDirty || $0.isSaving } == true
        }
        guard !pending.isEmpty else { return true }
        guard closing.isDisjoint(with: pending) else { return false }
        closing.formUnion(pending)
        Task {
            defer { closing.subtract(pending) }
            for id in pending {
                guard await workspaces[id]?.closeAll(window: window) == true else { return }
            }
            retry()
        }
        return false
    }

    func remove(tabID: UUID) {
        for surfaceID in owners.compactMap({ $0.value == tabID ? $0.key : nil }) {
            owners.removeValue(forKey: surfaceID)
            workspaces.removeValue(forKey: surfaceID)
        }
    }

    func prepareToTerminate() -> Bool {
        let pending = workspaces.values.filter { workspace in
            workspace.documents.contains { $0.isDirty || $0.isSaving }
        }
        guard !pending.isEmpty else { return true }
        guard !isResolvingTermination else { return false }
        isResolvingTermination = true
        Task {
            defer { isResolvingTermination = false }
            for workspace in pending {
                guard await workspace.closeAll(window: NSApp.keyWindow) else { return }
            }
            // Re-enter the host's existing terminal-process quit handling.
            NSApp.terminate(nil)
        }
        return false
    }
}
