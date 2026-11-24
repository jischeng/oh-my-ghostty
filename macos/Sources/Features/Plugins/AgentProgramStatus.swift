import Foundation

/// Terminal completion (`done` / `error`) records already acknowledged on a
/// pane. Reconnecting to a preserved `omgd` session replays its last stored
/// activity snapshot (`omg-agent-sync`), which does not know about host-local
/// mouse or keyboard acknowledgement; matching records stay `.idle` until a
/// new turn or terminal signal supersedes them.
struct AcknowledgedAgentStatus: Codable, Equatable, Sendable {
    struct ProgramRecord: Codable, Equatable, Sendable {
        var id: String
        var agent: String?
        var state: TabActivityState
        var message: String?

        func matches(_ candidate: Self?) -> Bool {
            guard let candidate else { return false }
            return id == candidate.id && agent == candidate.agent && state == candidate.state
        }
    }

    struct ReducerRecord: Codable, Equatable, Sendable {
        var contextID: String
        var source: String
        var state: TabActivityState
        var message: String?

        func matches(_ candidate: Self?) -> Bool {
            guard let candidate else { return false }
            return contextID == candidate.contextID &&
                source == candidate.source &&
                state == candidate.state
        }
    }

    var program: ProgramRecord?
    var reducer: ReducerRecord?

    var isEmpty: Bool {
        program == nil && reducer == nil
    }
}

/// OSC 7501 and OSC 26 (TAP) belong to the terminal client, including clients
/// whose Agent runs in a shared server. They therefore need neither a Hook PID
/// nor a daemon TTY.
struct AgentProgramStatus {
    enum Source: Equatable, Sendable {
        case osc7501
        case tap
    }

    struct Record {
        let id: String
        let agent: SupportedAgent?
        let state: TabActivityState
        let phase: TabActivityPhase?
        let attention: TabAttentionKind?
        let message: String?
        let progress: Double?
        var acknowledged = false
        let source: Source
        let sessionID: String?
        let taskProgress: String?
        let title: String?

        init(
            id: String,
            agent: SupportedAgent?,
            state: TabActivityState,
            phase: TabActivityPhase?,
            attention: TabAttentionKind?,
            message: String?,
            progress: Double?,
            acknowledged: Bool = false,
            source: Source = .osc7501,
            sessionID: String? = nil,
            taskProgress: String? = nil,
            title: String? = nil
        ) {
            self.id = id
            self.agent = agent
            self.state = state
            self.phase = phase
            self.attention = attention
            self.message = message
            self.progress = progress
            self.acknowledged = acknowledged
            self.source = source
            self.sessionID = sessionID
            self.taskProgress = taskProgress
            self.title = title
        }

        var effectiveState: TabActivityState {
            acknowledged ? .idle : state
        }

        var activity: TabActivity? {
            activity(enrichedBy: nil)
        }

        func activity(enrichedBy tap: Record?) -> TabActivity? {
            guard let agent else { return nil }
            let resolvedMessage: String? = if acknowledged {
                nil
            } else {
                message ?? tap?.title
            }
            let resolvedDetail: String? = if acknowledged {
                nil
            } else if let tapTitle = tap?.title, tapTitle != resolvedMessage {
                tapTitle
            } else {
                tap?.taskProgress ?? taskProgress
            }
            let resolvedProgress: Double? = if acknowledged {
                nil
            } else if effectiveState == .working || effectiveState == .needsAttention {
                progress ?? tap?.progress
            } else {
                nil
            }
            return .init(
                source: agent.rawValue,
                state: effectiveState,
                phase: acknowledged ? nil : phase,
                attentionKind: acknowledged ? nil : attention,
                label: agent.displayName,
                message: resolvedMessage,
                detail: resolvedDetail,
                progress: resolvedProgress,
                icon: agent.icon
            )
        }
    }

    var records: [Record] = []
    var isRemote = false
    var foregroundProcessGroup: Int?
    var activity: TabActivity? {
        guard let selected = selectedRecord else { return nil }
        let enrichment = selected.source == .osc7501
            ? latestTAPRecord(for: selected.agent)
            : nil
        return selected.activity(enrichedBy: enrichment)
    }

    var activeSessionID: String? {
        guard let selected = selectedRecord else { return nil }
        return selected.sessionID ?? latestTAPRecord(for: selected.agent)?.sessionID
    }

    var activeTaskProgress: String? {
        guard let selected = selectedRecord else { return nil }
        return selected.taskProgress ?? latestTAPRecord(for: selected.agent)?.taskProgress
    }

