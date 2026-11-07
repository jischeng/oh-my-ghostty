import Foundation

public struct MobileAgentActivity: Equatable {
    public enum State: String {
        case idle, working, done, needsAttention, error

        fileprivate var rank: Int {
            switch self {
            case .needsAttention: 0
            case .error: 1
            case .working: 2
            case .idle: 3
            case .done: 4
            }
        }
    }

    public let agentID: String
    public let state: State
    public let attention: String?
    public let message: String?
    public let progress: Double?

    public var displayName: String {
        switch agentID {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "pi": "Pi"
        case "antigravity", "agy": "Antigravity"
        default: agentID
        }
    }
}

/// Presentation-only projection of the runtime's existing G snapshot.
/// Field handling follows the Mac AgentStatusPlugin/AgentProgramStatus adapters.
public struct RuntimeAgentState: Equatable {
    private struct Signal: Decodable, Equatable {
        let id: String
        let metadata: String
    }
    private struct Snapshot: Decodable {
        let version: UInt32
        let revision: UInt64
        let records: [Signal]
        let pending: [Signal]?
    }
    public enum Failure: Error { case invalidSnapshot }
    public private(set) var revision: UInt64?
    public private(set) var activity: MobileAgentActivity?
    private var records: [Signal] = []
    private var pending: [Signal]?
    private var remoteID: String?
    public init() {}

    public mutating func consume(_ frame: RuntimeFrame, at position: UInt64?) throws {
        guard frame.kind == 71, let position, frame.sequence == position else {
            throw RuntimeFrame.Failure.invalidSequence
        }
        guard frame.data.count <= 2 * 1024 * 1024 else { throw Failure.invalidSnapshot }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: frame.data)
        guard snapshot.version == 1, snapshot.records.count <= 64,
              (snapshot.pending?.count ?? 0) <= 64,
              (snapshot.records + (snapshot.pending ?? [])).allSatisfy(Self.valid) else {
            throw Failure.invalidSnapshot
        }
        if let revision, snapshot.revision < revision { return }
        // Pending records are an incomplete transaction, never a new UI state.
        records = snapshot.records
        pending = snapshot.pending
        updateActivity()
        revision = snapshot.revision
    }

    /// Ghostty invokes this synchronously while applying the ordered O bytes.
    /// The callback copies borrowed strings; it must never re-enter the terminal.
    public mutating func consumeContext(ended: Bool, id: String, metadata: String) {
        guard id.utf8.count <= 64, metadata.utf8.count <= 4096,
              Self.clean(metadata) != nil else { return }
        if id == "omg-agent-sync" {
            if metadata == "begin" { pending = [] }
            if metadata == "end", let pending {
                records = pending
                self.pending = nil
                updateActivity()
            }
            return
        }
        if id.hasPrefix("omg-ssh-") {
            let values = Self.fields(metadata, separator: ";")
            if ended {
                guard remoteID == nil || remoteID == id else { return }
                remoteID = nil
            } else {
                remoteID = id
                if id.hasPrefix("omg-ssh-inline-") ||
                    (values["cwd"] == nil && values["cwdhex"] == nil) { return }
            }
            pending = nil
            records.removeAll {
                $0.id == "omg-program-status" ||
                    Self.fields($0.metadata, separator: ";")["omg_scope"] == "remote"
            }
            updateActivity()
            return
        }
        let signal = Signal(id: id, metadata: metadata)
        guard Self.valid(signal) else { return }
        let native = id == "omg-program-status"
        let values = Self.fields(metadata, separator: native ? ":" : ";")
        let key = native ? values["id"] ?? "" : id
        let clear = native && values["state"] == "clear"
        guard ended || clear || Self.activity(signal) != nil else { return }
        var updated = pending ?? records
        updated.removeAll { existing in
            guard existing.id == id else { return false }
            if !native { return true }
            let existingKey = Self.fields(existing.metadata, separator: ":")["id"] ?? ""
            return existingKey == key || ((clear || ended) && (key.isEmpty || existingKey.hasPrefix(key + "/")))
        }
        if !ended && !clear {
            if updated.count >= 64 { updated.removeFirst() }
            updated.append(signal)
        }
        if pending != nil {
            pending = updated
        } else {
            records = updated
            updateActivity()
        }
    }

    private mutating func updateActivity() {
        activity = records.compactMap(Self.activity).reversed().min { $0.state.rank < $1.state.rank }
    }

    private static func valid(_ signal: Signal) -> Bool {
        (signal.id == "omg-program-status" ||
            (signal.id.hasPrefix("omg-agent-") && signal.id != "omg-agent-sync")) &&
            signal.id.utf8.count <= 64 &&
            signal.id.utf8.allSatisfy { (32..<127).contains($0) && $0 != 59 } &&
            signal.metadata.utf8.count <= 4096 && clean(signal.metadata) != nil
    }

    private static func fields(_ text: String, separator: Character) -> [String: String] {
        var values: [String: String] = [:]
        for pair in text.split(separator: separator) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                values[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }

    private static func state(_ text: String?) -> MobileAgentActivity.State? {
        switch text {
        case "idle": .idle
        case "working", "processing", "active": .working
        case "waiting", "awaiting", "blocked", "needsAttention": .needsAttention
        case "done", "completed": .done
        case "error", "failed": .error
        default: nil
        }
    }

    private static func activity(_ signal: Signal) -> MobileAgentActivity? {
        let native = signal.id == "omg-program-status"
        let values = fields(signal.metadata, separator: native ? ":" : ";")
        guard native || values["type"] == "app",
              let agent = values[native ? "app" : "omg_agent"],
              !agent.isEmpty, agent.utf8.count <= 32,
              let state = state(values[native ? "state" : "omg_state"]) else { return nil }
        let attention = values[native ? "kind" : "omg_attention"]
        let message = native ? values["msg"].flatMap(decodeText)
            : values["message"].flatMap { $0.removingPercentEncoding }.flatMap(clean)
        let progress = values["progress"].flatMap(Double.init).flatMap { value -> Double? in
            let value = native ? value / 100 : value
            return value.isFinite && (0...1).contains(value) ? value : nil
        }
        return .init(agentID: agent == "agy" ? "antigravity" : agent, state: state,
            attention: state == .needsAttention && ["permission", "question"].contains(attention ?? "")
                ? attention : nil,
            message: message,
            progress: state == .working || state == .needsAttention ? progress : nil)
    }

    private static func clean(_ text: String) -> String? {
        guard text.utf8.count <= 4096,
              text.unicodeScalars.allSatisfy({ $0.value >= 32 && !(127...159).contains($0.value) })
        else { return nil }
        return text
    }

    private static func decodeText(_ text: String) -> String? {
        guard text.utf8.count <= 2732 else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= 2048,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return clean(text)
    }
}
