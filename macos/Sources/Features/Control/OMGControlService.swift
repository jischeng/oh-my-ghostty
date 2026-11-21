import AppKit
import OSLog

/// A validated `editor.open` / `viewer.open` request.
struct OMGControlOpenRequest: Equatable {
    enum Target: Equatable {
        case file(path: String, location: EditorTextLocation?)
        case url(String)
    }

    let target: Target
    let workingDirectory: String
    let pane: UUID?
    let tab: UUID?
    let destination: EditorOpenDestination?
    let wait: Bool
    /// `omg +edit newfile` starts an empty file, like other terminal editors.
    /// Viewing never creates one.
    let createsMissingFile: Bool

    init(method: OMGControlProtocol.Method, params: OMGControlOpenParams) throws {
        guard params.cwd.hasPrefix("/"), params.cwd.utf8.count <= 4_096, !params.cwd.contains("\0") else {
            throw OMGControlError.invalidParams("`cwd` must be an absolute directory")
        }
        guard !params.path.isEmpty, params.path.utf8.count <= 16_384 else {
            throw OMGControlError.invalidParams("`path` is empty or too long")
        }
        if let name = params.destination {
            guard let destination = Self.destinations[name] else {
                throw OMGControlError.invalidParams(
                    "`destination` must be one of current, tab, right, down, left, up"
                )
            }
            self.destination = destination
        } else {
            destination = nil
        }

        let lowercased = params.path.lowercased()
        if method == .viewerOpen, lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            target = .url(params.path)
        } else {
            // The CLI runs on this Mac, so the path is always a local one.
            guard let resolved = TerminalPathTarget.target(params.path, directory: params.cwd, isRemote: false) else {
                throw OMGControlError.invalidParams("`\(params.path)` is not a file path")
            }
            target = .file(path: resolved.path, location: resolved.location)
        }
        workingDirectory = params.cwd
        // A stale or foreign identifier must not fail the request; the
        // frontmost pane is the fallback.
        pane = params.pane.flatMap(UUID.init(uuidString:))
        tab = params.tab.flatMap(UUID.init(uuidString:))
        wait = method == .editorOpen && params.wait == true
        createsMissingFile = method == .editorOpen
    }

    static let destinations: [String: EditorOpenDestination] = [
        "current": .currentPane,
        "tab": .newTab,
        "right": .splitRight,
        "down": .splitDown,
        "left": .splitLeft,
        "up": .splitUp,
    ]
}

enum OMGControlOpenOutcome {
    /// Open in an OMG editor pane; `--wait` watches this document.
    case document(workspace: EditorWorkspace, id: EditorDocumentID)
    /// Handed to the file's default application; there is nothing to wait for.
    case external(path: String)
    case url
}

/// App-side owner of the local control plane: listens on the channel's
/// control socket and serves `editor.open` / `viewer.open`.
@MainActor
final class OMGControlService {
    typealias Opener = @MainActor (OMGControlOpenRequest) async -> Result<OMGControlOpenOutcome, OMGControlError>

    static let shared = OMGControlService()
    /// The Surface UUID, so a CLI run in a pane can name the pane it runs in.
    nonisolated static let paneEnvironmentKey = "OMG_PANE_ID"

    private static let logger = Logger(subsystem: "com.jischeng.omg", category: "control")

    private struct Waiter {
        let workspace: ObjectIdentifier
        let document: EditorDocumentID
        let finish: () -> Void
    }

