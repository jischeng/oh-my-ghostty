import Foundation

/// Bounded parser for OSC 26 (Terminal Agent Protocol / TAP) payloads.
///
/// Terminal output is never trusted authority:
/// - Payloads are bounded to 4096 UTF-8 bytes with no control characters.
/// - `SessionId` is strictly validated against `[A-Za-z0-9._-]` (no leading `-`, <= 128 bytes).
/// - `ProjectFolder` is explicitly ignored for filesystem / working-directory authority.
struct AgentTAPStatus: Equatable, Sendable {
    static let maxPayloadBytes = 4096
    static let maxKeyBytes = 32
    static let maxCodeAgentBytes = 64
    static let maxSessionIDBytes = 128
    static let maxTaskProgressBytes = 32
    static let maxTitleBytes = 256

    let agent: SupportedAgent?
    let sessionID: String?
    let state: TabActivityState
    let attention: TabAttentionKind?
    let taskProgress: String?
    let progress: Double?
    let title: String?

    static func parse(_ body: String, fallbackAgent: SupportedAgent? = nil) -> AgentTAPStatus? {
        guard !body.isEmpty, body.utf8.count <= maxPayloadBytes, isPrintable(body) else {
            return nil
        }

        var sawCodeAgent = false
        var parsedAgent: SupportedAgent?
        var parsedState: TabActivityState?
        var parsedAttention: TabAttentionKind?
        var parsedSessionID: String?
        var parsedTaskProgress: String?
        var parsedProgress: Double?
        var parsedTitle: String?

        for pair in body.split(separator: ";", omittingEmptySubsequences: true) {
            let trimmedPair = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPair.isEmpty { continue }
            let parts = trimmedPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.utf8.count <= maxKeyBytes else { return nil }

            switch key.lowercased() {
            case "codeagent":
                sawCodeAgent = true
                guard !value.isEmpty, value.utf8.count <= maxCodeAgentBytes,
                      let resolved = resolveAgent(value) else {
                    return nil
                }
                parsedAgent = resolved

            case "status":
                switch value.lowercased() {
                case "running":
                    parsedState = .working
                    parsedAttention = nil
                case "awaiting-input":
                    parsedState = .needsAttention
                    parsedAttention = .question
                case "awaiting-approval":
                    parsedState = .needsAttention
                    parsedAttention = .permission
                case "idle":
                    parsedState = .idle
                    parsedAttention = nil
                case "error":
                    parsedState = .error
                    parsedAttention = nil
                case "done", "completed":
                    parsedState = .done
                    parsedAttention = nil
                default:
                    return nil
                }

            case "sessionid":
                if value.isEmpty {
                    parsedSessionID = nil
                } else if validSessionID(value) {
                    parsedSessionID = value
                } else {
                    return nil
                }

            case "taskprogress":
                if value.isEmpty {
                    parsedTaskProgress = nil
                    parsedProgress = nil
                } else if value.utf8.count <= maxTaskProgressBytes, isPrintable(value) {
                    parsedTaskProgress = value
                    parsedProgress = parseProgress(value)
                } else {
                    return nil
                }

            case "title":
                if value.isEmpty {
                    parsedTitle = nil
                } else if value.utf8.count <= maxTitleBytes, isPrintable(value) {
                    parsedTitle = value
                } else {
                    return nil
                }

            case "projectfolder":
                // Untrusted terminal output must never establish cwd or FS authority.
                continue

            default:
                continue
            }
        }

        guard let state = parsedState else { return nil }
        let agent = sawCodeAgent ? parsedAgent : fallbackAgent
        return AgentTAPStatus(
            agent: agent,
            sessionID: parsedSessionID,
            state: state,
            attention: parsedAttention,
            taskProgress: parsedTaskProgress,
            progress: parsedProgress,
            title: parsedTitle
        )
    }

    static func resolveAgent(_ raw: String) -> SupportedAgent? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= maxCodeAgentBytes else { return nil }
        let hyphenated = normalized
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")

        for candidateName in [normalized, hyphenated] {
            if let agent = SupportedAgent(rawValue: candidateName) {
                return agent
            }
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
                }) {
                return candidate
            }
        }
        return nil
    }

    static func validSessionID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maxSessionIDBytes,
              !value.hasPrefix("-") else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) ||   // 0-9
            (65...90).contains(byte) ||   // A-Z
            (97...122).contains(byte) ||  // a-z
            byte == 46 ||                 // .
            byte == 95 ||                 // _
            byte == 45                    // -
        }
    }

    static func parseProgress(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let percentToken = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
        if !percentToken.isEmpty,
           percentToken.utf8.allSatisfy({ (48...57).contains($0) }),
           let value = Double(percentToken),
           (0...100).contains(value) {
            return value / 100
        }
        let fraction = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if fraction.count == 2,
           !fraction[0].isEmpty, !fraction[1].isEmpty,
           fraction[0].utf8.allSatisfy({ (48...57).contains($0) }),
           fraction[1].utf8.allSatisfy({ (48...57).contains($0) }),
           let numerator = Double(fraction[0]),
           let denominator = Double(fraction[1]),
           denominator > 0, numerator <= denominator {
            return numerator / denominator
        }
        return nil
    }

    private static func isPrintable(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value > 31 && !(127...159).contains($0.value) }
    }
}

extension AgentProgramStatus {
    /// Consumes an OSC 26 (TAP) payload as a Tier 1 peer alongside OSC 7501.
    ///
    /// When both OSC 7501 and OSC 26 report for the same agent, OSC 7501 wins on
    /// state/attention while OSC 26 enriches metadata (`SessionId`, `TaskProgress`,
    /// `Title`). TAP-only agents drive Tier 1 activity directly.
    mutating func consumeTAP(_ body: String, fallbackAgent: SupportedAgent? = nil) -> Bool {
        let resolvedFallback = fallbackAgent ?? inheritedAgent(for: "", fallback: nil)
        guard let tap = AgentTAPStatus.parse(body, fallbackAgent: resolvedFallback),
              let tapAgent = tap.agent else {
            return false
        }
        let recordID = "tap/\(tapAgent.rawValue)"
        if tap.state == .working {
            for index in records.indices
            where !records[index].acknowledged &&
                (records[index].state == .done || records[index].state == .error) {
                records[index].acknowledged = true
            }
        }
        let acknowledged = records.first { $0.id == recordID }.map {
            $0.acknowledged && $0.agent == tapAgent && $0.state == tap.state &&
                (tap.state == .done || tap.state == .error)
        } ?? false
        records.removeAll { $0.id == recordID }
        if records.count >= 32 { records.removeFirst() }
        records.append(.init(
            id: recordID,
            agent: tapAgent,
            state: tap.state,
            phase: nil,
            attention: tap.attention,
            message: tap.title,
            progress: tap.state == .working || tap.state == .needsAttention ? tap.progress : nil,
            acknowledged: acknowledged,
            source: .tap,
            sessionID: tap.sessionID,
            taskProgress: tap.taskProgress,
            title: tap.title
        ))
        return true
    }
}
