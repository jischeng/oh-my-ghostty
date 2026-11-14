import AppKit
import GhosttyKit

/// A terminal path is resolved against the clicked pane, never the process cwd.
enum TerminalPathTarget {
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

    private static func isPureAnchorFragment(_ path: String) -> Bool {
        path.hasPrefix("#") && !(path.count >= 3 && path.hasSuffix("#"))
    }

    static func isCandidate(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("file:") { return true }
        let unquoted = stripMatchingQuotes(value)
        let path = splitLocationSuffix(from: unquoted).path
        guard !path.isEmpty, !isPureAnchorFragment(path) else { return false }
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
            // A prose full stop or bare `#heading` fragment must not become a file link.
            // Explicit paths such as ./ and ./README.md and Emacs #autosave# remain valid.
            guard withoutLocation != ".", !isPureAnchorFragment(withoutLocation) else { return nil }
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
        var cleanRelative = path
        while cleanRelative.hasPrefix("./"), cleanRelative.count > 2 {
            cleanRelative.removeFirst(2)
        }
        return ((directory as NSString).appendingPathComponent(cleanRelative), location)
    }

    private static func splitLocationSuffix(from value: String) -> (path: String, location: EditorTextLocation?) {
        if let hashIndex = value.lastIndex(of: "#"),
           hashIndex > value.startIndex,
           value[value.index(before: hashIndex)] != "/" {
            let prefix = String(value[..<hashIndex])
            let fragment = String(value[value.index(after: hashIndex)...])
            if !fragment.isEmpty, !fragment.contains("/"), prefix != ".", !prefix.hasSuffix("/.") {
                return (prefix, parseFragmentLocation(fragment))
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
        let host: any TerminalHostProviding
        var controller: TerminalController? { host as? TerminalController }
        let session: PaneSessionContext
        let context: InspectorPaneContext
        let filesystem: any WorkspaceFilesystem
        let path: String
        let location: EditorTextLocation?
    }

    /// Resolve a candidate against the source pane's local or SSH filesystem.
    /// Shared by Cmd-hover existence checks and Cmd-click so both agree.
    static func resolve(_ value: String, from source: Ghostty.SurfaceView, baseDirectory: String?) -> Resolved? {
        guard let host = TerminalHostLookup.host(owning: source),
              let session = host.paneSessionContext(for: source) else { return nil }
        if case .sshConnecting = session.state { return nil }
        let context = InspectorPaneContext(
            tabID: host.hostTabSessionID, surfaceID: source.id, title: session.presentationTitle,
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
            host: host, session: session, context: context,
            filesystem: filesystem, path: target.path, location: target.location
        )
    }

    static func open(_ value: String, from source: Ghostty.SurfaceView, baseDirectory: String? = nil) -> Bool {
        guard TerminalPathTarget.isCandidate(value) else { return false }
        guard let resolved = resolve(value, from: source, baseDirectory: baseDirectory) else { return true }
        let host = resolved.host
        let filesystem = resolved.filesystem
        let path = resolved.path
        Task { [weak host, weak source] in
            do {
                guard let kind = try await filesystem.itemType(at: path),
                      let host, let source else { return }
                try await performOpen(kind: kind, resolved: resolved, host: host, source: source)
            } catch {
                presentOpenError(error, host: host, source: source)
            }
        }
        return true
    }

    /// Deferred click handler for `omg_path` candidates whose async hover existence
    /// check has not finished yet when the user presses `Cmd+Click`.
    static func openFirstExisting(
        _ candidates: [String],
        from source: Ghostty.SurfaceView,
        baseDirectory: String?
    ) {
        guard !candidates.isEmpty else { return }
        let base = baseDirectory ?? ""
        Task { [weak source] in
            for candidate in candidates {
                guard !Task.isCancelled, let source, source.surface != nil else { return }
                guard TerminalPathTarget.isCandidate(candidate),
                      let resolved = resolve(candidate, from: source, baseDirectory: baseDirectory) else {
                    reportLinkChecked(candidate, baseDirectory: base, exists: false, to: source)
                    continue
                }
                let host = resolved.host
                let filesystem = resolved.filesystem
                let path = resolved.path
                do {
                    let kind = try await filesystem.itemType(at: path)
                    guard !Task.isCancelled else { return }
                    reportLinkChecked(candidate, baseDirectory: base, exists: kind != nil, to: source)
                    guard let kind else { continue }
                    try await performOpen(kind: kind, resolved: resolved, host: host, source: source)
                    return
                } catch {
                    presentOpenError(error, host: host, source: source)
                    return
                }
            }
        }
    }

    private static func reportLinkChecked(
        _ url: String,
        baseDirectory: String,
        exists: Bool,
        to source: Ghostty.SurfaceView
    ) {
        guard let surface = source.surface else { return }
        url.withCString { urlPtr in
            baseDirectory.withCString { basePtr in
                ghostty_surface_omg_link_checked(
                    surface,
                    urlPtr, UInt(url.utf8.count),
                    basePtr, UInt(baseDirectory.utf8.count),
                    exists
                )
            }
        }
        ghostty_surface_omg_link_checks_flush(surface)
    }

    private static func performOpen(
        kind: WorkspaceItemType,
        resolved: Resolved,
        host: any TerminalHostProviding,
        source: Ghostty.SurfaceView
    ) async throws {
        let session = resolved.session
        guard source.surface != nil,
              host.surfaceTree.first(where: { $0.id == source.id }) != nil,
              host.paneSessionContext(for: source)?.state == session.state else { return }
        switch kind {
        case .file:
            if host is TerminalController {
                EditorWorkspaceStore.shared.open(
                    path: resolved.path,
                    context: resolved.context,
                    location: resolved.location
                )
            } else {
                let parentDirectory = (resolved.path as NSString).deletingLastPathComponent
                guard let resolution = host.resolveEditorHost(workingDirectory: parentDirectory) else {
                    return
                }
                let editorController = resolution.controller
                let targetSurface = editorController.focusedSurface ?? editorController.surfaceTree.first
                let targetSession = editorController.paneSessionContext(for: targetSurface)
                    ?? PaneSessionContext(workingDirectory: parentDirectory, terminalTitle: targetSurface?.title ?? "")
                let targetContext = InspectorPaneContext(
                    tabID: editorController.tabSessionID,
                    surfaceID: targetSurface?.id,
                    title: targetSession.presentationTitle,
                    workingDirectory: parentDirectory,
                    workspace: nil,
                    session: .init(workingDirectory: parentDirectory, terminalTitle: targetSurface?.title ?? "")
                )
                EditorWorkspaceStore.shared.open(
                    path: resolved.path,
                    context: targetContext,
                    destination: resolution.createdNewWindow ? .currentPane : nil,
                    location: resolved.location
                )
            }
        case .directory:
            let isIdleShell = await isIdleInteractiveShell(source, session: session)
            guard !Task.isCancelled,
                  source.surface != nil,
                  host.surfaceTree.first(where: { $0.id == source.id }) != nil,
                  host.paneSessionContext(for: source)?.state == session.state else { return }
            let destination = directoryDestination(
                preferred: OhMyGhosttySettings.shared.editorDirectoryOpenDestination,
                hasAgent: host.hasActivePaneAgent(for: source),
                blocksProgrammaticInput: source.blocksProgrammaticInput,
                isIdleInteractiveShell: isIdleShell
            )
            try host.navigateToDirectory(
                resolved.path,
                from: source,
                session: session,
                destination: destination
            )
        }
    }

    private static func presentOpenError(
        _ error: Error,
        host: (any TerminalHostProviding)?,
        source: Ghostty.SurfaceView?
    ) {
        guard let host, let source else { return }
        let parentDirectory = source.pwd
        guard let controller = (host as? TerminalController)
                ?? host.resolveEditorHostController(workingDirectory: parentDirectory) else { return }
        let resolvedSurfaceID: UUID? = (host is TerminalController)
            ? source.id
            : (controller.focusedSurface?.id ?? controller.surfaceTree.first?.id)
        guard let targetSurfaceID = resolvedSurfaceID else { return }
        let workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: targetSurfaceID)
        workspace.errorMessage = error.localizedDescription
        workspace.isVisible = true
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
