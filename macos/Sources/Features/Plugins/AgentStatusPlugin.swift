import Foundation

enum SupportedAgent: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .pi: "Pi"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        case .pi: "function"
        }
    }

    var icon: PluginTabIcon {
        .init(kind: .systemSymbol, name: systemImage)
    }

    func normalizedTitle(_ title: String) -> String {
        switch self {
        case .codex:
            return title
        case .claude:
            guard title.contains("Claude Code") else { return title }
            let trimmed = title.drop(while: { character in
                character.isWhitespace || character == "✳" || character == "✻" ||
                    character == "✶" || character == "*"
            })
            return trimmed.isEmpty ? displayName : String(trimmed)
        case .pi:
            let prefixes = ["π - ", "Pi - ", "pi - "]
            guard let prefix = prefixes.first(where: { title.hasPrefix($0) }) else {
                return title
            }
            let normalized = title.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            return normalized.isEmpty ? displayName : normalized
        }
    }
}

enum AgentStatusPlugin {
    @MainActor static var isEnabled: Bool {
        OhMyGhosttySettings.shared.agentStatusHooksEnabled
    }
}

enum AgentHookInstallerError: LocalizedError {
    case invalidConfiguration

    var errorDescription: String? {
        "The existing agent configuration is not a JSON object."
    }
}

struct AgentHookInstaller {
    static let marker = "_omg_agent_status"

    let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    func isInstalled(_ agent: SupportedAgent) -> Bool {
        switch agent {
        case .codex:
            containsMarker(in: homeURL.appendingPathComponent(".codex/hooks.json"))
        case .claude:
            containsMarker(in: homeURL.appendingPathComponent(".claude/settings.json"))
        case .pi:
            (try? String(
                contentsOf: piExtensionURL,
                encoding: .utf8
            ).contains("marker: \(Self.marker)")) == true
        }
    }

