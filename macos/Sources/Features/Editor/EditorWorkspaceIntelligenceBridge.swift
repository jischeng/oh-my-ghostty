import AppKit
import Foundation

/// Connects an `EditorWorkspace`'s documents and shared `MonacoWorkbenchController` to
/// `EditorIntelligenceCoordinator` (LSP + `EditorSymbolIndex` + `EditorCompletionEngine`),
/// `EditorFileWatcher` (atomic-write-safe local kqueue + SSH focus refresh), and
/// `EditorGitGutterService` (working-tree gutter diff bars).
@MainActor
final class EditorWorkspaceIntelligenceBridge {
    let coordinator: EditorIntelligenceCoordinator
    let fileWatcher: EditorFileWatcher
    let gitGutter: EditorGitGutterService

    private weak var workspace: EditorWorkspace?
    private var debouncedChangeTasks: [EditorDocumentID: Task<Void, Never>] = [:]
    private var gutterTasks: [EditorDocumentID: Task<Void, Never>] = [:]
    private var lifecycleTasks: [EditorDocumentID: Task<Void, Never>] = [:]
    private var focusCheckTask: Task<Void, Never>?
    private nonisolated(unsafe) var windowKeyObserver: NSObjectProtocol?

    init(
        workspace: EditorWorkspace,
        coordinator: EditorIntelligenceCoordinator? = nil,
        fileWatcherDebounce: TimeInterval = 0.12,
        gitGutter: EditorGitGutterService = EditorGitGutterService()
    ) {
        self.workspace = workspace
        self.gitGutter = gitGutter
        if let coordinator {
            self.coordinator = coordinator
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let disabled = EditorLSPServerCommand(executable: "/usr/bin/false-omg-xctest-lsp-disabled")
            let testLSP = EditorLSPManager(serverCommands: [
                "swift": disabled,
                "zig": disabled,
                "rust": disabled,
                "go": disabled,
                "typescript": disabled,
                "python": disabled,
                "clangd": disabled
            ])
            self.coordinator = EditorIntelligenceCoordinator(lspManager: testLSP)
        } else {
            self.coordinator = EditorIntelligenceCoordinator()
        }
        self.fileWatcher = EditorFileWatcher(debounceInterval: fileWatcherDebounce)

        configureCallbacks()
        installWindowFocusObserver()
    }

