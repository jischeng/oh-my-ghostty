import Foundation

/// A choice is remembered per account, not per tab or per Hook version. Hook
/// removal, upgrades, reconnects and failures must not nag the user again.
struct AgentIntegrationOnboarding: Codable, Equatable {
    var knownAgents: Set<SupportedAgent> = []
    var awaitingFirstInventory = false

    static func detected(in snapshot: AgentIntegrationSnapshot) -> Set<SupportedAgent> {
        Set(snapshot.cli.compactMap { $0.value.path == nil ? nil : $0.key })
    }

    static func choice(snapshot: AgentIntegrationSnapshot?) -> Self {
        .init(knownAgents: snapshot.map { detected(in: $0) } ?? [],
              awaitingFirstInventory: snapshot?.cli.isEmpty != false)
    }

    mutating func receive(_ snapshot: AgentIntegrationSnapshot) {
        guard awaitingFirstInventory, !snapshot.cli.isEmpty else { return }
        knownAgents.formUnion(Self.detected(in: snapshot))
        awaitingFirstInventory = false
    }

    func newlyDetected(in snapshot: AgentIntegrationSnapshot?) -> Set<SupportedAgent> {
        guard !awaitingFirstInventory, let snapshot else { return [] }
        return Self.detected(in: snapshot).subtracting(knownAgents)
    }
}

struct AgentIntegrationOperation: Equatable {
    enum Kind { case checking, hooks, cli }
    var kind: Kind
    var agent: SupportedAgent?
    var completed = 0
    var total = 0
}
