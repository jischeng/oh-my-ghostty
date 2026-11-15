import AppKit
import Foundation
import GhosttyKit

struct EditorHostResolution {
    let controller: TerminalController
    let createdNewWindow: Bool
}

/// Fork-owned host capability protocol allowing both standard `TerminalController`
/// windows and `QuickTerminalController` panels to participate in file-link hover/click,
/// safe directory navigation, command history queries, and editor handoff.
@MainActor
protocol TerminalHostProviding: AnyObject {
    var ghostty: Ghostty.App { get }
    var hostTabSessionID: UUID { get }
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get }

    func paneSessionContext(for surface: Ghostty.SurfaceView?) -> PaneSessionContext?
    func hasActivePaneAgent(for surface: Ghostty.SurfaceView) -> Bool
    func resolveEditorHost(workingDirectory: String?) -> EditorHostResolution?
    func navigateToDirectory(
        _ path: String,
        from surface: Ghostty.SurfaceView,
        session: PaneSessionContext,
        destination: EditorOpenDestination
    ) throws
}

extension TerminalHostProviding {
    func resolveEditorHostController(workingDirectory: String?) -> TerminalController? {
        resolveEditorHost(workingDirectory: workingDirectory)?.controller
    }
}

@MainActor
enum TerminalHostLookup {
    static func host(owning surface: Ghostty.SurfaceView) -> (any TerminalHostProviding)? {
        if let controller = BaseTerminalController.controller(owning: surface) as? any TerminalHostProviding {
            return controller
        }
        if let controller = TerminalFocusRouter.controller(owning: surface) as? any TerminalHostProviding {
            return controller
        }
        return surface.window?.windowController as? any TerminalHostProviding
    }

    static func surfaceAndHost(for surfaceID: UUID) -> (Ghostty.SurfaceView, any TerminalHostProviding)? {
        for controller in TerminalFocusRouter.allTerminalControllers() {
            if let view = controller.surfaceTree.first(where: { $0.id == surfaceID }) {
                return (view, controller)
            }
        }
        if let quick = (NSApp.delegate as? AppDelegate)?.quickControllerIfInitialized,
           let view = quick.surfaceTree.first(where: { $0.id == surfaceID }) {
            return (view, quick)
        }
        if let view = BaseTerminalController.surface(withID: surfaceID),
           let host = host(owning: view) {
            return (view, host)
        }
        return nil
    }
}

extension TerminalController: TerminalHostProviding {
    var hostTabSessionID: UUID { tabSessionID }

    func hasActivePaneAgent(for surface: Ghostty.SurfaceView) -> Bool {
        agentActivity(for: surface) != nil || agentResumeDescriptor(for: surface) != nil
    }

    func resolveEditorHost(workingDirectory: String?) -> EditorHostResolution? {
        EditorHostResolution(controller: self, createdNewWindow: false)
    }

    func navigateToDirectory(
        _ path: String,
        from surface: Ghostty.SurfaceView,
        session: PaneSessionContext,
        destination: EditorOpenDestination
    ) throws {
        if destination == .currentPane {
            guard !surface.blocksProgrammaticInput, let terminal = surface.surfaceModel else { return }
            EditorWorkspaceStore.shared.workspace(for: tabSessionID, surfaceID: surface.id).isVisible = false
            focusedSurface = surface
            surface.window?.makeFirstResponder(surface)
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
        _ = EditorPaneDestination.open(
            in: self,
            source: surface,
            destination: destination,
            configuration: configuration
        )
    }
}

extension QuickTerminalController: TerminalHostProviding {
    private static let fallbackTabSessionID = UUID(uuidString: "04670000-0000-4000-8000-000000000000")!

    var hostTabSessionID: UUID {
        surfaceTree.first?.id ?? Self.fallbackTabSessionID
    }

    func paneSessionContext(for surface: Ghostty.SurfaceView?) -> PaneSessionContext? {
        guard let surface else { return nil }
        let directory = surface.pwd
            ?? surface.runtimeDescriptor?.launchWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return PaneSessionContext(
            workingDirectory: directory,
            terminalTitle: surface.title
        )
    }

    func hasActivePaneAgent(for surface: Ghostty.SurfaceView) -> Bool {
        false
    }

