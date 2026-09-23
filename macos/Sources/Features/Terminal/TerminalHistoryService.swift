import AppKit
import Foundation
import GhosttyKit

@MainActor
final class TerminalHistoryService {
    static let shared = TerminalHistoryService()

    enum JumpResult: Equatable {
        case jumped
        case unavailable
        case wrongSession
        case expired
    }

    private struct Session {
        let connectionID: String?
        let epoch: UUID
    }
    private var sessions: [UUID: Session] = [:]
    private let commandSource: ((UUID) -> [InspectorHistoryItem])?

    /// The injected source is also the test seam; there is no second history store.
    init(commandSource: ((UUID) -> [InspectorHistoryItem])? = nil) {
        self.commandSource = commandSource
    }

    static func connectionID(_ context: PaneSessionContext) -> String? {
        switch context.state {
        case .local: nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _): ssh.connectionID
        }
    }

    /// Called on canonical session transitions, including when Info is hidden.
    /// A new remote connection (or return to local) starts a new navigation epoch.
    func synchronizeSession(_ context: PaneSessionContext, in view: Ghostty.SurfaceView) {
        synchronizeSession(surfaceID: view.id, connectionID: Self.connectionID(context)) {
            guard let surface = view.surface else { return }
            ghostty_surface_omg_clear_commands(surface)
        }
    }

    @discardableResult
    func synchronizeSession(surfaceID: UUID, connectionID: String?, clear: () -> Void) -> UUID {
        if let session = sessions[surfaceID], session.connectionID == connectionID { return session.epoch }
        // First observation of a local pane can retain commands already captured.
        // First observation of a remote pane must not inherit an unknown host's rows.
        if sessions[surfaceID] != nil || connectionID != nil { clear() }
        let epoch = UUID()
        sessions[surfaceID] = .init(connectionID: connectionID, epoch: epoch)
        return epoch
    }

    func removeSurface(_ surfaceID: UUID) { sessions.removeValue(forKey: surfaceID) }

    private final class CommandSnapshot {
        var items: [InspectorHistoryItem] = []
        let surfaceID: UUID
        let epoch: UUID
        init(surfaceID: UUID, epoch: UUID) {
            self.surfaceID = surfaceID
            self.epoch = epoch
        }
    }

    func commands(for surfaceID: UUID) -> [InspectorHistoryItem] {
        if let commandSource { return commandSource(surfaceID) }
        for controller in TerminalController.all {
            guard let view = controller.surfaceTree.first(where: { $0.id == surfaceID }),
                  let surface = view.surface else { continue }
            if let context = controller.paneSessionContext(for: view) {
                synchronizeSession(context, in: view)
            }
            guard let epoch = sessions[surfaceID]?.epoch else { return [] }
            let snapshot = CommandSnapshot(surfaceID: surfaceID, epoch: epoch)
            ghostty_surface_omg_commands(surface, Unmanaged.passUnretained(snapshot).toOpaque()) { context, id, text, timestamp in
                guard let context, let text else { return }
                let snapshot = Unmanaged<CommandSnapshot>.fromOpaque(context).takeUnretainedValue()
                snapshot.items.append(.init(
                    id: "command:\(snapshot.surfaceID):\(snapshot.epoch):\(id)",
                    kind: .command, text: String(cString: text),
                    timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                    location: .command(surfaceID: snapshot.surfaceID, executionID: id, epoch: snapshot.epoch)
                ))
            }
            return snapshot.items.reversed()
        }
        return []
    }

    func validate(_ location: HistoryLocation, surfaceID: UUID) -> JumpResult? {
        guard case .command(let owner, _, let epoch) = location else { return .unavailable }
        guard owner == surfaceID, sessions[surfaceID]?.epoch == epoch else { return .wrongSession }
        return nil
    }

    @discardableResult
    func jump(to item: InspectorHistoryItem, in view: Ghostty.SurfaceView) -> JumpResult {
        if let result = validate(item.location, surfaceID: view.id) { return result }
        guard case .command(_, let id, _) = item.location,
              let surface = view.surface else { return .expired }
        guard ghostty_surface_omg_jump_command(surface, id) else { return .expired }
        Ghostty.moveFocus(to: view, from: nil)
        return .jumped
    }
}