    private let server = OMGControlServer()
    private let opener: Opener
    private var openChain: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]

    init(opener: @escaping Opener = OMGControlEditorOpener.open) {
        self.opener = opener
    }

    nonisolated static func configure(_ configuration: inout Ghostty.SurfaceConfiguration, pane: UUID) {
        configuration.environmentVariables[paneEnvironmentKey] = pane.uuidString
    }

    var waiterCount: Int { waiters.count }

    func start(path: String = OMGControlSocketPath.path()) {
        do {
            try server.start(path: path) { [weak self] frame, connection in
                Task { @MainActor in self?.handle(frame, from: connection) }
            }
        } catch OMGControlServer.Failure.alreadyListening {
            // A second instance of this channel keeps the first one's socket.
            Self.logger.info("control socket is owned by another running instance")
        } catch {
            Self.logger.error("control socket unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        server.stop()
        waiters.removeAll()
    }

    func handle(_ frame: Data, from connection: OMGControlConnection) {
        let request: OMGControlRequest
        switch OMGControlFrame.decodeRequest(frame) {
        case .failure(let response):
            connection.send(response.frame())
            return
        case .success(let value):
            request = value
        }
        let open: OMGControlOpenRequest
        do {
            guard let method = OMGControlProtocol.Method(rawValue: request.method) else {
                throw OMGControlError.methodNotFound(request.method)
            }
            open = try OMGControlOpenRequest(method: method, params: request.params)
        } catch {
            let failure = error as? OMGControlError ?? .invalidParams("Invalid parameters")
            connection.send(OMGControlResponse.failure(request.id, failure).frame())
            return
        }
        // One open at a time: starting a second load in the same editor
        // cancels a first that is still reading its file.
        let previous = openChain
        openChain = Task { [weak self] in
            await previous?.value
            await self?.perform(open, id: request.id, connection: connection)
        }
    }

    private func perform(_ request: OMGControlOpenRequest, id: OMGControlID, connection: OMGControlConnection) async {
        switch await opener(request) {
        case .failure(let error):
            connection.send(OMGControlResponse.failure(id, error).frame())
        case .success(.url):
            connection.send(OMGControlResponse.success(id, ["status": "opened"]).frame())
        case .success(.external(let path)):
            connection.send(OMGControlResponse.success(id, ["status": "external", "path": path]).frame())
        case .success(.document(let workspace, let document)):
            guard request.wait else {
                connection.send(OMGControlResponse.success(id, ["status": "opened", "path": document.path]).frame())
                return
            }
            wait(for: document, in: workspace, connection: connection) {
                connection.send(OMGControlResponse.success(id, ["status": "closed", "path": document.path]).frame())
            }
        }
    }

    /// Holds the reply until `document` leaves `workspace`, or drops it when
    /// the client goes away first.
    private func wait(
        for document: EditorDocumentID,
        in workspace: EditorWorkspace,
        connection: OMGControlConnection,
        finish: @escaping () -> Void
    ) {
        let token = UUID()
        let key = ObjectIdentifier(workspace)
        waiters[token] = Waiter(workspace: key, document: document, finish: finish)
        workspace.onDocumentRemoved = { [weak self] removed in
            self?.finishWaiters(in: key) { $0 == removed.id }
        }
        // Closing the pane or tab closes every document in it.
        workspace.onWorkspaceCleared = { [weak self] in
            self?.finishWaiters(in: key) { _ in true }
        }
        connection.onClose { [weak self] in
            Task { @MainActor in self?.waiters.removeValue(forKey: token) }
        }
    }

    private func finishWaiters(in workspace: ObjectIdentifier, where matches: (EditorDocumentID) -> Bool) {
        for (token, waiter) in waiters where waiter.workspace == workspace && matches(waiter.document) {
            waiters.removeValue(forKey: token)
            waiter.finish()
        }
    }
}

/// Carries an open request out against the live terminal windows.
@MainActor
enum OMGControlEditorOpener {
    static let loadTimeout: Duration = .seconds(30)

    static func open(_ request: OMGControlOpenRequest) async -> Result<OMGControlOpenOutcome, OMGControlError> {
        switch request.target {
        case .url(let value):
            return openURL(value)
        case .file(let path, let location):
            return await openFile(path: path, location: location, request: request)
        }
    }

    private static func openURL(_ value: String) -> Result<OMGControlOpenOutcome, OMGControlError> {
        let target = UntrustedURL(value)
        switch target.decision {
        case .allow(let url):
            return NSWorkspace.shared.open(url) ? .success(.url) : .failure(.failed("Could not open \(value)"))
        case .confirm(let url):
            UntrustedURLAlert.presentConfirmation(for: url, displayString: target.displayString)
            return .success(.url)
        case .deny(let reason):
            return .failure(.failed(reason.message))
        }
    }

    private static func openFile(
        path: String,
        location: EditorTextLocation?,
        request: OMGControlOpenRequest
    ) async -> Result<OMGControlOpenOutcome, OMGControlError> {
        guard let host = host(pane: request.pane, tab: request.tab, workingDirectory: request.workingDirectory) else {
            return .failure(.failed("OMG has no terminal window to open the file in"))
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard request.createsMissingFile else { return .failure(.failed("No such file: \(path)")) }
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                return .failure(.failed("Cannot create \(path)"))
            }
        } else if isDirectory.boolValue {
            return .failure(.failed("\(path) is a directory"))
        }

        let filesystem = LocalWorkspaceFilesystem(workingDirectory: request.workingDirectory)
        if EditorFileOpening.prefersDefaultApplication(path: path) {
            do {
                try await EditorFileOpening.openExternally(path: path, filesystem: filesystem)
                return .success(.external(path: path))
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }
        guard let documentID = try? EditorDocumentID(descriptor: filesystem.descriptor, path: path),
              let destination = EditorPaneDestination.open(
                  in: host.controller,
                  source: host.surface,
                  destination: request.destination ?? host.defaultDestination
              ) else {
            return .failure(.failed("Could not open an editor pane for \(path)"))
        }
        let workspace = EditorWorkspaceStore.shared.workspace(
            for: destination.controller.tabSessionID,
            surfaceID: destination.surface.id
        )
        workspace.open(path: path, filesystem: filesystem, location: location, externalFallback: true)

        let deadline = ContinuousClock.now + loadTimeout
        while workspace.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if workspace.documents.contains(where: { $0.id == documentID }) {
            focusEditor(workspace)
            return .success(.document(workspace: workspace, id: documentID))
        }
        if workspace.isLoading { return .failure(.failed("Timed out opening \(path)")) }
        if let message = workspace.errorMessage { return .failure(.failed(message)) }
        // The editor passed a binary or oversized file to its default app.
        return .success(.external(path: path))
    }

    /// The caller asked for an editor, so typing should land in it rather
    /// than in the terminal the command was run from. The editor view mounts
    /// a moment after the document loads; this never delays the reply.
    private static func focusEditor(_ workspace: EditorWorkspace) {
        Task { @MainActor [weak workspace] in
            for _ in 0..<40 {
                guard let workspace, workspace.isVisible else { return }
                if workspace.workbenchController.webView?.window != nil {
                    workspace.workbenchController.focus()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private struct Host {
        let controller: TerminalController
        let surface: Ghostty.SurfaceView
        let defaultDestination: EditorOpenDestination
    }

    /// The calling pane when it can be identified, then the calling tab, then
    /// the frontmost terminal window.
    private static func host(pane: UUID?, tab: UUID?, workingDirectory: String) -> Host? {
        let configured = OhMyGhosttySettings.shared.editorFileOpenDestination
        if let pane, let (surface, owner) = TerminalHostLookup.surfaceAndHost(for: pane) {
            if let controller = owner as? TerminalController {
                return Host(controller: controller, surface: surface, defaultDestination: configured)
            }
            // The Quick Terminal has no editor of its own; it borrows a window.
            if let resolution = owner.resolveEditorHost(workingDirectory: workingDirectory),
               let surface = resolution.controller.focusedSurface ?? resolution.controller.surfaceTree.first {
                return Host(
                    controller: resolution.controller,
                    surface: surface,
                    defaultDestination: resolution.createdNewWindow ? .currentPane : configured
                )
            }
        }
        let controllers = TerminalFocusRouter.allTerminalControllers()
        let controller = tab.flatMap { id in controllers.first(where: { $0.tabSessionID == id }) }
            ?? TerminalController.preferredParent
        guard let controller, let surface = controller.focusedSurface ?? controller.surfaceTree.first else {
            return nil
        }
        return Host(controller: controller, surface: surface, defaultDestination: configured)
    }
}
