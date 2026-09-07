import Foundation

@MainActor
protocol GitTerminalSurfaceTarget: AnyObject {
    var id: UUID { get }

    /// Sends terminal text and reports whether a live surface model exists.
    func sendText(_ text: String) -> Bool
}

extension Ghostty.SurfaceView: GitTerminalSurfaceTarget {
    @MainActor
    func sendText(_ text: String) -> Bool {
        guard let surfaceModel else { return false }
        surfaceModel.sendText(text)
        return true
    }
}

enum GitTerminalDispatchFailure: Equatable, Sendable {
    case missingSurfaceID
    case surfaceNotFound(tabID: UUID, surfaceID: UUID)
    case surfaceModelUnavailable(tabID: UUID, surfaceID: UUID)
    case targetContextMismatch

    var displayMessage: String {
        switch self {
        case .missingSurfaceID:
            "Git command could not find the selected terminal surface."
        case .surfaceNotFound:
            "Git command target is no longer available."
        case .surfaceModelUnavailable:
            "Git command target is still starting."
        case .targetContextMismatch:
            "Git command target does not match this terminal session."
        }
    }
}

enum GitTerminalDispatchResult: Equatable, Sendable {
    case sent(command: String)
    case failed(GitTerminalDispatchFailure)

    var displayMessage: String? {
        if case .failed(let failure) = self { return failure.displayMessage }
        return nil
    }
}

/// Routes a formatted Git command to the exact Surface represented by an
/// inspector context. It deliberately does not synthesize an Enter key event.
@MainActor
final class GitTerminalBridge {
    typealias SurfaceLookup = @MainActor (UUID, UUID) -> (any GitTerminalSurfaceTarget)?
    typealias FocusSurface = @MainActor (any GitTerminalSurfaceTarget) -> Void

    private let surfaceLookup: SurfaceLookup
    private let focusSurface: FocusSurface

    init(
        surfaceLookup: @escaping SurfaceLookup = GitTerminalBridge.liveSurface,
        focusSurface: @escaping FocusSurface = GitTerminalBridge.focusLiveSurface
    ) {
        self.surfaceLookup = surfaceLookup
        self.focusSurface = focusSurface
    }

    func dispatch(
        _ intent: GitTerminalCommandIntent,
        in context: InspectorPaneContext
    ) -> GitTerminalDispatchResult {
        guard Self.isCompatible(intent.repository.target, with: context.session) else {
            return .failed(.targetContextMismatch)
        }

        guard let surfaceID = context.surfaceID else {
            return .failed(.missingSurfaceID)
        }

        guard let surface = surfaceLookup(context.tabID, surfaceID) else {
            return .failed(.surfaceNotFound(tabID: context.tabID, surfaceID: surfaceID))
        }

        let command = GitTerminalCommandFormatter.format(intent)
        focusSurface(surface)
        guard surface.sendText(command.shellCommand) else {
            return .failed(.surfaceModelUnavailable(tabID: context.tabID, surfaceID: surfaceID))
        }
        return .sent(command: command.shellCommand)
    }

    private static func isCompatible(
        _ target: GitExecutionTarget,
        with session: PaneSessionContext
    ) -> Bool {
        switch (target, session.state) {
        case (.local, .local):
            return true
        case (.remote(let host, let user), .sshReady(let ssh, _)):
            let hostMatches = host == ssh.alias || host == ssh.transferTarget
            let userMatches: Bool
            if let user {
                userMatches = ssh.transferTarget.hasPrefix("\(user)@")
            } else {
                userMatches = true
            }
            return hostMatches && userMatches
        default:
            return false
        }
    }

    private static func liveSurface(
        tabID: UUID,
        surfaceID: UUID
    ) -> (any GitTerminalSurfaceTarget)? {
        for controller in TerminalController.all where controller.tabSessionID == tabID {
            if let surface = controller.surfaceTree.first(where: { $0.id == surfaceID }) {
                return surface
            }
        }
        return nil
    }

    private static func focusLiveSurface(_ target: any GitTerminalSurfaceTarget) {
        guard let surface = target as? Ghostty.SurfaceView,
              let controller = BaseTerminalController.controller(owning: surface) else {
            return
        }
        controller.focusSurface(surface)
    }
}
