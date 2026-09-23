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
        let sourceLabel: String
    }
    private var sessions: [UUID: Session] = [:]
    private var archivedBySurface: [UUID: [InspectorHistoryItem]] = [:]
    private var skippedInitialSSHReplay = Set<UUID>()
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
    static func sourceLabel(_ context: PaneSessionContext) -> String {
        switch context.state {
        case .local: "Local"
        case .sshConnecting(let ssh): "SSH · \(ssh.alias)"
        case .sshReady(let ssh, _):
            if let serverID = ssh.serverID {
                "SSH · \(ssh.alias) · \(serverID.suffix(8))"
            } else {
                "SSH · \(ssh.alias)"
            }
        }
    }

    func initializeSession(_ context: PaneSessionContext, in view: Ghostty.SurfaceView) {
        guard sessions[view.id] == nil else { return }
        synchronizeSession(context, in: view)
    }

    func synchronizeSession(_ context: PaneSessionContext, in view: Ghostty.SurfaceView) {
        let saved = ShellScrollbackRestoreStore.savedCommands(for: view.id)
        let previous = sessions[view.id]
        let skipReplay = previous != nil && view.sshResumeDescriptor != nil && saved != nil &&
            !skippedInitialSSHReplay.contains(view.id)
        if skipReplay, previous?.connectionID != Self.connectionID(context) {
            // The startup wrapper replayed a prior display before opening the
            // new SSH transport. Its commands already live in the sidecar.
            skippedInitialSSHReplay.insert(view.id)
        }
        synchronizeSession(surfaceID: view.id, connectionID: Self.connectionID(context),
                           sourceLabel: Self.sourceLabel(context), captured: {
            guard !skipReplay, let previous, let surface = view.surface else { return [] }
            let rows = snapshotCommands(surface, surfaceID: view.id, epoch: previous.epoch,
                                        sourceLabel: previous.sourceLabel)
            return Self.excludingRestoredSuffix(rows, saved: saved,
                canReconcile: ShellScrollbackRestoreStore.allowsAnchorReconciliation(for: view.id))
        }, clear: {
            guard let surface = view.surface else { return }
            ghostty_surface_omg_clear_commands(surface)
        })
    }

    @discardableResult
    func synchronizeSession(
        surfaceID: UUID, connectionID: String?, sourceLabel: String = "Local",
        captured: () -> [InspectorHistoryItem] = { [] }, clear: () -> Void
    ) -> UUID {
        if let session = sessions[surfaceID], session.connectionID == connectionID {
            if session.sourceLabel != sourceLabel {
                sessions[surfaceID] = .init(connectionID: connectionID, epoch: session.epoch,
                                            sourceLabel: sourceLabel)
            }
            return session.epoch
        }
        if sessions[surfaceID] != nil {
            let expired = captured().map { item in
                InspectorHistoryItem(id: item.id, kind: .command, text: item.text,
                    timestamp: item.timestamp, location: .unavailable(.expired),
                    sourceLabel: item.sourceLabel)
            }
            archivedBySurface[surfaceID, default: []].append(contentsOf: expired)
            if let count = archivedBySurface[surfaceID]?.count, count > 100 {
                archivedBySurface[surfaceID]?.removeFirst(count - 100)
            }
        }
        // First observation of a local pane can retain commands already captured.
        // First observation of a remote pane must not inherit an unknown host's rows.
        if sessions[surfaceID] != nil || connectionID != nil { clear() }
        let epoch = UUID()
        sessions[surfaceID] = .init(connectionID: connectionID, epoch: epoch,
                                    sourceLabel: sourceLabel)
        return epoch
    }

    func archivedCommands(for surfaceID: UUID) -> [InspectorHistoryItem] {
        archivedBySurface[surfaceID] ?? []
    }

    func removeSurface(_ surfaceID: UUID) {
        sessions.removeValue(forKey: surfaceID)
        archivedBySurface.removeValue(forKey: surfaceID)
        skippedInitialSSHReplay.remove(surfaceID)
    }

    private final class CommandSnapshot {
        var items: [InspectorHistoryItem] = []
        let surfaceID: UUID
        let epoch: UUID
        let sourceLabel: String
        init(surfaceID: UUID, epoch: UUID, sourceLabel: String) {
            self.surfaceID = surfaceID
            self.epoch = epoch
            self.sourceLabel = sourceLabel
        }
    }

    private func snapshotCommands(
        _ surface: ghostty_surface_t, surfaceID: UUID, epoch: UUID, sourceLabel: String
    ) -> [InspectorHistoryItem] {
        let snapshot = CommandSnapshot(surfaceID: surfaceID, epoch: epoch, sourceLabel: sourceLabel)
        ghostty_surface_omg_commands(surface, Unmanaged.passUnretained(snapshot).toOpaque()) { context, id, text, timestamp in
            guard let context, let text else { return }
            let snapshot = Unmanaged<CommandSnapshot>.fromOpaque(context).takeUnretainedValue()
            snapshot.items.append(.init(
                id: "command:\(snapshot.surfaceID):\(snapshot.epoch):\(id)",
                kind: .command, text: String(cString: text),
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                location: .command(surfaceID: snapshot.surfaceID, executionID: id,
                                   epoch: snapshot.epoch), sourceLabel: snapshot.sourceLabel
            ))
        }
        return snapshot.items.reversed()
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
            let live = snapshotCommands(surface, surfaceID: surfaceID, epoch: epoch,
                                        sourceLabel: sessions[surfaceID]?.sourceLabel ?? "Local")
            let archived = archivedBySurface[surfaceID] ?? []
            let saved = ShellScrollbackRestoreStore.savedCommands(for: surfaceID)
            let combined = Self.presentingHistory(in: live + archived, from: saved,
                surfaceID: surfaceID,
                allowReconciliation: ShellScrollbackRestoreStore.allowsAnchorReconciliation(for: surfaceID))
            return combined.sorted { lhs, rhs in
                (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
            }
        }
        return []
    }

    static func excludingRestoredSuffix(
        _ items: [InspectorHistoryItem],
        saved: [ShellScrollbackRestoreStore.SavedCommand]?,
        canReconcile: Bool
    ) -> [InspectorHistoryItem] {
        guard canReconcile, let saved, !saved.isEmpty, items.count >= saved.count,
              zip(items.suffix(saved.count), saved).allSatisfy({
                  $0.text == $1.text && ($0.sourceLabel ?? "Local") == ($1.sourceLabel ?? "Local")
              }) else { return items }
        return Array(items.dropLast(saved.count))
    }

    /// Replay is best-effort: keep archived commands visible when the Shell
    /// redrew or pruned their pins, but never claim an unverified jump target.
    static func presentingHistory(
        in items: [InspectorHistoryItem],
        from saved: [ShellScrollbackRestoreStore.SavedCommand]?,
        surfaceID: UUID,
        allowReconciliation: Bool = true
    ) -> [InspectorHistoryItem] {
        guard let saved, !saved.isEmpty else { return items }
        if allowReconciliation, items.count >= saved.count,
           zip(items.suffix(saved.count), saved).allSatisfy({
               $0.text == $1.text && ($0.sourceLabel ?? "Local") == ($1.sourceLabel ?? "Local")
           }) {
            return restoringTimestamps(in: items, from: saved)
        }
        let archived = saved.enumerated().map { index, command in
            InspectorHistoryItem(
                id: "archived:\(surfaceID.uuidString):\(index)", kind: .command,
                text: command.text, timestamp: command.timestamp,
                location: .unavailable(.expired), sourceLabel: command.sourceLabel
            )
        }
        return items + archived
    }

    static func restoringTimestamps(
        in items: [InspectorHistoryItem],
        from saved: [ShellScrollbackRestoreStore.SavedCommand]?
    ) -> [InspectorHistoryItem] {
        guard let saved, !saved.isEmpty, items.count >= saved.count else { return items }
        let offset = items.count - saved.count
        guard zip(items[offset...], saved).allSatisfy({
            $0.text == $1.text && ($0.sourceLabel ?? "Local") == ($1.sourceLabel ?? "Local")
        }) else { return items }
        var result = items
        for index in saved.indices {
            let item = items[offset + index]
            result[offset + index] = .init(
                id: item.id, kind: item.kind, text: item.text,
                timestamp: saved[index].timestamp, exitCode: item.exitCode,
                duration: item.duration, promptIndex: item.promptIndex,
                location: item.location, sourceLabel: item.sourceLabel
            )
        }
        return result
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
        var row = UInt32.max
        var topPadding = 0.0
        guard ghostty_surface_omg_jump_command(surface, id, &row, &topPadding) else { return .expired }
        Ghostty.moveFocus(to: view, from: nil)
        if row != .max { view.flashHistoryRow(row, topPadding: CGFloat(topPadding)) }
        return .jumped
    }
}