    func resolveEditorHost(workingDirectory: String?) -> EditorHostResolution? {
        prepareForInternalWindowHandoff()
        let resolution: EditorHostResolution
        if let existing = Self.frontmostOpenTerminalController() {
            resolution = EditorHostResolution(controller: existing, createdNewWindow: false)
        } else {
            var config = Ghostty.SurfaceConfiguration()
            if let workingDirectory, !workingDirectory.isEmpty {
                config.workingDirectory = workingDirectory
            }
            let created = TerminalController.newWindow(ghostty, withBaseConfig: config)
            resolution = EditorHostResolution(controller: created, createdNewWindow: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        Self.presentEditorHostWindow(resolution.controller)
        if visible {
            animateOut()
            resolution.controller.window?.makeKeyAndOrderFront(nil)
        }
        return resolution
    }

    func navigateToDirectory(
        _ path: String,
        from surface: Ghostty.SurfaceView,
        session: PaneSessionContext,
        destination: EditorOpenDestination
    ) throws {
        if destination == .currentPane {
            guard !surface.blocksProgrammaticInput, let terminal = surface.surfaceModel else { return }
            focusedSurface = surface
            surface.window?.makeFirstResponder(surface)
            terminal.sendKeyEvent(.init(key: .e, mods: .ctrl))
            terminal.sendKeyEvent(.init(key: .u, mods: .ctrl))
            terminal.sendText(TerminalPathTarget.directoryCommand(path))
            terminal.sendKeyEvent(.init(key: .enter))
            return
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch destination {
        case .splitDown, .splitUp, .splitLeft, .splitRight:
            splitDirection = destination.splitDirection
        case .currentPane, .newTab:
            splitDirection = .right
        }
        _ = newSplit(at: surface, direction: splitDirection, baseConfig: config)
    }

    static func isEligibleEditorHost(_ controller: TerminalController) -> Bool {
        guard let window = controller.window else { return false }
        return (window.isVisible || window.isMiniaturized)
            && !controller.workspacePresentationIsParked
            && !controller.surfaceTree.isEmpty
    }

    static func frontmostOpenTerminalController() -> TerminalController? {
        for window in NSApp.orderedWindows {
            if let controller = window.windowController as? TerminalController,
               isEligibleEditorHost(controller) {
                return controller
            }
        }
        if let preferred = TerminalController.preferredParent, isEligibleEditorHost(preferred) {
            return preferred
        }
        return TerminalController.all.first(where: isEligibleEditorHost)
    }

    private static func presentEditorHostWindow(_ controller: TerminalController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Optional persistent local `omgd` session support for `QuickTerminalController`.
enum QuickTerminalRuntimeSupport {
    static let dedicatedPaneID = UUID(uuidString: "04670000-0000-4000-8000-000000000001")!

    nonisolated static func hasLiveLocalSession(
        pane: UUID,
        descriptor: SessionRuntimeDescriptor,
        applicationSupportRoot: URL? = nil,
        homeDirectory: URL? = nil
    ) -> Bool {
        guard descriptor.isLocal else { return false }
        let stateDir = SessionRuntimeConnections.localStateDirectory(
            for: descriptor,
            applicationSupportRoot: applicationSupportRoot,
            homeDirectory: homeDirectory
        )
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        let id = pane.uuidString.lowercased()
        if FileManager.default.fileExists(atPath: sessionsDir.appendingPathComponent("\(id).closed").path) {
            return false
        }
        let recordURL = sessionsDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: recordURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let ended = json["ended"], !(ended is NSNull) {
            return (ended as? String) == "lost"
        }
        if let exited = json["exited"] as? Bool, exited {
            return false
        }
        return true
    }

    struct EnvironmentContext {
        var resources: URL? = Bundle.main.resourceURL
        var applicationSupportRoot: URL?
        var homeDirectory: URL?
        var isRunningTests: Bool = OMGApplicationEnvironment.isRunningTests
    }

    @MainActor
    @discardableResult
    static func prepareInitialConfiguration(
        _ config: inout Ghostty.SurfaceConfiguration,
        settings: OhMyGhosttySettings = .shared,
        environment: EnvironmentContext = .init()
    ) -> UUID? {
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        guard SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
            &config,
            policy: settings.runtimePolicy,
            enabled: settings.quickTerminalRuntimeEnabled,
            resources: environment.resources,
            isRunningTests: environment.isRunningTests
        ),
        let encoded = config.environmentVariables[SessionRuntimeDescriptor.environmentKey],
        let descriptor = try? JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(encoded.utf8)) else {
            return nil
        }

        if hasLiveLocalSession(
            pane: dedicatedPaneID,
            descriptor: descriptor,
            applicationSupportRoot: environment.applicationSupportRoot,
            homeDirectory: environment.homeDirectory
        ) {
            config.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] = "1"
        }
        return dedicatedPaneID
    }

    @MainActor
    @discardableResult
    static func prepareSplitConfiguration(
        _ config: inout Ghostty.SurfaceConfiguration,
        settings: OhMyGhosttySettings = .shared,
        resources: URL? = Bundle.main.resourceURL,
        isRunningTests: Bool = OMGApplicationEnvironment.isRunningTests
    ) -> Bool {
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        return SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
            &config,
            policy: settings.runtimePolicy,
            enabled: settings.quickTerminalRuntimeEnabled,
            resources: resources,
            isRunningTests: isRunningTests
        )
    }
}
