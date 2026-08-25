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
    case invalidHooks(String)
    case duplicateCodexHooksSetting

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The existing agent configuration is not a JSON object."
        case .invalidHooks(let event):
            "The existing hooks configuration for \(event) is not an array."
        case .duplicateCodexHooksSetting:
            "Codex config.toml contains more than one hooks setting in [features]."
        }
    }
}

enum AgentHookInstallationState: Equatable, Sendable {
    case missing
    case updateAvailable
    case current

    var isInstalled: Bool { self != .missing }
}

struct AgentHookInstaller {
    static let marker = "_omg_agent_status"
    static let hookVersion = 2

    let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    func isInstalled(_ agent: SupportedAgent) -> Bool {
        installationState(agent).isInstalled
    }

    func installationState(
        _ agent: SupportedAgent
    ) -> AgentHookInstallationState {
        switch agent {
        case .codex, .claude:
            let url = homeURL.appendingPathComponent(
                agent == .codex ? ".codex/hooks.json" : ".claude/settings.json"
            )
            guard containsMarker(in: url) else { return .missing }
            guard hasCurrentJSONHooks(at: url, agent: agent) else {
                return .updateAvailable
            }
            if agent == .codex, !codexHooksEnabled() {
                return .updateAvailable
            }
            return .current
        case .pi:
            guard let source = try? String(
                contentsOf: piExtensionURL,
                encoding: .utf8
            ), source.contains("marker: \(Self.marker)") else {
                return .missing
            }
            return source == Self.piExtension ? .current : .updateAvailable
        }
    }