    deinit {
        if let observer = windowKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Document Registration & Lifecycle

    func registerDocument(_ document: EditorDocument) {
        let docID = document.id
        document.onWillWriteData = { [weak self, weak document] data in
            guard let self, let document, document.id.endpoint == .local else { return }
            self.fileWatcher.recordPendingSelfSave(data, forPath: document.path)
        }
        document.onDidPersistSnapshot = { [weak self, weak document] data, savedText in
            guard let self, let document else { return }
            if document.id.endpoint == .local {
                self.fileWatcher.updateExpectedData(data, forPath: document.path)
            }
            let ctx = self.documentContext(for: document)
            Task { @MainActor [weak self] in
                await self?.coordinator.documentDidSave(ctx, text: savedText)
            }
            self.refreshGitGutter(for: document)
        }
        document.onDidEditText = { [weak self, weak document] updatedText in
            guard let self, let document else { return }
            self.scheduleDidChange(for: document, text: updatedText)
        }

        if document.id.endpoint == .local {
            fileWatcher.watchLocalFile(
                path: document.path,
                expectedData: document.persistedSnapshotData
            )
        }

        let ctx = documentContext(for: document)
        let initialText = document.text
        lifecycleTasks[docID]?.cancel()
        lifecycleTasks[docID] = Task { @MainActor [weak self] in
            await self?.coordinator.documentDidOpen(ctx, text: initialText)
        }

        refreshGitGutter(for: document)
    }

    func unregisterDocument(_ document: EditorDocument) {
        let docID = document.id
        document.onWillWriteData = nil
        document.onDidPersistSnapshot = nil
        document.onDidEditText = nil

        debouncedChangeTasks.removeValue(forKey: docID)?.cancel()
        gutterTasks.removeValue(forKey: docID)?.cancel()
        lifecycleTasks.removeValue(forKey: docID)?.cancel()

        if document.id.endpoint == .local {
            let stillOpenLocally = workspace?.documents.contains { other in
                other.id != docID && other.id.endpoint == .local && other.path == document.path
            } ?? false
            if !stillOpenLocally {
                fileWatcher.unwatch(path: document.path)
            }
        }

        let ctx = documentContext(for: document)
        let coordinator = self.coordinator
        Task { @MainActor in
            await coordinator.documentDidClose(ctx)
        }
    }

    func tearDown() {
        focusCheckTask?.cancel()
        focusCheckTask = nil
        for (_, task) in debouncedChangeTasks { task.cancel() }
        debouncedChangeTasks.removeAll()
        for (_, task) in gutterTasks { task.cancel() }
        gutterTasks.removeAll()
        for (_, task) in lifecycleTasks { task.cancel() }
        lifecycleTasks.removeAll()
        fileWatcher.stopAll()
        let coordinator = self.coordinator
        Task { @MainActor in
            await coordinator.shutdown()
        }
    }

    func refreshGitGutter(for document: EditorDocument, remoteExecutor: (any GitExecutor)? = nil) {
        let docID = document.id
        let uri = docID.monacoURI
        let path = document.path
        let root = document.filesystem.descriptor.workingDirectory
        let isLocal = docID.endpoint == .local
        let gutterService = gitGutter

        gutterTasks[docID]?.cancel()
        gutterTasks[docID] = Task { @MainActor [weak self] in
            let diffMap: [Int: EditorGutterLineKind]
            if isLocal {
                diffMap = await gutterService.diffLines(forFileAt: path, workingDirectory: root)
            } else if let remoteExecutor {
                diffMap = await gutterService.diffLines(
                    forFileAt: path,
                    repositoryRoot: root,
                    executor: remoteExecutor
                )
            } else {
                return
            }
            guard !Task.isCancelled,
                  let workspace = self?.workspace,
                  workspace.documents.contains(where: { $0.id == docID }) else { return }
            let payload = EditorGitGutterService.bridgePayload(from: diffMap)
            workspace.workbenchController.setGitDiffLines(uri: uri, lines: payload)
        }
    }

    func refreshRemoteDocumentsOnFocus() async {
        guard let workspace else { return }
        let remoteDocs = workspace.documents.filter { $0.id.endpoint != .local }
        for doc in remoteDocs {
            guard !Task.isCancelled else { return }
            if let change = await fileWatcher.checkExternalChange(
                path: doc.path,
                filesystem: doc.filesystem,
                expectedData: doc.persistedSnapshotData
            ), let text = change.text, let encoding = change.encoding {
                doc.applyExternalDiskUpdate(data: change.data, decoded: (text, encoding))
            }
        }
    }

    // MARK: - Private Wiring

    private func configureCallbacks() {
        fileWatcher.expectedDataProvider = { [weak self] path in
            self?.workspace?.documents.first { doc in
                doc.id.endpoint == .local && doc.path == path
            }?.persistedSnapshotData
        }

        fileWatcher.onExternalChange = { [weak self] change in
            self?.handleExternalChange(change)
        }

        coordinator.onDiagnostics = { [weak self] path, diagnostics in
            guard let workspace = self?.workspace else { return }
            let markers = diagnostics.map(\.bridgeDictionary)
            for doc in workspace.documents where doc.id.endpoint == .local && doc.path == path {
                workspace.workbenchController.setDiagnostics(uri: doc.id.monacoURI, markers: markers)
            }
        }

        workspace?.workbenchController.onLSPRequest = { [weak self] method, uri, path, line, column, trigger in
            guard let self else { return nil }
            return await self.handleLSPRequest(
                method: method,
                uri: uri,
                path: path,
                line: line,
                column: column,
                triggerCharacter: trigger
            )
        }
    }

    private func installWindowFocusObserver() {
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let workspace = self.workspace, workspace.isVisible else { return }
                self.focusCheckTask?.cancel()
                self.focusCheckTask = Task { @MainActor [weak self] in
                    await self?.refreshRemoteDocumentsOnFocus()
                }
            }
        }
    }

    private func handleExternalChange(_ change: EditorExternalFileChange) {
        guard let workspace else { return }
        let matching = workspace.documents.filter {
            $0.id.endpoint == .local && $0.path == change.path
        }
        guard !matching.isEmpty else { return }

        for doc in matching {
            if let text = change.text, let encoding = change.encoding {
                let wasDirty = doc.isDirty
                doc.applyExternalDiskUpdate(data: change.data, decoded: (text, encoding))
                if !wasDirty {
                    fileWatcher.updateExpectedData(change.data, forPath: doc.path)
                    let ctx = documentContext(for: doc)
                    Task { @MainActor [weak self] in
                        await self?.coordinator.documentDidChange(ctx, text: text)
                    }
                }
            }
            refreshGitGutter(for: doc)
        }
    }

    private func scheduleDidChange(for document: EditorDocument, text: String) {
        let docID = document.id
        let ctx = documentContext(for: document)
        debouncedChangeTasks[docID]?.cancel()
        debouncedChangeTasks[docID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.coordinator.documentDidChange(ctx, text: text)
        }
    }

    private func handleLSPRequest(
        method: String,
        uri: String,
        path: String,
        line: Int,
        column: Int,
        triggerCharacter: String?
    ) async -> Any? {
        guard let workspace else { return nil }
        let matchedDoc = workspace.documents.first { $0.id.monacoURI == uri }
            ?? workspace.documents.first { $0.path == path }
        let ctx: EditorIntelligenceDocumentContext
        let currentText: String
        if let matchedDoc {
            ctx = documentContext(for: matchedDoc)
            currentText = matchedDoc.text
        } else if let model = workspace.workbenchController.openModels[uri] {
            ctx = EditorIntelligenceDocumentContext(
                path: model.path,
                languageHint: model.languageHint,
                workspaceRoot: nil,
                isLocal: !uri.hasPrefix("omg-model://ssh-")
            )
            currentText = model.text
        } else {
            return nil
        }

        let position = EditorPosition(line: line, column: column)
        switch method {
        case "hover":
            return await coordinator.hover(for: ctx, text: currentText, at: position)?.bridgeDictionary
        case "definition":
            return await coordinator.definitions(for: ctx, text: currentText, at: position)
                .map(\.bridgeDictionary)
        case "references":
            return await coordinator.references(for: ctx, text: currentText, at: position)
                .map(\.bridgeDictionary)
        case "documentSymbol":
            return await coordinator.documentSymbols(for: ctx, text: currentText)
                .map(\.bridgeDictionary)
        case "completion":
            return await coordinator.completions(
                for: ctx,
                text: currentText,
                at: position,
                triggerCharacter: triggerCharacter
            ).map(\.bridgeDictionary)
        default:
            return nil
        }
    }

    private func documentContext(for document: EditorDocument) -> EditorIntelligenceDocumentContext {
        let languageHint = workspace?.workbenchController.openModels[document.id.monacoURI]?.languageHint
        return EditorIntelligenceDocumentContext(document: document, languageHint: languageHint)
    }
}
