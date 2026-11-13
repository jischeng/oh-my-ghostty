import AppKit

/// A terminal path is resolved against the clicked pane, never the process cwd.
enum TerminalPathTarget {
    private static let locationSuffixPattern =
        "(?::\\d+(?::\\d+)?(?:-L?\\d+(?::\\d+)?)?|#L?\\d+(?:C\\d+)?(?:-L?\\d+(?:C\\d+)?)?)$"

    private static let colonLocationRegex = try? NSRegularExpression(
        pattern: ":(\\d+)(?::(\\d+))?(?:-L?(\\d+)(?::(\\d+))?)?$"
    )
    private static let fragmentLocationRegex = try? NSRegularExpression(
        pattern: "^L?(\\d+)(?:C(\\d+))?(?:-L?(\\d+)(?:C(\\d+))?)?$",
        options: [.caseInsensitive]
    )

    private static func stripMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first,
              first == "'" || first == "\"" || first == "`", value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    static func isCandidate(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("file:") { return true }
        let unquoted = stripMatchingQuotes(value)
        let path = unquoted.replacingOccurrences(of: locationSuffixPattern, with: "", options: .regularExpression)
        if path.contains(" ") {
            return !path.contains("://")
        }
        return URLComponents(string: path)?.scheme == nil
    }

    static func path(_ value: String, directory: String, isRemote: Bool) -> String? {
        target(value, directory: directory, isRemote: isRemote)?.path
    }

    static func target(
        _ value: String,
        directory: String,
        isRemote: Bool
    ) -> (path: String, location: EditorTextLocation?)? {
        guard !value.isEmpty, value.utf8.count <= 16_384 else { return nil }
        let value = stripMatchingQuotes(value)
        let path: String
        let location: EditorTextLocation?
        if value.lowercased().hasPrefix("file:") {
            let resolvedURL = URL(string: value) ?? URL(string: value.replacingOccurrences(of: " ", with: "%20"))
            guard let url = resolvedURL, url.isFileURL else { return nil }
            // A file link never creates a connection to another machine.
            if !isRemote, let host = url.host, !host.isEmpty, host != "localhost" {
                let local = ProcessInfo.processInfo.hostName.lowercased()
                guard host.lowercased() == local || host.lowercased() == local.components(separatedBy: ".")[0]
                    || host.lowercased() == local + ".local" else { return nil }
            }
            path = url.path
            location = url.fragment.flatMap(parseFragmentLocation)
        } else {
            let extracted = splitLocationSuffix(from: value)
            let withoutLocation = extracted.path
            if withoutLocation.contains(" ") {
                guard !withoutLocation.contains("://") else { return nil }
            } else {
                guard URLComponents(string: withoutLocation)?.scheme == nil else { return nil }
            }
            // A prose full stop must not become a link to the pane's cwd.
            // Explicit paths such as ./ and ./README.md remain valid.
            guard withoutLocation != "." else { return nil }
            path = withoutLocation
            location = extracted.location
        }
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        if path.hasPrefix("~/") || path == "~" {
            guard !isRemote else { return nil }
            return ((path as NSString).expandingTildeInPath, location)
        }
        if path.hasPrefix("/") { return (path, location) }
        // An empty base explicitly means the clicked output's cwd is no longer known.
        guard !directory.isEmpty else { return nil }
        return ((directory as NSString).appendingPathComponent(path), location)
    }

    private static func splitLocationSuffix(from value: String) -> (path: String, location: EditorTextLocation?) {
        if let hashIndex = value.lastIndex(of: "#") {
            let fragment = String(value[value.index(after: hashIndex)...])
            if let location = parseFragmentLocation(fragment) {
                return (String(value[..<hashIndex]), location)
            }
        }
        let nsValue = value as NSString
        let fullRange = NSRange(location: 0, length: nsValue.length)
        if let match = colonLocationRegex?.firstMatch(in: value, range: fullRange),
           match.range.location > 0,
           let startLine = intGroup(1, in: match, source: nsValue), startLine > 0 {
            let column = intGroup(2, in: match, source: nsValue).flatMap { $0 > 0 ? $0 : nil }
            let endLine = intGroup(3, in: match, source: nsValue).flatMap { $0 > 0 ? $0 : nil }
            let prefix = nsValue.substring(to: match.range.location)
            return (prefix, EditorTextLocation(startLine: startLine, column: endLine == nil ? column : nil, endLine: endLine))
        }
        return (value, nil)
    }