    static func remoteInstallerScript() throws -> String {
        let spec = Dictionary(uniqueKeysWithValues: [
            SupportedAgent.codex,
            SupportedAgent.claude,
        ].map { agent in
            let entries = hookEvents(agent).map { event, state, matcher in
                var entry: [String: Any] = [
                    marker: hookVersion,
                    "hooks": [[
                        "type": "command",
                        "command": hookCommand(agent: agent, state: state),
                    ]],
                ]
                if let matcher { entry["matcher"] = matcher }
                return ["event": event, "entry": entry]
            }
            return (agent.rawValue, entries)
        })
        let specData = try JSONSerialization.data(
            withJSONObject: spec,
            options: [.sortedKeys]
        )
        let specBase64 = specData.base64EncodedString()
        let piBase64 = Data(piExtension.utf8).base64EncodedString()
        return #"""
#!/usr/bin/env python3
# Auditable OMG Agent Status installer for an SSH account.
import base64
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

MARKER = "_omg_agent_status"
VERSION = 2
SPEC = json.loads(base64.b64decode("\#(specBase64)").decode("utf-8"))
PI_SOURCE = base64.b64decode("\#(piBase64)").decode("utf-8")
HOME = Path.home()


def backup(path):
    if not path.exists():
        return
    destination = path.with_name(path.name + ".omg-backup")
    if not destination.exists():
        shutil.copy2(path, destination)


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    descriptor, temporary = tempfile.mkstemp(prefix=".omg-agent-", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def is_legacy_omg(command):
    return isinstance(command, dict) and ": " + MARKER + ";" in str(command.get("command", ""))


def remove_omg(entry):
    if MARKER in entry:
        return None
    commands = entry.get("hooks")
    if not isinstance(commands, list):
        return entry
    remaining = [command for command in commands if not is_legacy_omg(command)]
    if len(remaining) == len(commands):
        return entry
    if not remaining:
        return None
    result = dict(entry)
    result["hooks"] = remaining
    return result


def load_hooks(path):
    if path.exists():
        root = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(root, dict):
            raise ValueError(str(path) + " is not a JSON object")
    else:
        root = {}
    hooks = root.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(str(path) + " hooks is not an object")
    return root, hooks


def validate_json(path, agent):
    _, hooks = load_hooks(path)
    for item in SPEC[agent]:
        existing = hooks.get(item["event"], [])
        if not isinstance(existing, list):
            raise ValueError(str(path) + " " + item["event"] + " is not an array")
        if not all(isinstance(entry, dict) for entry in existing):
            raise ValueError(str(path) + " " + item["event"] + " contains a non-object")


def install_json(path, agent):
    root, hooks = load_hooks(path)
    for item in SPEC[agent]:
        event = item["event"]
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            raise ValueError(str(path) + " " + event + " is not an array")
        hooks[event] = [entry for entry in (remove_omg(value) for value in existing) if entry is not None]
        hooks[event].append(item["entry"])
    root["hooks"] = hooks
    backup(path)
    atomic_write(path, json.dumps(root, indent=2, sort_keys=True) + "\n")


def enable_codex_hooks(path):
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = text.split("\n")
    try:
        section = next(index for index, line in enumerate(lines) if line.strip() == "[features]")
    except StopIteration:
        if lines and lines[-1]:
            lines.append("")
        lines.extend(["[features]", "hooks = true"])
    else:
        end = next((index for index in range(section + 1, len(lines)) if lines[index].strip().startswith("[")), len(lines))
        assignments = [index for index in range(section + 1, end) if re.match(r"^\s*hooks\s*=", lines[index])]
        if len(assignments) > 1:
            raise ValueError("Codex config.toml contains duplicate hooks settings")
        if assignments:
            indentation = lines[assignments[0]][:len(lines[assignments[0]]) - len(lines[assignments[0]].lstrip())]
            lines[assignments[0]] = indentation + "hooks = true"
        else:
            lines.insert(section + 1, "hooks = true")
    backup(path)
    atomic_write(path, "\n".join(lines))


codex_hooks = HOME / ".codex" / "hooks.json"
claude_hooks = HOME / ".claude" / "settings.json"
validate_json(codex_hooks, "codex")
validate_json(claude_hooks, "claude")
enable_codex_hooks(HOME / ".codex" / "config.toml")
install_json(codex_hooks, "codex")
install_json(claude_hooks, "claude")
pi_path = HOME / ".pi" / "agent" / "extensions" / "omg-agent-status.ts"
backup(pi_path)
atomic_write(pi_path, PI_SOURCE)
print("Installed current OMG agent hooks for Codex, Claude Code, and Pi.")
"""#
    }

    func install(_ agent: SupportedAgent) throws {
        switch agent {
        case .codex:
            try validateJSONHooks(
                at: homeURL.appendingPathComponent(".codex/hooks.json"),
                agent: agent
            )
            try ensureCodexHooksEnabled()
            try installJSONHooks(
                at: homeURL.appendingPathComponent(".codex/hooks.json"),
                agent: agent
            )
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
            try writeText(Self.piExtension, to: piExtensionURL)
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
            guard FileManager.default.fileExists(atPath: piExtensionURL.path) else {
                return
            }
            try FileManager.default.removeItem(at: piExtensionURL)
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
            return entries.contains(where: Self.containsOMGCommand)
        }
    }

    private func hasCurrentJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dictionary = root as? [String: Any],
              let hooks = dictionary["hooks"] as? [String: Any] else {
            return false
        }
        return Self.hookEvents(agent).allSatisfy { event, _, _ in
            guard let entries = hooks[event] as? [[String: Any]] else {
                return false
            }
            return entries.contains {
                $0[Self.marker] as? Int == Self.hookVersion
            }
        }
    }

    private func codexHooksEnabled() -> Bool {
        let url = homeURL.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let section = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[features]"
        }) else { return false }
        let end = lines[(section + 1)...].firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        } ?? lines.endIndex
        let values = lines[(section + 1)..<end].filter(Self.isHooksAssignment)
        guard values.count == 1 else { return false }
        return values[0].trimmingCharacters(in: .whitespaces)
            .range(
                of: #"^hooks\s*=\s*true\s*(?:#.*)?$"#,
                options: .regularExpression
            ) != nil
    }

    private func validateJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        let root = try loadJSONObject(at: url)
        let hooks = try hooksDictionary(root["hooks"])
        for (event, _, _) in Self.hookEvents(agent) {
            _ = try hookEntries(hooks[event], event: event)
        }
    }

    private func installJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        var root = try loadJSONObject(at: url)
        var hooks = try hooksDictionary(root["hooks"])
        for (event, state, matcher) in Self.hookEvents(agent) {
            let existing = try hookEntries(hooks[event], event: event)
            var entries = existing.compactMap(Self.removingOMGCommands)
            var entry: [String: Any] = [
                Self.marker: Self.hookVersion,
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
        guard root["hooks"] != nil else { return }
        var hooks = try hooksDictionary(root["hooks"])
        for key in Array(hooks.keys) {
            let entries = try hookEntries(hooks[key], event: key)
            let remaining = entries.compactMap(Self.removingOMGCommands)
            if remaining.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = remaining
            }
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func hooksDictionary(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw AgentHookInstallerError.invalidHooks("hooks")
        }
        return hooks
    }

    private func hookEntries(
        _ value: Any?,
        event: String
    ) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw AgentHookInstallerError.invalidHooks(event)
        }
        return entries
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
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        try writeData(data, to: url)
    }

    private func ensureCodexHooksEnabled() throws {
        let url = homeURL.appendingPathComponent(".codex/config.toml")
        var text: String
        if FileManager.default.fileExists(atPath: url.path) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            text = ""
        }
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
            let assignments = lines[(section + 1)..<end].indices.filter {
                Self.isHooksAssignment(lines[$0])
            }
            guard assignments.count <= 1 else {
                throw AgentHookInstallerError.duplicateCodexHooksSetting
            }
            if let hooks = assignments.first {
                let indentation = lines[hooks].prefix { $0.isWhitespace }
                lines[hooks] = "\(indentation)hooks = true"
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
        try writeText(text, to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeData(data, to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = attributes?[.posixPermissions] as? NSNumber ??
            NSNumber(value: 0o600)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func isHooksAssignment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^hooks\s*="#, options: .regularExpression) != nil
    }

    private static func containsOMGCommand(_ entry: [String: Any]) -> Bool {
        if entry[marker] != nil { return true }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains(where: isLegacyOMGCommand)
    }

    private static func removingOMGCommands(
        _ entry: [String: Any]
    ) -> [String: Any]? {
        if entry[marker] != nil { return nil }
        guard let commands = entry["hooks"] as? [[String: Any]] else {
            return entry
        }
        let remaining = commands.filter { !isLegacyOMGCommand($0) }
        guard remaining.count != commands.count else { return entry }
        guard !remaining.isEmpty else { return nil }
        var result = entry
        result["hooks"] = remaining
        return result
    }

    private static func isLegacyOMGCommand(_ command: [String: Any]) -> Bool {
        guard let value = command["command"] as? String else { return false }
        return value.contains(": \(marker);")
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
        let action = state == nil ? "end" : "start"
        var metadata = "type=app;omg_agent=\(agent.rawValue);omg_scope=%s"
        if let state { metadata += ";omg_state=\(state.rawValue)" }
        return ": \(marker); " +
            "omg_tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "omg_pgid=$(ps -o pgid= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "case \"$omg_tty\" in ''|*[!A-Za-z0-9/._-]*) exit 0;; esac; " +
            "case \"$omg_pgid\" in ''|*[!0-9]*) exit 0;; esac; " +
            "omg_scope=local; test -n \"${SSH_CONNECTION-}\" && omg_scope=remote; " +
            "printf '\\033]3008;\(action)=omg-agent-\(agent.rawValue)-%s;" +
            "\(metadata)\\007' \"$omg_pgid\" \"$omg_scope\" " +
            "> \"/dev/$omg_tty\" 2>/dev/null || true"
    }

    private static let piExtension = #"""
// OMG agent status integration for Pi.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";

const contextId = `omg-agent-pi-${process.pid}`;
const scope = process.env.SSH_CONNECTION ? "remote" : "local";
function report(state?: string, end = false) {
  let fd: number | undefined;
  try {
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=pi;omg_scope=${scope}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=pi;omg_scope=${scope};omg_state=${state}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
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

struct AgentActivityCandidate: Sendable {
    let activity: TabActivity
    let isFocused: Bool
}

enum AgentActivitySelection {
    static func preferred(
        _ candidates: [AgentActivityCandidate]
    ) -> TabActivity? {
        candidates.max { lhs, rhs in
            let lhsPriority = priority(lhs.activity.state)
            let rhsPriority = priority(rhs.activity.state)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.isFocused != rhs.isFocused {
                return !lhs.isFocused && rhs.isFocused
            }
            return false
        }?.activity
    }

    private static func priority(_ state: TabActivityState) -> Int {
        switch state {
        case .needsAttention: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        }
    }
}

struct AgentContextSignalReducer: Sendable {
    private enum Scope: String, Sendable {
        case local
        case remote
        case legacy
    }

    private struct Identity: Sendable {
        let processGroupID: Int?
    }

    private struct Record: Sendable {
        let activity: TabActivity
        let scope: Scope
        let processGroupID: Int?
    }

    private var activities: [String: Record] = [:]
    private var order: [String] = []

    var requiresForegroundValidation: Bool {
        guard let current = currentRecord else { return false }
        return current.scope == .local && current.processGroupID != nil
    }

    mutating func consume(_ signal: Ghostty.ContextSignal) -> AgentActivityUpdate? {
        guard signal.id.hasPrefix("omg-agent-") else { return nil }
        switch signal.action {
        case .end:
            return remove(signal.id)

        case .start:
            let metadata = Self.metadata(signal.metadata)
            guard metadata["type"] == "app",
                  let rawAgent = metadata["omg_agent"],
                  let agent = SupportedAgent(rawValue: rawAgent),
                  let identity = Self.identity(signal.id, agent: agent),
                  let rawState = metadata["omg_state"],
                  let state = Self.state(rawState) else { return nil }
            let scope = metadata["omg_scope"].flatMap(Scope.init) ?? .legacy
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
            activities[signal.id] = Record(
                activity: activity,
                scope: scope,
                processGroupID: identity.processGroupID
            )
            order.removeAll { $0 == signal.id }
            order.append(signal.id)
            return .set(activity)
        }
    }

    mutating func reconcileLocalForegroundProcess(
        _ foregroundPID: Int?
    ) -> AgentActivityUpdate? {
        guard let foregroundPID else { return nil }
        var removedCurrent = false
        while let currentID = order.last,
              let current = activities[currentID],
              current.scope == .local,
              let processGroupID = current.processGroupID,
              processGroupID != foregroundPID {
            activities.removeValue(forKey: currentID)
            order.removeLast()
            removedCurrent = true
        }
        guard removedCurrent else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    mutating func consumeRemotePrompt(
        _ signal: Ghostty.ContextSignal
    ) -> AgentActivityUpdate? {
        guard signal.action == .start,
              signal.id.hasPrefix("omg-ssh-"),
              Self.metadata(signal.metadata)["cwd"] != nil else { return nil }
        let previousID = order.last
        activities = activities.filter { $0.value.scope != .remote }
        order.removeAll { activities[$0] == nil }
        guard previousID != order.last else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private var currentRecord: Record? {
        order.last.flatMap { activities[$0] }
    }

    private mutating func remove(_ id: String) -> AgentActivityUpdate? {
        guard activities.removeValue(forKey: id) != nil else { return nil }
        let wasActive = order.last == id
        order.removeAll { $0 == id }
        guard wasActive else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private static func identity(
        _ id: String,
        agent: SupportedAgent
    ) -> Identity? {
        let prefix = "omg-agent-\(agent.rawValue)"
        if id == prefix { return Identity(processGroupID: nil) }
        guard id.hasPrefix(prefix + "-") else { return nil }
        let raw = id.dropFirst(prefix.count + 1)
        guard !raw.isEmpty,
              raw.count <= 20,
              raw.allSatisfy(\.isNumber),
              let value = Int(raw),
              value > 0 else { return nil }
        return Identity(processGroupID: value)
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