    var activeTAPTitle: String? {
        guard let selected = selectedRecord else { return nil }
        return selected.title ?? latestTAPRecord(for: selected.agent)?.title
    }

    /// Core validates the full protocol. Retain bounded validation here too:
    /// OSC 3008 shares the bridge and terminal text is never trusted authority.
    mutating func consume(_ body: String, fallbackAgent: SupportedAgent? = nil) -> Bool {
        guard body.utf8.count <= 4087 else { return false }
        var fields: [String: String] = [:]
        for pair in body.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.utf8.count <= 16 else { return false }
            if key == "id", !Self.validID(value) { return false }
            if key == "app", value.utf8.count > 32 { return false }
            if key == "msg", Self.text(value, limit: 2048) == nil { return false }
            if key == "title", Self.text(value, limit: 192) == nil { return false }
            fields[key] = value
        }
        let id = fields["id"] ?? ""
        if fields["state"] == "clear" {
            records.removeAll { id.isEmpty || $0.id == id || $0.id.hasPrefix(id + "/") }
            return true
        }
        let state: TabActivityState
        switch fields["state"] {
        case "idle": state = .idle
        case "working": state = .working
        case "done": state = .done
        case "blocked": state = .needsAttention
        case "error": state = .error
        default: return false
        }
        let phase: TabActivityPhase? = state == .working && fields["phase"] == "background"
            ? .background
            : nil
        let progress = fields["progress"].flatMap { raw -> Double? in
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Double(raw), (0...100).contains(value) else { return nil }
            return value / 100
        }
        let attention: TabAttentionKind? = if state == .needsAttention {
            fields["kind"] == "question" ? .question : (fields["kind"] == "permission" ? .permission : nil)
        } else { nil }
        let resolvedAgent: SupportedAgent?
        if let rawApp = fields["app"], !rawApp.isEmpty {
            resolvedAgent = Self.resolveAgent(rawApp)
        } else {
            resolvedAgent = inheritedAgent(for: id, fallback: fallbackAgent)
        }
        guard let agent = resolvedAgent else {
            return false
        }
        if state == .working, phase != .background {
            for index in records.indices
            where !records[index].acknowledged &&
                (records[index].state == .done || records[index].state == .error) {
                records[index].acknowledged = true
            }
        }
        let acknowledged = records.first { $0.id == id }.map {
            $0.acknowledged && $0.agent == agent && $0.state == state &&
                (state == .done || state == .error)
        } ?? false
        records.removeAll { $0.id == id }
        if records.count >= 32 { records.removeFirst() }
        records.append(.init(
            id: id,
            agent: agent,
            state: state,
            phase: phase,
            attention: attention,
            message: fields["msg"].flatMap { Self.text($0, limit: 2048) },
            progress: state == .working || state == .needsAttention ? progress : nil,
            acknowledged: acknowledged
        ))
        return true
    }

    var acknowledgmentCandidate: AcknowledgedAgentStatus.ProgramRecord? {
        let target = selectedRecord.flatMap {
            ($0.state == .done || $0.state == .error) ? $0 : nil
        } ?? records.last { $0.state == .done || $0.state == .error }
        guard let target else { return nil }
        return .init(
            id: target.id,
            agent: target.agent?.rawValue,
            state: target.state,
            message: target.message
        )
    }

    var hasAcknowledgedTerminalRecord: Bool {
        records.contains { $0.acknowledged && ($0.state == .done || $0.state == .error) }
    }

    mutating func acknowledge() -> Bool {
        var didChange = false
        for index in records.indices
        where !records[index].acknowledged &&
            (records[index].state == .done || records[index].state == .error) {
            records[index].acknowledged = true
            didChange = true
        }
        return didChange
    }

    /// Resolves effective pane activity when both Tier 1 native status (`program`:
    /// OSC 7501 / OSC 26 TAP) and Tier 2/3 Hook/fallback state (`fallback`) exist.
    ///
    /// Strict Tier 1 authority: once an agent has an active Tier 1 record in a pane,
    /// Tier 2 hooks for that same agent are metadata-only — they never resurface over
    /// Tier 1 `idle`, and only augment Tier 1 `working` with `needsAttention` when the
    /// agent does not natively support OSC 7501 `blocked`.
    static func preferredActivity(
        program: TabActivity?,
        fallback: TabActivity?
    ) -> TabActivity? {
        if let program {
            let allowsSameAgentHookOverride =
                SupportedAgent(rawValue: program.source)?
                    .definition.supportsNativeOSC7501Blocked != true
            if program.state != .idle {
                if program.state == .working,
                   let fallback,
                   fallback.state == .needsAttention || fallback.state == .error,
                   fallback.source == program.source,
                   allowsSameAgentHookOverride {
                    return fallback
                }
                return program
            }
            if let fallback, fallback.state != .idle {
                if fallback.source != program.source {
                    return fallback
                }
                if fallback.state == .error, allowsSameAgentHookOverride {
                    return fallback
                }
            }
            return program
        }
        return fallback
    }

    private func latestTAPRecord(for agent: SupportedAgent?) -> Record? {
        guard let agent else { return nil }
        return records.reversed().first { $0.source == .tap && $0.agent == agent }
    }

    private var selectedRecord: Record? {
        let osc7501Agents = Set(records.compactMap { $0.source == .osc7501 ? $0.agent : nil })
        var best: Record?
        for record in records where record.agent != nil {
            // Same-agent arbitration: OSC 7501 wins on state/attention over OSC 26 TAP.
            if record.source == .tap, let agent = record.agent, osc7501Agents.contains(agent) {
                continue
            }
            guard let existing = best else {
                best = record
                continue
            }
            let nextPriority = Self.priority(record)
            let existingPriority = Self.priority(existing)
            if nextPriority > existingPriority ||
                (nextPriority == existingPriority &&
                    !(existing.source == .osc7501 && record.source == .tap)) {
                best = record
            }
        }
        return best
    }

    private static func priority(_ record: Record) -> Int {
        switch record.effectiveState {
        case .needsAttention: 5
        case .working: record.phase == .background ? 3 : 4
        case .error: 2
        case .done: 1
        case .idle: 0
        }
    }

    func inheritedAgent(
        for id: String,
        fallback: SupportedAgent?
    ) -> SupportedAgent? {
        if let exact = records.reversed().first(where: { $0.id == id && $0.agent != nil })?.agent {
            return exact
        }
        if !id.isEmpty {
            var prefix = id[...]
            while let slash = prefix.lastIndex(of: "/") {
                let parent = String(prefix[..<slash])
                if let match = records.reversed().first(where: {
                    $0.id == parent && $0.agent != nil
                })?.agent {
                    return match
                }
                prefix = prefix[..<slash]
            }
        }
        if let root = records.reversed().first(where: { $0.id.isEmpty && $0.agent != nil })?.agent {
            return root
        }
        let known = Set(records.compactMap(\.agent))
        if known.count == 1, let sole = known.first {
            return sole
        }
        return fallback
    }

    static func resolveAgent(_ raw: String) -> SupportedAgent? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let hyphenated = normalized
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")

        for candidateName in [normalized, hyphenated] {
            if let agent = SupportedAgent(rawValue: candidateName) { return agent }
            switch candidateName {
            case "agy", "jetski", "jetski-cli", "antigravity-cli", "gemini":
                return .antigravity
            case "claude-code":
                return .claude
            case "openai-codex":
                return .codex
            case "pi-coding-agent":
                return .pi
            case "github-copilot-cli", "gh-copilot":
                return .copilot
            case "oh-my-pi":
                return .omp
            case "qwen-code":
                return .qwen
            case "kimi-code":
                return .kimi
            default:
                break
            }
        }

        for candidate in SupportedAgent.allCases {
            let definition = candidate.definition
            if candidate.displayName.lowercased() == normalized ||
                definition.command.lowercased() == normalized ||
                definition.command.lowercased() == hyphenated ||
                definition.process.executables.contains(where: {
                    let lower = $0.lowercased()
                    return lower == normalized || lower == hyphenated
                }) ||
                definition.process.runtimeMarkers.contains(where: {
                    guard !$0.contains("/") else { return false }
                    let lower = $0.lowercased()
                    return lower == normalized || lower == hyphenated
                }) {
                return candidate
            }
        }
        return nil
    }

    private static func validID(_ value: String) -> Bool {
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-".utf8)
        return value.utf8.count <= 128 && segments.count <= 8 &&
            segments.allSatisfy { !$0.isEmpty && $0.utf8.count <= 32 && $0.utf8.allSatisfy(alphabet.contains) }
    }

    private static func text(_ value: String, limit: Int) -> String? {
        guard value.utf8.count <= ((limit + 2) / 3) * 4 else { return nil }
        let padded = value + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= limit,
              let text = String(data: data, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value > 31 && !(127...159).contains($0.value) }) else { return nil }
        return text
    }
}
