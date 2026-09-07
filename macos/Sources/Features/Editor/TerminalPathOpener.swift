import AppKit

/// A terminal path is resolved against the clicked pane, never the process cwd.
enum TerminalPathTarget {
    static func isCandidate(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("file:") { return true }
        let path = value.replacingOccurrences(of: ":\\d+(?::\\d+)?$", with: "", options: .regularExpression)
        return URLComponents(string: path)?.scheme == nil
    }

    static func path(_ value: String, directory: String, isRemote: Bool) -> String? {
        guard !value.isEmpty, value.utf8.count <= 16_384 else { return nil }
        var value = value
        if value.count >= 2, let first = value.first,
           first == "'" || first == "\"", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        let path: String
        if value.lowercased().hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            // A file link never creates a connection to another machine.
            if !isRemote, let host = url.host, !host.isEmpty, host != "localhost" {
                let local = ProcessInfo.processInfo.hostName.lowercased()
                guard host.lowercased() == local || host.lowercased() == local.components(separatedBy: ".")[0]
                    || host.lowercased() == local + ".local" else { return nil }
            }
            path = url.path
        } else {
            let withoutLocation = value.replacingOccurrences(
                of: ":\\d+(?::\\d+)?$", with: "", options: .regularExpression
            )
            guard URLComponents(string: withoutLocation)?.scheme == nil else { return nil }
            path = withoutLocation
        }
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        if path.hasPrefix("~/") || path == "~" {
            guard !isRemote else { return nil }
            return (path as NSString).expandingTildeInPath
        }
        if path.hasPrefix("/") { return path }
        // An empty base explicitly means the clicked output's cwd is no longer known.
        guard !directory.isEmpty else { return nil }
        return (directory as NSString).appendingPathComponent(path)
    }

    static func directoryCommand(_ path: String) -> String {
        "cd -- '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
enum TerminalPathOpener {
    /// Return true for file candidates even when absent, so prose cannot reach Launch Services.
    static func open(_ value: String, from source: Ghostty.SurfaceView, baseDirectory: String? = nil) -> Bool {
        guard TerminalPathTarget.isCandidate(value) else { return false }
        guard let controller = source.window?.windowController as? TerminalController,
              let session = controller.paneSessionContext(for: source) else { return true }
        if case .sshConnecting = session.state { return true }
        let context = InspectorPaneContext(
            tabID: controller.tabSessionID, surfaceID: source.id, title: session.presentationTitle,
            workingDirectory: session.workingDirectory, workspace: session.workspace, session: session
        )
        let filesystem = WorkspaceFilesystemFactory.make(for: context)
        let directory = baseDirectory.map { value in
            value.hasPrefix("file:") ? (URL(string: value)?.path ?? "") : value
        } ?? filesystem.descriptor.workingDirectory
        guard let path = TerminalPathTarget.path(value, directory: directory,
                                                 isRemote: filesystem.descriptor.kind == .ssh) else { return true }
        Task { [weak controller, weak source] in
            do {
                guard let kind = try await filesystem.itemType(at: path),
                      let controller, let source, source.surface != nil,
                      controller.surfaceTree.first(where: { $0.id == source.id }) != nil,
                      controller.paneSessionContext(for: source)?.state == session.state else { return }
                switch kind {
                case .file:
                    EditorWorkspaceStore.shared.open(path: path, context: context)
                case .directory:
                    try openDirectory(path, controller: controller, source: source, session: session)
                }
            } catch {
                guard let controller, let source else { return }
                let workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: source.id)
                workspace.errorMessage = error.localizedDescription
                workspace.isVisible = true
            }
        }
        return true
    }

    private static func openDirectory(
        _ path: String, controller: TerminalController, source: Ghostty.SurfaceView, session: PaneSessionContext
    ) throws {
        let destination = OhMyGhosttySettings.shared.editorDirectoryOpenDestination
        if destination == .currentPane {
            guard let terminal = source.surfaceModel else { return }
            EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: source.id).isVisible = false
            controller.focusedSurface = source
            source.window?.makeFirstResponder(source)
            // Move to the end and clear any partial shell input before changing directory.
            terminal.sendKeyEvent(.init(key: .e, mods: .ctrl))
            terminal.sendKeyEvent(.init(key: .u, mods: .ctrl))
            terminal.sendText(TerminalPathTarget.directoryCommand(path))
            terminal.sendKeyEvent(.init(key: .enter))
            return
        }

        var configuration = Ghostty.SurfaceConfiguration()
        switch session.state {
        case .local:
            configuration.workingDirectory = path
        case .sshReady(let ssh, _):
            guard let replay = ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID),
                  let executable = Bundle.main.executableURL?.path,
                  let command = replay.command(executablePath: executable, remoteWorkingDirectory: path) else {
                throw WorkspaceFilesystemError.operationFailed("This SSH session cannot be opened in another pane.")
            }
            configuration.workingDirectory = session.local.workingDirectory
            configuration.command = TerminalController.replaySurvivalCommand(command)
        case .sshConnecting:
            return
        }
        _ = EditorPaneDestination.open(in: controller, source: source, destination: destination, configuration: configuration)
    }
}

@MainActor
enum EditorPaneDestination {
    static func open(
        in controller: TerminalController, source: Ghostty.SurfaceView, destination: EditorOpenDestination,
        configuration: Ghostty.SurfaceConfiguration? = nil
    ) -> (controller: TerminalController, surface: Ghostty.SurfaceView)? {
        controller.focusedSurface = source
        let targetController: TerminalController
        let target: Ghostty.SurfaceView
        switch destination {
        case .currentPane:
            targetController = controller
            target = source
        case .newTab:
            guard let created = TerminalController.newTab(controller.ghostty, from: controller.window,
                                                          withBaseConfig: configuration),
                  let surface = created.surfaceTree.first else { return nil }
            targetController = created
            target = surface
        case .splitRight, .splitDown, .splitLeft, .splitUp:
            let created: Ghostty.SurfaceView?
            if let configuration {
                created = controller.newDirectorySplit(at: source, direction: destination.splitDirection, configuration: configuration)
            } else {
                created = controller.newSplit(at: source, direction: destination.splitDirection)
            }
            guard let surface = created else { return nil }
            targetController = controller
            target = surface
        }
        targetController.focusedSurface = target
        return (targetController, target)
    }
}

extension TerminalController {
    /// The directory opener already supplied a local cwd or an SSH replay command.
    func newDirectorySplit(
        at source: Ghostty.SurfaceView, direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        configuration: Ghostty.SurfaceConfiguration
    ) -> Ghostty.SurfaceView? {
        super.newSplit(at: source, direction: direction,
                       baseConfig: Self.injectingSessionID(tabSessionID, into: configuration))
    }
}
