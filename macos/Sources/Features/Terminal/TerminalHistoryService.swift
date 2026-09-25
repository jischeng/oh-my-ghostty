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
    private var checkedReplay = Set<UUID>()
    // Core IDs are monotonic even across reset. Retired entries must never
    // be relabeled as belonging to a new host; one high-water mark is bounded.
    private var historicalExecutionFloor: [UUID: UInt64] = [:]
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
        let changing = previous != nil && previous?.connectionID != Self.connectionID(context)
        let pendingReplay = previous != nil && saved != nil && !checkedReplay.contains(view.id)
        var rejectReplay = false
        if pendingReplay, let previous, let surface = view.surface, let saved {
            let rows = snapshotCommands(surface, surfaceID: view.id, epoch: previous.epoch,
                                        sourceLabel: previous.sourceLabel)
            if let segment = ShellScrollbackRestoreStore.replayCommands(for: view.id),
               let verified = Self.verifiedReplay(rows.filter { $0.replayKey != nil },
                   segment: segment, saved: saved, surfaceID: view.id) {
                installVerifiedReplay(verified, for: view.id)
                checkedReplay.insert(view.id)
            } else if changing {
                // Legacy/unverifiable replay must not inherit the new SSH
                // connection's identity. This is not an ordinary transition.
                rejectReplay = true
                checkedReplay.insert(view.id)
            }
        }
        synchronizeSession(surfaceID: view.id, connectionID: Self.connectionID(context),
                           sourceLabel: Self.sourceLabel(context), preserveAnchors: !rejectReplay, captured: {
            guard !rejectReplay, let previous, let surface = view.surface else { return [] }
            return snapshotCommands(surface, surfaceID: view.id, epoch: previous.epoch,
                                    sourceLabel: previous.sourceLabel)
        }, clear: {
            guard let surface = view.surface else { return }
            ghostty_surface_omg_clear_commands(surface)
        })
    }

    @discardableResult
    func synchronizeSession(
        surfaceID: UUID, connectionID: String?, sourceLabel: String = "Local",
        preserveAnchors: Bool = true,
        captured: () -> [InspectorHistoryItem] = { [] }, clear: () -> Void
    ) -> UUID {
        if let session = sessions[surfaceID], session.connectionID == connectionID {
            if session.sourceLabel != sourceLabel {
                sessions[surfaceID] = .init(connectionID: connectionID, epoch: session.epoch,
                                            sourceLabel: sourceLabel)
            }
            return session.epoch
        }
        if sessions[surfaceID] != nil, preserveAnchors {
            retainHistoricalAnchors(captured(), for: surfaceID)
        } else if sessions[surfaceID] != nil || connectionID != nil {
            clear()
            archivedBySurface[surfaceID] = (archivedBySurface[surfaceID] ?? []).map(Self.expired)
            historicalExecutionFloor.removeValue(forKey: surfaceID)
        }
        let epoch = UUID()
        sessions[surfaceID] = .init(connectionID: connectionID, epoch: epoch,
                                    sourceLabel: sourceLabel)
        return epoch
    }

    private static func executionID(_ item: InspectorHistoryItem) -> UInt64? {
        if case .command(_, let id, _) = item.location { return id }
        return nil
    }

    private static func expired(_ item: InspectorHistoryItem) -> InspectorHistoryItem {
        .init(id: item.id, kind: item.kind, text: item.text, timestamp: item.timestamp,
              location: .unavailable(.expired), sourceLabel: item.sourceLabel, replayKey: item.replayKey)
    }

    private func retainHistoricalAnchors(_ records: [InspectorHistoryItem], for surfaceID: UUID) {
        let valid = Set(records.compactMap(Self.executionID))
        let previousFloor = historicalExecutionFloor[surfaceID]
        var highest = previousFloor
        var added = Set<UInt64>()
        var history = (archivedBySurface[surfaceID] ?? []).map { item in
            if let id = Self.executionID(item), !valid.contains(id) { return Self.expired(item) }
            return item
        }
        for item in records {
            guard case .command(let owner, let id, _) = item.location,
                  owner == surfaceID, previousFloor.map({ id > $0 }) ?? true,
                  added.insert(id).inserted else { continue }
            history.append(item)
            highest = max(highest ?? id, id)
        }
        // IDs remain reserved even if a bounded UI row is evicted, so the
        // same old core entry is never relabeled as belonging to a new host.
        historicalExecutionFloor[surfaceID] = highest
        archivedBySurface[surfaceID] = Array(history.sorted {
            if $0.location.isAvailable != $1.location.isAvailable { return $0.location.isAvailable }
            return ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }.prefix(100))
    }

    func installVerifiedReplay(_ records: [InspectorHistoryItem], for surfaceID: UUID) {
        retainHistoricalAnchors(records, for: surfaceID)
    }

    func archivedCommands(for surfaceID: UUID) -> [InspectorHistoryItem] {
        archivedBySurface[surfaceID] ?? []
    }

    func removeSurface(_ surfaceID: UUID) {
        sessions.removeValue(forKey: surfaceID)
        archivedBySurface.removeValue(forKey: surfaceID)
        checkedReplay.remove(surfaceID)
        historicalExecutionFloor.removeValue(forKey: surfaceID)
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
        ghostty_surface_omg_commands(surface, Unmanaged.passUnretained(snapshot).toOpaque()) { context, id, text, timestamp, replayKey in
            guard let context, let text else { return }
            let snapshot = Unmanaged<CommandSnapshot>.fromOpaque(context).takeUnretainedValue()
            snapshot.items.append(.init(
                id: "command:\(snapshot.surfaceID):\(snapshot.epoch):\(id)",
                kind: .command, text: String(cString: text),
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                location: .command(surfaceID: snapshot.surfaceID, executionID: id,
                                   epoch: snapshot.epoch), sourceLabel: snapshot.sourceLabel,
                replayKey: replayKey.map { String(cString: $0) }
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
            let raw = snapshotCommands(surface, surfaceID: surfaceID, epoch: epoch,
                                       sourceLabel: sessions[surfaceID]?.sourceLabel ?? "Local")
            let validIDs = Set(raw.compactMap(Self.executionID))
            let previousFloor = historicalExecutionFloor[surfaceID]
            let live = raw.filter { item in
                if case .command(_, let id, _) = item.location { return previousFloor.map { id > $0 } ?? true }
                return false
            }
            let archived = (archivedBySurface[surfaceID] ?? []).map { item in
                if case .command(_, let id, _) = item.location, !validIDs.contains(id) {
                    return Self.expired(item)
                }
                return item
            }
            archivedBySurface[surfaceID] = archived
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

    /// Exact v3/v4 binding. All replayed input markers must match the
    /// saved segments in order, with distinct host-owned identities.
    /// Repeated text alone can never establish a one-to-one mapping.
    static func verifiedReplay(
        _ replayedNewestFirst: [InspectorHistoryItem],
        segment: [ShellScrollbackRestoreStore.SavedCommand],
        saved: [ShellScrollbackRestoreStore.SavedCommand],
        surfaceID: UUID
    ) -> [InspectorHistoryItem]? {
        guard replayedNewestFirst.count == segment.count else { return nil }
        let identities = segment.compactMap(\.occurrenceID)
        guard identities.count == segment.count, Set(identities).count == segment.count else { return nil }
        var verified: [InspectorHistoryItem] = []
        var coreIDs = Set<UInt64>()
        for (item, command) in zip(replayedNewestFirst.reversed(), segment) {
            guard let occurrenceID = command.occurrenceID,
                  item.replayKey == occurrenceID,
                  saved.filter({ $0.occurrenceID == occurrenceID }) == [command],
                  item.text == command.text,
                  case .command(let owner, let id, _) = item.location,
                  owner == surfaceID, coreIDs.insert(id).inserted else { return nil }
            verified.append(.init(id: occurrenceID, kind: .command,
                text: command.text, timestamp: command.timestamp,
                location: item.location, sourceLabel: command.sourceLabel,
                replayKey: occurrenceID))
        }
        return verified
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
        let seenIDs = Set(items.map(\.id))
        let archived = saved.enumerated().compactMap { index, command -> InspectorHistoryItem? in
            if let occurrenceID = command.occurrenceID, seenIDs.contains(occurrenceID) { return nil }
            return .init(
                id: command.occurrenceID ?? "archived:\(surfaceID.uuidString):\(index)",
                kind: .command, text: command.text, timestamp: command.timestamp,
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
                location: item.location, sourceLabel: item.sourceLabel,
                replayKey: item.replayKey
            )
        }
        return result
    }

    func validate(_ location: HistoryLocation, surfaceID: UUID) -> JumpResult? {
        guard case .command(let owner, _, let epoch) = location else { return .unavailable }
        guard owner == surfaceID else { return .wrongSession }
        if sessions[surfaceID]?.epoch == epoch { return nil }
        guard archivedBySurface[surfaceID]?.contains(where: { $0.location == location }) == true else {
            return .wrongSession
        }
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