    func install(_ agent: SupportedAgent) throws {
        switch agent {
        case .codex:
            try installJSONHooks(
                at: homeURL.appendingPathComponent(".codex/hooks.json"),
                agent: agent
            )
            try ensureCodexHooksEnabled()
        case .claude:
            try installJSONHooks(
                at: homeURL.appendingPathComponent(".claude/settings.json"),
                agent: agent
            )
        case .pi:
            try backupIfNeeded(piExtensionURL)
            try FileManager.default.createDirectory(
                at: piExtensionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.piExtension.write(
                to: piExtensionURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func uninstall(_ agent: SupportedAgent) throws {
        switch agent {
        case .codex:
            try removeJSONHooks(
                at: homeURL.appendingPathComponent(".codex/hooks.json")
            )
        case .claude:
            try removeJSONHooks(
                at: homeURL.appendingPathComponent(".claude/settings.json")
            )
        case .pi:
            try? FileManager.default.removeItem(at: piExtensionURL)
        }
    }

    private var piExtensionURL: URL {
        homeURL.appendingPathComponent(
            ".pi/agent/extensions/omg-agent-status.ts"
        )
    }

    private func containsMarker(in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dictionary = root as? [String: Any],
              let hooks = dictionary["hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: Self.isOMGEntry)
        }
    }

    private func installJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        var root = try loadJSONObject(at: url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, state, matcher) in Self.hookEvents(agent) {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter {
                !Self.isOMGEntry($0)
            }
            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": Self.hookCommand(
                        agent: agent,
                        state: state
                    ),
                ]],
            ]
            if let matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeJSONHooks(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try loadJSONObject(at: url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for key in Array(hooks.keys) {
            guard let entries = hooks[key] as? [[String: Any]] else { continue }
            let remaining = entries.filter { !Self.isOMGEntry($0) }
            if remaining.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = remaining
            }
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw AgentHookInstallerError.invalidConfiguration
        }
        return dictionary
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func ensureCodexHooksEnabled() throws {
        let url = homeURL.appendingPathComponent(".codex/config.toml")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let section = lines.firstIndex { $0.trimmingCharacters(
            in: .whitespaces
        ) == "[features]" }
        if let section {
            let end = lines[(section + 1)...].firstIndex {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            } ?? lines.endIndex
            if let hooks = lines[(section + 1)..<end].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("hooks =")
            }) {
                lines[hooks] = "hooks = true"
            } else {
                lines.insert("hooks = true", at: section + 1)
            }
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: ["[features]", "hooks = true"])
        }
        text = lines.joined(separator: "\n")
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func isOMGEntry(_ entry: [String: Any]) -> Bool {
        if entry[marker] as? Bool == true { return true }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private func backupIfNeeded(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("omg-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private static func hookEvents(
        _ agent: SupportedAgent
    ) -> [(String, TabActivityState?, String?)] {
        var events: [(String, TabActivityState?, String?)] = [
            ("SessionStart", .idle, nil),
            ("UserPromptSubmit", .working, nil),
            ("PreToolUse", .working, nil),
            ("PostToolUse", .working, nil),
            ("PermissionRequest", .needsAttention, nil),
            ("Stop", .done, nil),
            ("SessionEnd", nil, nil),
        ]
        if agent == .claude {
            events.append(("Notification", .needsAttention, "permission_prompt"))
        }
        return events
    }

    private static func hookCommand(
        agent: SupportedAgent,
        state: TabActivityState?
    ) -> String {
        let sequence: String
        if let state {
            sequence = "\\033]3008;start=omg-agent-\(agent.rawValue);" +
                "type=app;omg_agent=\(agent.rawValue);" +
                "omg_state=\(state.rawValue)\\007"
        } else {
            sequence = "\\033]3008;end=omg-agent-\(agent.rawValue);" +
                "type=app;omg_agent=\(agent.rawValue)\\007"
        }
        return ": \(marker); " +
            "omg_tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "case \"$omg_tty\" in ''|*[!A-Za-z0-9/._-]*) exit 0;; esac; " +
            "printf '\(sequence)' > \"/dev/$omg_tty\" 2>/dev/null || true"
    }

    private static let piExtension = #"""
// OMG agent status integration for Pi.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";

const contextId = "omg-agent-pi";
function report(state?: string, end = false) {
  try {
    const fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=pi\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=pi;omg_state=${state}\u0007`;
    writeSync(fd, sequence);
    closeSync(fd);
  } catch {}
}

export default function (pi: any) {
  pi.on("session_start", async () => report("idle"));
  pi.on("before_agent_start", async () => report("working"));
  pi.on("agent_start", async () => report("working"));
  pi.on("tool_execution_start", async (event: any) => {
    const waitingTools = new Set(["ask_user_question", "ask_question", "question", "confirm"]);
    report(waitingTools.has(String(event.toolName)) ? "needsAttention" : "working");
  });
  pi.on("tool_execution_end", async () => report("working"));
  pi.on("agent_settled", async () => report("done"));
  pi.on("session_shutdown", async () => report(undefined, true));
}
"""#
}

enum AgentActivityUpdate: Equatable, Sendable {
    case set(TabActivity)
    case clear
}

struct AgentContextSignalReducer: Sendable {
    private var activities: [String: TabActivity] = [:]
    private var order: [String] = []

    mutating func consume(_ signal: Ghostty.ContextSignal) -> AgentActivityUpdate? {
        guard signal.id.hasPrefix("omg-agent-") else { return nil }
        switch signal.action {
        case .end:
            guard activities.removeValue(forKey: signal.id) != nil else { return nil }
            let wasActive = order.last == signal.id
            order.removeAll { $0 == signal.id }
            guard wasActive else { return nil }
            guard let restoredID = order.last,
                  let restored = activities[restoredID] else { return .clear }
            return .set(restored)

        case .start:
            let metadata = Self.metadata(signal.metadata)
            guard metadata["type"] == "app",
                  let rawAgent = metadata["omg_agent"],
                  let agent = SupportedAgent(rawValue: rawAgent),
                  let rawState = metadata["omg_state"],
                  let state = Self.state(rawState) else { return nil }
            let progress = metadata["progress"].flatMap(Double.init).flatMap {
                (0...1).contains($0) ? $0 : nil
            }
            let activity = TabActivity(
                source: agent.rawValue,
                state: state,
                label: agent.displayName,
                message: metadata["message"]?.removingPercentEncoding,
                detail: nil,
                progress: progress,
                icon: agent.icon
            )
            activities[signal.id] = activity
            order.removeAll { $0 == signal.id }
            order.append(signal.id)
            return .set(activity)
        }
    }

    private static func state(_ raw: String) -> TabActivityState? {
        switch raw {
        case "idle": .idle
        case "working", "processing", "active": .working
        case "waiting", "awaiting", "blocked", "needsAttention": .needsAttention
        case "done", "completed": .done
        case "error", "failed": .error
        default: nil
        }
    }

    private static func metadata(_ raw: String) -> [String: String] {
        raw.split(separator: ";").reduce(into: [:]) { result, field in
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[0].count <= 64,
                  parts[1].count <= 512 else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }
}

@MainActor
final class MockAgentStatusAdapter {
    static let pluginID = "dev.oh-my-ghostty.mock-agent"

    private let store: TabActivityStore
    private var revisions: [UUID: UInt64] = [:]

    init(store: TabActivityStore) {
        self.store = store
    }

    @discardableResult
    func report(
        sessionID: UUID,
        state: TabActivityState,
        message: String? = nil
    ) -> PluginProtocolFailure? {
        let revision = (revisions[sessionID] ?? 0) + 1
        revisions[sessionID] = revision

        if state == .idle {
            return store.clear(
                .init(sessionID: sessionID, revision: revision),
                pluginID: Self.pluginID
            )
        }

        let wireState: PluginSessionStatus.State = switch state {
        case .idle: .completed
        case .working: .running
        case .done: .completed
        case .needsAttention: .waiting
        case .error: .failed
        }
        return store.set(
            .init(
                sessionID: sessionID,
                revision: revision,
                status: .init(
                    agent: "mock",
                    title: "Mock Agent",
                    state: wireState,
                    message: message,
                    icon: .init(kind: .systemSymbol, name: "bolt.fill")
                ),
                ttlMilliseconds: state == .done ? 15_000 : nil
            ),
            pluginID: Self.pluginID,
            sessionExists: { $0 == sessionID }
        )
    }
}

extension TabActivityState {
    var titleMarker: String {
        switch self {
        case .idle: ""
        case .working: "⏳"
        case .done: "✓"
        case .needsAttention: "⚠️"
        case .error: "✕"
        }
    }
}

extension PluginSessionStatus.State {
    var titleMarker: String {
        switch self {
        case .running: "⏳"
        case .waiting: "⚠️"
        case .completed: "✓"
        case .failed: "✕"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "hourglass"
        case .waiting: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