    private static func parseFragmentLocation(_ fragment: String) -> EditorTextLocation? {
        let nsFragment = fragment as NSString
        let fullRange = NSRange(location: 0, length: nsFragment.length)
        guard let match = fragmentLocationRegex?.firstMatch(in: fragment, range: fullRange),
              let startLine = intGroup(1, in: match, source: nsFragment), startLine > 0 else {
            return nil
        }
        let column = intGroup(2, in: match, source: nsFragment).flatMap { $0 > 0 ? $0 : nil }
        let endLine = intGroup(3, in: match, source: nsFragment).flatMap { $0 > 0 ? $0 : nil }
        return EditorTextLocation(startLine: startLine, column: endLine == nil ? column : nil, endLine: endLine)
    }

    private static func intGroup(_ index: Int, in match: NSTextCheckingResult, source: NSString) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return Int(source.substring(with: range))
    }

    /// Core history contains local OSC7 directories, not remote shell/agent
    /// directories. Never use that local base for an SSH filesystem.
    static func baseDirectory(historical: String?, paneDirectory: String, isRemote: Bool) -> String {
        if isRemote { return paneDirectory }
        return historical.map { value in
            value.hasPrefix("file:") ? (URL(string: value)?.path ?? "") : value
        } ?? paneDirectory
    }

    static func directoryCommand(_ path: String) -> String {
        "cd -- '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
enum TerminalPathOpener {
    /// Return true for file candidates even when absent, so prose cannot reach Launch Services.
    struct Resolved {
        let controller: TerminalController
        let session: PaneSessionContext
        let context: InspectorPaneContext
        let filesystem: any WorkspaceFilesystem
        let path: String
        let location: EditorTextLocation?
    }

    /// Resolve a candidate against the source pane's local or SSH filesystem.
    /// Shared by Cmd-hover existence checks and Cmd-click so both agree.
    static func resolve(_ value: String, from source: Ghostty.SurfaceView, baseDirectory: String?) -> Resolved? {
        guard let controller = source.window?.windowController as? TerminalController,
              let session = controller.paneSessionContext(for: source) else { return nil }
        if case .sshConnecting = session.state { return nil }
        let context = InspectorPaneContext(
            tabID: controller.tabSessionID, surfaceID: source.id, title: session.presentationTitle,
            workingDirectory: session.workingDirectory, workspace: session.workspace, session: session
        )
        let filesystem = WorkspaceFilesystemFactory.make(for: context)
        let directory = TerminalPathTarget.baseDirectory(
            historical: baseDirectory,
            paneDirectory: filesystem.descriptor.workingDirectory,
            isRemote: filesystem.descriptor.kind == .ssh
        )
        guard let target = TerminalPathTarget.target(
            value, directory: directory, isRemote: filesystem.descriptor.kind == .ssh
        ) else { return nil }
        return .init(
            controller: controller, session: session, context: context,
            filesystem: filesystem, path: target.path, location: target.location
        )
    }

    static func open(_ value: String, from source: Ghostty.SurfaceView, baseDirectory: String? = nil) -> Bool {
        guard TerminalPathTarget.isCandidate(value) else { return false }
        guard let resolved = resolve(value, from: source, baseDirectory: baseDirectory) else { return true }
        let controller = resolved.controller, session = resolved.session
        let context = resolved.context, filesystem = resolved.filesystem
        let path = resolved.path, location = resolved.location
        Task { [weak controller, weak source] in
            do {
                guard let kind = try await filesystem.itemType(at: path),
                      let controller, let source, source.surface != nil,
                      controller.surfaceTree.first(where: { $0.id == source.id }) != nil,
                      controller.paneSessionContext(for: source)?.state == session.state else { return }
                switch kind {
                case .file:
                    EditorWorkspaceStore.shared.open(path: path, context: context, location: location)
                case .directory:
                    let isIdleShell = await isIdleInteractiveShell(source, session: session)
                    guard !Task.isCancelled,
                          source.surface != nil,
                          controller.surfaceTree.first(where: { $0.id == source.id }) != nil,
                          controller.paneSessionContext(for: source)?.state == session.state else { return }
                    try openDirectory(
                        path,
                        controller: controller,
                        source: source,
                        session: session,
                        isIdleInteractiveShell: isIdleShell
                    )
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

    private static let interactiveShellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "oksh",
        "pdksh", "tcsh", "csh", "nu", "nushell", "elvish", "xonsh", "pwsh",
    ]

    private static let shellFlagsTakingValue: Set<String> = [
        "--rcfile", "--init-file", "-o", "+o", "--option",
        "--init-command", "-C", "--config", "--env-config", "--plugin-config",
    ]

    /// A directory click must never submit shell commands to an agent's chat
    /// input, a password prompt, or an active non-shell foreground program.
    /// Preserve explicit destinations; use a sibling split for current-pane.
    nonisolated static func directoryDestination(
        preferred: EditorOpenDestination,
        hasAgent: Bool,
        blocksProgrammaticInput: Bool = false,
        isIdleInteractiveShell: Bool = true
    ) -> EditorOpenDestination {
        guard preferred == .currentPane else { return preferred }
        if hasAgent || blocksProgrammaticInput || !isIdleInteractiveShell {
            return .splitRight
        }
        return .currentPane
    }

    /// Returns true only when every foreground process in the PTY's foreground
    /// process group is an interactive shell (plus optional macOS `login` wrapper),
    /// with no script or `-c` command execution and no non-shell child program.
    nonisolated static func isInteractiveShellProcessGroup(_ commandLines: String) -> Bool {
        var foundInteractiveShell = false
        for rawLine in commandLines.split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = tokens.first else { continue }
            if isLoginWrapperExecutable(first) {
                continue
            }
            guard isInteractiveShellCommand(tokens: tokens) else {
                return false
            }
            foundInteractiveShell = true
        }
        return foundInteractiveShell
    }

    nonisolated private static func isLoginWrapperExecutable(_ executable: String) -> Bool {
        let trimmed = executable.hasPrefix("-") ? String(executable.dropFirst()) : executable
        return (trimmed as NSString).lastPathComponent.lowercased() == "login"
    }

    nonisolated private static func isInteractiveShellCommand(tokens: [String]) -> Bool {
        guard let executable = tokens.first else { return false }
        let trimmed = executable.hasPrefix("-") ? String(executable.dropFirst()) : executable
        let basename = (trimmed as NSString).lastPathComponent.lowercased()
        guard interactiveShellNames.contains(basename) else {
            return false
        }
        var index = 1
        while index < tokens.count {
            let arg = tokens[index]
            if arg == "--" {
                return index + 1 == tokens.count
            }
            if shellFlagsTakingValue.contains(arg) {
                index += 2
                continue
            }
            let lower = arg.lowercased()
            if lower == "--command" || lower == "--commands" || lower == "--execute" ||
                lower.hasPrefix("--command=") || lower.hasPrefix("--commands=") || lower.hasPrefix("--execute=") {
                return false
            }
            if arg.hasPrefix("--") {
                index += 1
                continue
            }
            if arg.hasPrefix("-") && arg.count > 1 {
                let cluster = arg.dropFirst()
                if cluster.contains("c") {
                    return false
                }
                if (basename == "nu" || basename == "nushell") && cluster.contains("e") {
                    return false
                }
                index += 1
                continue
            }
            if arg.hasPrefix("+") && arg.count > 1 {
                index += 1
                continue
            }
            // Positional script filename or non-option argument.
            return false
        }
        return true
    }

    private static func isIdleInteractiveShell(
        _ source: Ghostty.SurfaceView,
        session: PaneSessionContext
    ) async -> Bool {
        guard !source.blocksProgrammaticInput,
              !source.readonly,
              !source.processExited,
              source.surfaceModel?.mouseCaptured != true else {
            return false
        }
        switch session.state {
        case .local:
            guard let foregroundPID = source.surfaceModel?.foregroundPID else {
                return false
            }
            let commandLines = await Task.detached(priority: .userInitiated) {
                TerminalController.processGroupCommandLines(foregroundPID)
            }.value
            guard source.surfaceModel?.foregroundPID == foregroundPID,
                  !source.blocksProgrammaticInput,
                  source.surfaceModel?.mouseCaptured != true,
                  let commandLines else {
                return false
            }
            return isInteractiveShellProcessGroup(commandLines)
        case .sshReady:
            return true
        case .sshConnecting:
            return false
        }
    }

    private static func openDirectory(
        _ path: String,
        controller: TerminalController,
        source: Ghostty.SurfaceView,
        session: PaneSessionContext,
        isIdleInteractiveShell: Bool
    ) throws {
        let destination = directoryDestination(
            preferred: OhMyGhosttySettings.shared.editorDirectoryOpenDestination,
            hasAgent: controller.agentActivity(for: source) != nil || controller.agentResumeDescriptor(for: source) != nil,
            blocksProgrammaticInput: source.blocksProgrammaticInput,
            isIdleInteractiveShell: isIdleInteractiveShell
        )
        if destination == .currentPane {
            guard !source.blocksProgrammaticInput, let terminal = source.surfaceModel else { return }
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
