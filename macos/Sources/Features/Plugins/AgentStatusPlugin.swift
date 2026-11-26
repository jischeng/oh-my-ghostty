import Foundation

enum AgentStatusPlugin {
    @MainActor static var isEnabled: Bool {
        OhMyGhosttySettings.shared.agentStatusHooksEnabled
    }
}

enum LocalAgentProcessDetector {
    static func detect(in commandLines: String) -> SupportedAgent? {
        for line in commandLines.split(separator: "\n") {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let executable = tokens.first else { continue }
            let normalizedExec: String
            if !executable.contains("/"), executable.hasPrefix("-"), !executable.hasPrefix("--") {
                normalizedExec = String(executable.dropFirst())
            } else {
                normalizedExec = executable
            }
            if let agent = exactAgent(normalizedExec) { return agent }
            let basename = URL(fileURLWithPath: normalizedExec).lastPathComponent.lowercased()
            let isWrapperOrPython = ["login", "env", "sh", "bash", "zsh", "fish", "python", "python3"]
                .contains(basename) || basename.hasPrefix("python3.")
            if isWrapperOrPython,
               let agent = tokens.dropFirst().compactMap(exactAgent).last {
                return agent
            }
            if ["node", "bun", "deno"].contains(basename) {
                let runtimeArguments = tokens.dropFirst().prefix(4)
                    .map { $0.lowercased() }
                    .joined(separator: " ")
                if let agent = SupportedAgent.allCases.first(where: { candidate in
                    candidate.definition.process.runtimeMarkers.contains {
                        runtimeArguments.contains($0.lowercased())
                    }
                }) { return agent }
            }
        }
        return nil
    }

    private static func exactAgent(_ token: String) -> SupportedAgent? {
        guard !token.isEmpty, !token.hasPrefix("-") else { return nil }
        let name = URL(fileURLWithPath: token).lastPathComponent.lowercased()
        if let direct = SupportedAgent.allCases.first(where: { agent in
            agent.definition.process.executables.contains {
                $0.lowercased() == name
            }
        }) {
            return direct
        }
        guard token.contains("/") else { return nil }
        let components = token.lowercased().split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[components.count - 2] == "versions",
              looksLikeVersionSegment(components[components.count - 1]) else {
            return nil
        }
        let vendorDir = components[components.count - 3]
        return SupportedAgent.allCases.first { agent in
            agent.definition.process.executables.contains { $0.lowercased() == vendorDir } ||
                agent.definition.process.runtimeMarkers.contains {
                    !$0.contains("/") && $0.lowercased() == vendorDir
                }
        }
    }

    private static func looksLikeVersionSegment(_ value: String) -> Bool {
        let stripped = value.hasPrefix("v") ? value.dropFirst() : value[...]
        guard let first = stripped.first, first.isASCII && first.isNumber else {
            return false
        }
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyz._+-".utf8)
        return stripped.utf8.count <= 64 && stripped.utf8.allSatisfy(allowed.contains)
    }
}

/// Hermes' gateway owns hooks, while the terminal client owns the pane. Resolve
/// identity from a live client and its per-TTY breadcrumb before accepting events.
enum HermesPaneStatus {
    struct Snapshot: Decodable, Equatable, Sendable {
        let pgid: Int
        let conversation: String?
        let cwd: String?
        let state: String
        let revision: String
    }

    static func script(tty: String) throws -> String {
        let data = try JSONEncoder().encode(tty)
        let encoded = data.base64EncodedString()
        return probe + "\nprint(json.dumps(snapshot(json.loads(base64.b64decode(\"\(encoded)\")))))\n"
    }

    static var localScript: String {
        probe + "\nprint(json.dumps(snapshots(), sort_keys=True))\n"
    }

    static let reporter = #"""
import hashlib, json, os, re, stat, subprocess, sys, tempfile, time
from pathlib import Path

def controlling_tty():
    for fd in (0, 1, 2):
        try:
            tty = os.ttyname(fd)
            if re.fullmatch(r"/dev/(?:ttys[0-9]+|pts/[0-9]+)", tty):
                return tty
        except OSError:
            pass
    try:
        raw = subprocess.run(
            ["ps", "-o", "tty=", "-p", str(os.getpid())],
            capture_output=True, text=True, timeout=1,
        ).stdout.strip()
        if re.fullmatch(r"(?:ttys[0-9]+|pts/[0-9]+)", raw):
            return "/dev/" + raw
    except (OSError, subprocess.SubprocessError):
        pass
    return None

def owns_controlling_tty(sid):
    if not os.environ.get("OMG_SESSION_ID") or not os.environ.get("OMG_RUNTIME_EVENT_SOCKET"):
        return False
    tty = controlling_tty()
    if not tty:
        return False
    home = Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))
    key = "tty-" + re.sub(r"[^A-Za-z0-9._-]", "-", tty.strip("/"))[:120]
    crumb_path = home / "terminal-sessions" / key
    try:
        info = crumb_path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 4096:
            return False
        with crumb_path.open() as stream:
            crumb = json.load(stream)
    except (OSError, ValueError, TypeError):
        return False
    return isinstance(crumb, dict) and crumb.get("session_id") == sid

def write_status_file(sid, state):
    directory = Path.home() / ".config/oh-my-ghostty/agent-status/hermes"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        return
    directory.chmod(0o700)
    key = hashlib.sha256(sid.encode()).hexdigest()
    target = directory / (key + ".json")
    if target.is_symlink():
        return
    fd, temporary = tempfile.mkstemp(prefix=".event-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"session_id": sid, "state": state, "time": time.time()}, stream)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def report():
    state = sys.argv[1] if len(sys.argv) == 2 else ""
    if state not in {"idle", "working", "done", "error", "needsAttention", "end"}:
        return
    payload = json.loads(sys.stdin.read(65537))
    sid = payload.get("session_id")
    if not isinstance(sid, str) or sid.startswith("test-"):
        return
    if not re.fullmatch(r"[A-Za-z0-9._][A-Za-z0-9._-]{0,127}", sid):
        return
    write_status_file(sid, state)
    runtime_bin = os.environ.get("OMG_RUNTIME_BIN")
    if runtime_bin and owns_controlling_tty(sid):
        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            try: cwd = os.getcwd()
            except OSError: cwd = "/"
        cmd = [runtime_bin, "report", "hermes", state, sid, cwd]
        if state == "working":
            cmd.extend(["--event", "prompt"])
        try:
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        except (OSError, subprocess.SubprocessError):
            pass

try:
    report()
except (ValueError, OSError, TypeError):
    pass
"""#

    // Executed locally or through the existing bounded SSH transport. Never infer
    // ownership from cwd or from the latest event on the host (both are ambiguous).
    static let probe = #"""
import base64, hashlib, json, os, re, stat, subprocess, time
from pathlib import Path

def read_object(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 4096:
        raise ValueError("invalid metadata file")
    with path.open() as stream:
        obj = json.load(stream)
    if not isinstance(obj, dict): raise ValueError("invalid object")
    return obj

def elapsed_seconds(text):
    days, _, rest = text.rpartition("-")
    values = [int(part) for part in rest.split(":")]
    seconds = sum(value * (60 ** index) for index, value in enumerate(reversed(values)))
    return seconds + (int(days) * 86400 if days else 0)

def valid_tty(tty):
    return isinstance(tty, str) and re.fullmatch(r"/dev/(?:ttys[0-9]+|pts/[0-9]+)", tty)

def is_hermes_client(command):
    argv = command.split()
    if not argv: return False
    runtime = Path(argv[0]).name.lower()
    node_client = runtime in {"node", "bun"} and any(
        re.search(r"/(?:ui-tui/(?:dist|src)|hermes_cli/tui_dist)/entry\.(?:js|tsx?)$", arg)
        and "hermes" in arg.lower() for arg in argv[1:6])
    python_client = (runtime.startswith("python") and "/.hermes/" in argv[0]
                     and "from hermes_cli.main import main" in command
                     and "sys.exit(main())" in command)
    return node_client or python_client

def foreground_hermes_client(flags, command):
    return "+" in flags and is_hermes_client(command)

def select_client(candidates):
    groups = {candidate[1] for candidate in candidates}
    if len(groups) != 1: return None
    return candidates[0]

def read_session(tty, pid, pgid, started):
    output = {"pgid": pgid, "state": "idle", "revision": "client:" + str(pid)}
    try:
        home = Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))
        key = "tty-" + re.sub(r"[^A-Za-z0-9._-]", "-", tty.strip("/"))[:120]
        crumb = read_object(home / "terminal-sessions" / key)
        sid, timestamp = crumb.get("session_id"), crumb.get("ts")
        if (not isinstance(sid, str) or sid.startswith("test-")
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", sid)
            or not isinstance(timestamp, (int, float)) or timestamp < started - 5):
            return output
        output["conversation"] = sid
        cwd = crumb.get("cwd")
        if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 4096 and "\0" not in cwd:
            output["cwd"] = cwd
        output["revision"] += ":" + sid
        status_path = Path.home() / ".config/oh-my-ghostty/agent-status/hermes"
        event = read_object(status_path / (hashlib.sha256(sid.encode()).hexdigest() + ".json"))
        stamp = event.get("time")
        state = event.get("state")
        if (event.get("session_id") == sid and isinstance(stamp, (int, float))
            and started - 5 <= stamp <= time.time() + 5
            and state in {"idle", "working", "done", "error", "needsAttention"}):
            output["state"] = state
            output["revision"] += ":" + str(stamp)
    except (ValueError, OSError, TypeError):
        pass
    return output

def snapshot(tty):
    try:
        if not valid_tty(tty): return {}
        result = subprocess.run(["ps", "-t", tty[5:], "-o", "pid=,pgid=,stat=,args="],
                                capture_output=True, text=True, timeout=2)
        if result.returncode != 0: return {}
        candidates = []
        for line in result.stdout.splitlines():
            fields = line.split(None, 3)
            if len(fields) != 4: continue
            pid, pgid, flags, command = fields
            if not foreground_hermes_client(flags, command): continue
            candidates.append((int(pid), int(pgid)))
        selected = select_client(candidates)
        if selected is None: return {}
        pid, pgid = selected
        age_result = subprocess.run(["ps", "-p", str(pid), "-o", "etime="],
                             capture_output=True, text=True, timeout=2).stdout.strip()
        started = time.time() - elapsed_seconds(age_result)
        return read_session(tty, pid, pgid, started)
    except (ValueError, OSError, TypeError, subprocess.SubprocessError):
        return {}

def snapshots():
    # One process-table read serves every local pane. A failed read must remain
    # distinguishable from a successful scan with no Hermes clients.
    result = subprocess.run(
        ["ps", "-axo", "pid=,pgid=,tty=,stat=,etime=,args="],
        capture_output=True, text=True, timeout=2)
    if result.returncode != 0:
        detail = (result.stderr or "").strip()[:512]
        raise RuntimeError("ps process-table scan failed" + (": " + detail if detail else ""))

    by_tty = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6: continue
        pid, pgid, raw_tty, flags, age, command = fields
        if not re.fullmatch(r"(?:ttys[0-9]+|pts/[0-9]+)", raw_tty): continue
        if not foreground_hermes_client(flags, command): continue
        try:
            candidate = (int(pid), int(pgid), elapsed_seconds(age))
        except ValueError:
            continue
        by_tty.setdefault("/dev/" + raw_tty, []).append(candidate)

    result_by_tty = {}
    for tty, candidates in by_tty.items():
        selected = select_client(candidates)
        if selected is None: continue
        pid, pgid, elapsed = selected
        started = time.time() - elapsed
        result_by_tty[tty] = read_session(tty, pid, pgid, started)
    return result_by_tty
"""#
}

enum AgentHookInstallerError: LocalizedError {
    case invalidConfiguration
    case invalidHooks(String)
    case invalidDetectorMarker(String)
    case duplicateCodexHooksSetting

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The existing agent configuration is not a JSON object."
        case .invalidHooks(let event):
            "The existing hooks configuration for \(event) is not an array."
        case .invalidDetectorMarker(let agent):
            "The existing detector marker for \(agent) is not owned by OMG."
        case .duplicateCodexHooksSetting:
            "Codex config.toml contains more than one hooks setting in [features]."
        }
    }
}

enum AgentHookInstallationState: String, Codable, Equatable, Sendable {
    case missing
    case updateAvailable
    case current

    var isInstalled: Bool { self != .missing }
}

enum AgentHookRemoteAction: String {
    case status
    case install
    case remove
}

struct AgentHookInstaller {
    static let marker = "_omg_agent_status"
    static let hookVersion = 16
    static let detectorMarkerVersion = 1
    static let didChangeNotification = Notification.Name(
        "com.oh-my-ghostty.agentIntegrationDidChange"
    )
    static let changedAgentUserInfoKey = "agent"

    private struct DetectorMarker: Codable, Equatable {
        let owner: String
        let version: Int
        let agent: String
    }

    let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    func isInstalled(_ agent: SupportedAgent) -> Bool {
        // A stale YAML integration is still installed. Runtime detection must
        // not revalidate every event/helper version just to establish presence.
        if agent.definition.hook.kind == .yaml { return Self.yamlBlockPresent(at: hookURL(for: agent)) }
        return installationState(agent).isInstalled
    }

    /// Whether the user explicitly removed this Agent's detector integration.
    ///
    /// Automatic adoption consults this so a removed detector is never silently
    /// reinstalled; an explicit Install clears the record and re-enables it.
    func isDetectorRemovedByUser(_ agent: SupportedAgent) -> Bool {
        Self.supportsDetector(for: agent) && hasTombstone(agent)
    }

    /// Whether the user explicitly removed this Agent's Hook integration.
    ///
    /// Automatic adoption consults this so an uninstalled Hook is never silently
    /// reinstalled; an explicit Install clears the record and re-enables it.
    func isHookRemovedByUser(_ agent: SupportedAgent) -> Bool {
        !Self.supportsDetector(for: agent) && hasHookTombstone(agent)
    }

    /// Reconciles detector-only Agent markers on every launch.
    ///
    /// Detector-only agents (`hook.kind == .none`) were implicitly enabled before
    /// explicit Install/Remove controls existed. A single global sentinel used to
    /// record that one-time migration and then short-circuit forever, which meant
    /// a detector-only Agent bundled after the sentinel was written could never be
    /// installed, and a detector version bump could never reach existing users.
    /// Reconciliation is per Agent and idempotent instead:
    ///
    /// - a current marker is left untouched;
    /// - a missing marker is installed unless the user explicitly removed it;
    /// - a stale OMG-owned marker is refreshed;
    /// - a marker that is not OMG-owned is never overwritten.
    ///
    /// An explicit Remove writes a per-Agent tombstone, so reconciliation can never
    /// resurrect a detector the user turned off. Removals recorded by the legacy
    /// global sentinel cannot be distinguished from detectors that simply did not
    /// exist yet, so those are not carried over: a detector removed before this
    /// version is re-enabled once and can be removed again, whereas guessing would
    /// permanently hide every detector-only Agent added since the sentinel.
    /// `supportsDetector(for:)` is the capability check; detectors that grew a real
    /// vendor Hook adapter are skipped.
    func migrateImplicitDetectorsIfNeeded() throws {
        for agent in SupportedAgent.allCases where Self.supportsDetector(for: agent) {
            guard !hasTombstone(agent) else { continue }
            let url = detectorMarkerURL(agent)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try installDetectorMarker(agent)
                continue
            }
            // Content that is not an OMG marker (or is malformed) is left alone so
            // reconciliation can never clobber a file it does not own.
            guard let marker = validDetectorMarker(
                at: url,
                expectedAgent: agent.rawValue
            ) else { continue }
            if marker.version != Self.detectorMarkerVersion {
                try installDetectorMarker(agent)
            }
        }
    }

    /// Whether a detector marker is the only way to observe this Agent.
    ///
    /// Kept as a single predicate so reconciliation, install and status agree on
    /// which Agents are detector-only as manifests migrate to real Hook adapters.
    static func supportsDetector(for agent: SupportedAgent) -> Bool {
        agent.definition.hook.kind == .none
    }

    func installationState(
        _ agent: SupportedAgent
    ) -> AgentHookInstallationState {
        let definition = agent.definition
        switch definition.hook.kind {
        case .json:
            let url = hookURL(for: agent)
            guard containsMarker(in: url, agent: agent) else { return .missing }
            guard hasCurrentJSONHooks(at: url, agent: agent) else {
                return .updateAvailable
            }
            if agent == .codex, !codexHooksEnabled() {
                return .updateAvailable
            }
            return .current
        case .plugin:
            guard let expected = Self.pluginSource(for: agent),
                  let source = try? String(
                      contentsOf: hookURL(for: agent),
                      encoding: .utf8
                  ), source.contains("marker: \(Self.marker)") else {
                return .missing
            }
            return source == expected ? .current : .updateAvailable
        case .toml:
            guard let source = try? String(
                contentsOf: hookURL(for: agent),
                encoding: .utf8
            ), source.contains(Self.tomlBlockBegin) else { return .missing }
            return source.contains("_omg_agent_status_v\(Self.hookVersion)")
                ? .current : .updateAvailable
        case .scripts:
            let directory = hookURL(for: agent)
            let current = agent.definition.hook.events.allSatisfy { event in
                let url = directory.appendingPathComponent(event.name)
                return (try? String(contentsOf: url, encoding: .utf8))?
                    .contains("_omg_agent_status_v\(Self.hookVersion)") == true
            }
            return current ? .current : .missing
        case .yaml:
            let url = hookURL(for: agent)
            guard yamlHooksCurrent(at: url, agent: agent),
                  FileManager.default.fileExists(
                      atPath: yamlHookScriptURL(agent).path
                  ) else {
                return Self.yamlBlockPresent(at: url) ? .updateAvailable : .missing
            }
            return .current
        case .none:
            return detectorInstallationState(agent)
        }
    }

    static func remoteInstallerScript(
        action: AgentHookRemoteAction = .install,
        agents: [SupportedAgent]? = nil
    ) throws -> String {
        let selected = agents ?? SupportedAgent.allCases.filter { $0.definition.hook.kind != .none }
        guard selected.allSatisfy({ $0.definition.hook.kind != .none }) else {
            throw AgentHookInstallerError.invalidConfiguration
        }
        let selectionData = try JSONEncoder().encode(selected.map(\.rawValue))
        let jsonAgents = SupportedAgent.allCases.filter {
            $0.definition.hook.kind == .json
        }
        let spec = Dictionary(uniqueKeysWithValues: jsonAgents.map { agent in
            let entries = hookEvents(agent).map { event, state, matcher in
                [
                    "event": event,
                    "entry": jsonHookEntry(
                        agent: agent,
                        event: event,
                        state: state,
                        matcher: matcher
                    ),
                ]
            }
            return (agent.rawValue, [
                "path": agent.definition.hook.path,
                "dialect": (
                    agent.definition.hook.dialect ?? .nested
                ).rawValue,
                "entries": entries,
            ] as [String: Any])
        })
        let specData = try JSONSerialization.data(
            withJSONObject: spec,
            options: [.sortedKeys]
        )
        let specBase64 = specData.base64EncodedString()
        let auxiliaryPairs: [(String, [String: Any])] =
            SupportedAgent.allCases.compactMap { agent in
                let hook = agent.definition.hook
                switch hook.kind {
                case .plugin:
                    guard let source = pluginSource(for: agent) else { return nil }
                    return (agent.rawValue, [
                        "kind": "plugin", "path": hook.path, "source": source,
                    ])
                case .toml, .scripts, .yaml:
                    let entries = hook.events.map { event in
                        let cmd: String = if hook.kind == .yaml {
                            yamlHookCommand(agent: agent, state: event.state)
                        } else {
                            hookCommand(
                                agent: agent,
                                event: event.name,
                                state: event.state,
                                attentionKind: attentionKind(
                                    event: event.name,
                                    matcher: event.matcher,
                                    state: event.state
                                )
                            )
                        }
                        var item: [String: Any] = [
                            "event": event.name,
                            "command": cmd,
                        ]
                        if let matcher = event.matcher { item["matcher"] = matcher }
                        return item
                    }
                    var payload: [String: Any] = [
                        "kind": hook.kind.rawValue,
                        "path": hook.path,
                        "entries": entries,
                    ]
                    if hook.kind == .yaml {
                        payload["script"] = Self.yamlHookScriptPath(agent)
                        payload["source"] = Self.yamlHookScriptSource(for: agent)
                    }
                    return (agent.rawValue, payload)
                case .none, .json:
                    return nil
                }
            }
        let auxiliaryPayload = Dictionary(uniqueKeysWithValues: auxiliaryPairs)
        let auxiliaryData = try JSONSerialization.data(
            withJSONObject: auxiliaryPayload,
            options: [.sortedKeys]
        )
        let auxiliaryBase64 = auxiliaryData.base64EncodedString()
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
VERSION = \#(hookVersion)
SPEC = json.loads(base64.b64decode("\#(specBase64)").decode("utf-8"))
AUXILIARY = json.loads(base64.b64decode("\#(auxiliaryBase64)").decode("utf-8"))
HOME = Path.home()
ACTION = "\#(action.rawValue)"
SELECTED = json.loads(base64.b64decode("\#(selectionData.base64EncodedString())"))


def ensure_not_symlink(path):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("refusing symbolic link: " + str(path))


def write_private_backup(source, destination):
    ensure_not_symlink(source)
    ensure_not_symlink(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    payload = source.read_bytes()
    descriptor, temporary = tempfile.mkstemp(prefix=".omg-bak-", dir=destination.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if destination.is_symlink():
            raise ValueError("refusing symbolic link: " + str(destination))
        os.replace(temporary, destination)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def backup(path):
    ensure_not_symlink(path)
    if not path.exists() or path.is_dir():
        return
    destination = path.with_name(path.name + ".omg-backup")
    ensure_not_symlink(destination)
    if not destination.exists():
        write_private_backup(path, destination)


def atomic_write(path, content, default_mode=0o600, force_mode=None):
    ensure_not_symlink(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    ensure_not_symlink(path)
    exists_reg = False
    existing_mode = default_mode
    try:
        st = path.lstat()
        if stat.S_ISLNK(st.st_mode):
            raise ValueError("refusing symbolic link: " + str(path))
        if stat.S_ISREG(st.st_mode):
            exists_reg = True
            existing_mode = stat.S_IMODE(st.st_mode)
    except FileNotFoundError:
        pass
    if exists_reg and ".config/oh-my-ghostty/agent-status" not in path.as_posix():
        write_private_backup(path, path.with_name(path.name + ".omg.bak"))
    mode = force_mode if force_mode is not None else (existing_mode if exists_reg else default_mode)
    descriptor, temporary = tempfile.mkstemp(prefix=".omg-agent-", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.is_symlink():
            raise ValueError("refusing symbolic link: " + str(path))
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
    if MARKER in entry or (": " + MARKER + ";") in str(entry.get("command", "")):
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


def load_hooks(path, agent):
    if path.exists():
        root = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(root, dict):
            raise ValueError(str(path) + " is not a JSON object")
    else:
        root = {}
    key = "omg-agent-status" if SPEC[agent].get("dialect") == "antigravity" else "hooks"
    hooks = root.get(key, {})
    if not isinstance(hooks, dict):
        raise ValueError(str(path) + " hooks is not an object")
    return root, hooks


def validate_json(path, agent):
    root, hooks = load_hooks(path, agent)
    if SPEC[agent].get("dialect") == "antigravity" and "omg-agent-status" in root:
        if not any(event != "enabled" for event in hooks):
            raise ValueError(str(path) + " omg-agent-status is owned by another hook")
        for event, entries in hooks.items():
            if event == "enabled": continue
            if not isinstance(entries, list) or not entries or not all(
                    isinstance(entry, dict) and remove_omg(entry) is None for entry in entries):
                raise ValueError(str(path) + " omg-agent-status is owned by another hook")
    for item in SPEC[agent]["entries"]:
        existing = hooks.get(item["event"], [])
        if not isinstance(existing, list):
            raise ValueError(str(path) + " " + item["event"] + " is not an array")
        if not all(isinstance(entry, dict) for entry in existing):
            raise ValueError(str(path) + " " + item["event"] + " contains a non-object")


def install_json(path, agent):
    root, hooks = load_hooks(path, agent)
    named = SPEC[agent].get("dialect") == "antigravity"
    if named:
        hooks["enabled"] = True
    else:
        for existing_event in list(hooks.keys()):
            existing_entries = hooks.get(existing_event)
            if isinstance(existing_entries, list) and all(isinstance(entry, dict) for entry in existing_entries):
                cleaned = [entry for entry in (remove_omg(value) for value in existing_entries) if entry is not None]
                if cleaned:
                    hooks[existing_event] = cleaned
                else:
                    del hooks[existing_event]
    cleaned_events = set()
    for item in SPEC[agent]["entries"]:
        event = item["event"]
        if event not in cleaned_events:
            cleaned_events.add(event)
            existing = hooks.get(event, [])
            if not isinstance(existing, list):
                raise ValueError(str(path) + " " + event + " is not an array")
            hooks[event] = [entry for entry in (remove_omg(value) for value in existing) if entry is not None]
        hooks[event].append(item["entry"])
    root["omg-agent-status" if named else "hooks"] = hooks
    if SPEC[agent].get("dialect") in ("cursor", "copilot") and "version" not in root:
        root["version"] = 1
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


def strip_toml_block(text):
    begin = "# >>> OMG agent-status hooks (managed; do not edit) >>>"
    end = "# <<< OMG agent-status hooks <<<"
    start = text.find(begin)
    finish = text.find(end, start + len(begin)) if start >= 0 else -1
    return text if start < 0 or finish < 0 else text[:start] + text[finish + len(end):]


def strip_yaml_block(text):
    return strip_toml_block(text)


def install_auxiliary(item):
    path = expand(item["path"])
    kind = item["kind"]
    if kind == "plugin":
        backup(path)
        atomic_write(path, item["source"])
        return
    if kind == "toml":
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        base = strip_toml_block(existing).strip("\n")
        lines = ["# >>> OMG agent-status hooks (managed; do not edit) >>>"]
        for entry in item["entries"]:
            lines.extend(["[[hooks]]", 'event = "' + entry["event"] + '"'])
            if entry.get("matcher") is not None:
                lines.append('matcher = "' + entry["matcher"] + '"')
            lines.extend(["command = '''" + entry["command"] + "'''", "timeout = 5", ""])
        if lines[-1] == "": lines.pop()
        lines.append("# <<< OMG agent-status hooks <<<")
        backup(path)
        atomic_write(path, (base + "\n\n" if base else "") + "\n".join(lines) + "\n")
        return
    if kind == "yaml":
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        base = strip_yaml_block(existing).strip("\n")
        if any(line.startswith("hooks:") for line in base.split("\n")):
            raise ValueError(str(path) + " already has a hooks: key")
        # The hook command delegates to a helper script: Hermes may run shell hooks
        # from a headless daemon that owns no TTY, so the script records the state
        # instead of writing OSC from the hook process.
        script_path = expand(item["script"])
        script_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            script_path.parent.chmod(0o700)
        except OSError:
            pass
        backup(script_path)
        atomic_write(script_path, item["source"], force_mode=0o700)
        lines = [
            "# >>> OMG agent-status hooks (managed; do not edit) >>>",
            "hooks_auto_accept: true",
            "hooks:",
        ]
        for entry in item["entries"]:
            lines.append("  " + entry["event"] + ":")
            lines.append("    - command: >-")
            lines.append("        " + entry["command"].replace("\n", " "))
            lines.append("      timeout: 5")
        lines.append("# <<< OMG agent-status hooks <<<")
        backup(path)
        atomic_write(path, (base + "\n\n" if base else "") + "\n".join(lines) + "\n")
        return
    if kind == "scripts":
        path.mkdir(parents=True, exist_ok=True)
        for entry in item["entries"]:
            target = path / entry["event"]
            if target.exists() and (": " + MARKER + ";") not in target.read_text(encoding="utf-8"):
                raise ValueError(str(target) + " is owned by another hook")
            backup(target)
            atomic_write(target, "#!/bin/sh\n" + entry["command"] + "\n", force_mode=0o700)


def expand(raw):
    return HOME / raw[2:] if raw.startswith("~/") else Path(raw)


def state(agent):
    if agent in SPEC:
        item = SPEC[agent]
        path = expand(item["path"])
        if not path.exists(): return "missing"
        root, hooks = load_hooks(path, agent)
        owned = any(remove_omg(entry) != entry for entries in hooks.values()
                    if isinstance(entries, list) for entry in entries if isinstance(entry, dict))
        if not owned: return "missing"
        current = all(item_entry["entry"] in hooks.get(item_entry["event"], [])
                      for item_entry in item["entries"])
        if item.get("dialect") == "antigravity":
            current = current and hooks.get("enabled", True) is not False
        if agent == "codex":
            config = HOME / ".codex/config.toml"
            text = config.read_text(encoding="utf-8") if config.exists() else ""
            section = re.search(r"(?ms)^\s*\[features\]\s*\n(.*?)(?=^\s*\[|\Z)", text)
            current = current and section is not None and re.search(
                r"(?m)^\s*hooks\s*=\s*true\s*(?:#.*)?$", section.group(1)) is not None
        return "current" if current else "updateAvailable"
    if agent in AUXILIARY:
        item = AUXILIARY[agent]
        path = expand(item["path"])
        if item["kind"] == "scripts":
            texts = [(path / entry["event"]).read_text(encoding="utf-8")
                     if (path / entry["event"]).exists() else "" for entry in item["entries"]]
            if not any(MARKER in text for text in texts): return "missing"
            return "current" if all("_omg_agent_status_v" + str(VERSION) in text for text in texts) else "updateAvailable"
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        if item["kind"] == "yaml":
            if "# >>> OMG agent-status hooks" not in text: return "missing"
            script = expand(item["script"]) if item.get("script") else None
            if script is None or not script.is_file(): return "missing"
            script_text = script.read_text(encoding="utf-8", errors="replace")
            current = ("_omg_agent_status v" + str(VERSION)) in script_text and all(
                (entry["event"] + ":") in text for entry in item["entries"])
            return "current" if current else "updateAvailable"
        if MARKER not in text and "# >>> OMG agent-status hooks" not in text: return "missing"
        current = text == item["source"] if item["kind"] == "plugin" else "_omg_agent_status_v" + str(VERSION) in text
        return "current" if current else "updateAvailable"
    raise ValueError("No remote hook for this agent")


def remove(agent):
    if agent in SPEC:
        path = expand(SPEC[agent]["path"])
        if not path.exists(): return
        root, hooks = load_hooks(path, agent)
        if SPEC[agent].get("dialect") == "antigravity":
            if "omg-agent-status" not in root: return
            validate_json(path, agent)
            del root["omg-agent-status"]
            backup(path)
            atomic_write(path, json.dumps(root, indent=2, sort_keys=True) + "\n")
            return
        for event, entries in hooks.items():
            if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
                raise ValueError(str(path) + " invalid hooks")
            hooks[event] = [entry for entry in (remove_omg(value) for value in entries) if entry is not None]
        root["hooks"] = hooks
        backup(path)
        atomic_write(path, json.dumps(root, indent=2, sort_keys=True) + "\n")
    elif agent in AUXILIARY:
        item = AUXILIARY[agent]
        path = expand(item["path"])
        if item["kind"] == "scripts":
            for entry in item["entries"]:
                target = path / entry["event"]
                if target.exists() and (": " + MARKER + ";") in target.read_text(encoding="utf-8"):
                    backup(target)
                    target.unlink()
        elif path.exists():
            text = path.read_text(encoding="utf-8")
            if item["kind"] == "toml":
                backup(path)
                atomic_write(path, strip_toml_block(text))
            elif item["kind"] == "yaml":
                if "# >>> OMG agent-status hooks" in text:
                    backup(path)
                    atomic_write(path, strip_yaml_block(text).strip("\n") + ("\n" if strip_yaml_block(text).strip() else ""))
                for extra in (item.get("script"), (item.get("script") or "").replace("-hook.sh", ".status")):
                    if not extra: continue
                    target = expand(extra)
                    try:
                        if target.is_file(): target.unlink()
                    except OSError:
                        pass
            elif "marker: " + MARKER in text:
                backup(path)
                path.unlink()


if ACTION == "status":
    print(json.dumps({agent: state(agent) for agent in SELECTED}))
elif ACTION == "remove":
    for agent in SELECTED: remove(agent)
elif ACTION == "install":
    for agent in SELECTED:
        if agent in SPEC: validate_json(expand(SPEC[agent]["path"]), agent)
    for agent in SELECTED:
        if agent in SPEC:
            if agent == "codex": enable_codex_hooks(HOME / ".codex/config.toml")
            install_json(expand(SPEC[agent]["path"]), agent)
        elif agent in AUXILIARY:
            install_auxiliary(AUXILIARY[agent])
    print("Installed current OMG agent hooks.")
else:
    raise ValueError("Unknown OMG integration action")
"""#
    }

    func install(_ agent: SupportedAgent) throws {
        let url = hookURL(for: agent)
        switch agent.definition.hook.kind {
        case .json:
            try validateJSONHooks(at: url, agent: agent)
            if agent == .codex { try ensureCodexHooksEnabled() }
            try installJSONHooks(at: url, agent: agent)
        case .plugin:
            guard let source = Self.pluginSource(for: agent) else {
                throw AgentHookInstallerError.invalidConfiguration
            }
            try backupIfNeeded(url)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeText(source, to: url)
        case .toml:
            try installTOMLHooks(at: url, agent: agent)
        case .scripts:
            try installScriptHooks(at: url, agent: agent)
        case .yaml:
            try installYAMLHooks(at: url, agent: agent)
            try installYAMLHookScript(for: agent)
        case .none:
            // An explicit Install overrides an earlier explicit Remove.
            try removeTombstone(agent)
            try installDetectorMarker(agent)
        }
        if !Self.supportsDetector(for: agent) {
            try removeHookTombstone(agent)
        }
        notifyChanged(agent)
    }

    func uninstall(_ agent: SupportedAgent) throws {
        let url = hookURL(for: agent)
        switch agent.definition.hook.kind {
        case .json:
            try removeJSONHooks(at: url, agent: agent)
        case .plugin:
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        case .toml:
            try removeTOMLHooks(at: url)
        case .scripts:
            try removeScriptHooks(at: url, agent: agent)
        case .yaml:
            try removeYAMLHooks(at: url)
            let scriptURL = yamlHookScriptURL(agent)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                try FileManager.default.removeItem(at: scriptURL)
            }
            let statusURL = agentStatusURL(agent)
            if FileManager.default.fileExists(atPath: statusURL.path) {
                try FileManager.default.removeItem(at: statusURL)
            }
        case .none:
            try removeDetectorMarker(agent)
        }
        if !Self.supportsDetector(for: agent) {
            try writeHookTombstone(agent.rawValue)
        }
        notifyChanged(agent)
    }

    private func notifyChanged(_ agent: SupportedAgent) {
        let post = {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: nil,
                userInfo: [Self.changedAgentUserInfoKey: agent.rawValue]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private func detectorInstallationState(
        _ agent: SupportedAgent
    ) -> AgentHookInstallationState {
        let url = detectorMarkerURL(agent)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let marker = validDetectorMarker(
            at: url,
            expectedAgent: agent.rawValue
        ) else { return .updateAvailable }
        return marker.version == Self.detectorMarkerVersion
            ? .current : .updateAvailable
    }

    private func installDetectorMarker(_ agent: SupportedAgent) throws {
        try writeDetectorMarker(agent: agent.rawValue, to: detectorMarkerURL(agent))
    }

    private func writeDetectorMarker(agent: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var data = try JSONEncoder().encode(DetectorMarker(
            owner: Self.marker,
            version: Self.detectorMarkerVersion,
            agent: agent
        ))
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func removeDetectorMarker(_ agent: SupportedAgent) throws {
        let url = detectorMarkerURL(agent)
        if FileManager.default.fileExists(atPath: url.path) {
            guard validDetectorMarker(
                at: url,
                expectedAgent: agent.rawValue
            ) != nil else {
                throw AgentHookInstallerError.invalidDetectorMarker(agent.rawValue)
            }
            try FileManager.default.removeItem(at: url)
        }
        // Record the removal before returning so reconciliation cannot reinstall it.
        try writeTombstone(agent.rawValue)
    }

    private func writeTombstone(_ agent: String) throws {
        try writeDetectorMarker(agent: agent, to: detectorTombstoneURL(agent))
    }

    private func hasTombstone(_ agent: SupportedAgent) -> Bool {
        validDetectorMarker(
            at: detectorTombstoneURL(agent.rawValue),
            expectedAgent: agent.rawValue
        ) != nil
    }

    private func removeTombstone(_ agent: SupportedAgent) throws {
        let url = detectorTombstoneURL(agent.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard validDetectorMarker(
            at: url,
            expectedAgent: agent.rawValue
        ) != nil else {
            throw AgentHookInstallerError.invalidDetectorMarker(agent.rawValue)
        }
        try FileManager.default.removeItem(at: url)
    }

    private func validDetectorMarker(
        at url: URL,
        expectedAgent: String
    ) -> DetectorMarker? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        ((attributes[.size] as? NSNumber)?.intValue ?? 4_097) <= 4_096,
        (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
        let data = try? Data(contentsOf: url),
        let marker = try? JSONDecoder().decode(DetectorMarker.self, from: data),
        marker.owner == Self.marker,
        marker.agent == expectedAgent else { return nil }
        return marker
    }

    private var detectorDirectoryURL: URL {
        homeURL.appendingPathComponent(".config/oh-my-ghostty/agent-detectors")
    }

    private func detectorMarkerURL(_ agent: SupportedAgent) -> URL {
        detectorDirectoryURL.appendingPathComponent("\(agent.rawValue).json")
    }

    /// Path of the status line a YAML-hook Agent's helper script writes.
    func agentStatusURL(_ agent: SupportedAgent) -> URL {
        homeURL
            .appendingPathComponent(".config/oh-my-ghostty/agent-status")
            .appendingPathComponent("\(agent.rawValue).status")
    }

    /// Per-Agent record of an explicit removal. Dot-prefixed so it cannot collide
    /// with any `SupportedAgent.rawValue` marker file.
    private func detectorTombstoneURL(_ agent: String) -> URL {
        detectorDirectoryURL.appendingPathComponent(".removed-\(agent).json")
    }

    private func hookTombstoneURL(_ agent: String) -> URL {
        detectorDirectoryURL.appendingPathComponent(".removed-hook-\(agent).json")
    }

    private func writeHookTombstone(_ agent: String) throws {
        try writeDetectorMarker(agent: agent, to: hookTombstoneURL(agent))
    }

    private func hasHookTombstone(_ agent: SupportedAgent) -> Bool {
        validDetectorMarker(
            at: hookTombstoneURL(agent.rawValue),
            expectedAgent: agent.rawValue
        ) != nil
    }

    private func removeHookTombstone(_ agent: SupportedAgent) throws {
        let url = hookTombstoneURL(agent.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard validDetectorMarker(
            at: url,
            expectedAgent: agent.rawValue
        ) != nil else {
            throw AgentHookInstallerError.invalidDetectorMarker(agent.rawValue)
        }
        try FileManager.default.removeItem(at: url)
    }

    private static let tomlBlockBegin =
        "# >>> OMG agent-status hooks (managed; do not edit) >>>"
    private static let tomlBlockEnd = "# <<< OMG agent-status hooks <<<"

    private static let yamlBlockBegin =
        "# >>> OMG agent-status hooks (managed; do not edit) >>>"
    private static let yamlBlockEnd = "# <<< OMG agent-status hooks <<<"

    /// Marker-delimited YAML block: the commands OMG owns inside a YAML config.
    /// Kept free of anchors and nested user content so a plain block replace is
    /// safe and unrelated configuration is preserved byte-for-byte.
    private func installYAMLHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        try validateYAMLHooks(existing)
        let base = Self.removingYAMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        var lines = [
            Self.yamlBlockBegin,
            "hooks_auto_accept: true",
            "hooks:",
        ]
        for event in agent.definition.hook.events {
            // Hermes reads `hooks: { <event>: [ {command, timeout}, ... ] }`.
            // The nested list form keeps unrelated hooks on the same event intact.
            lines.append("  \(event.name):")
            lines.append("    - command: >-")
            let command = Self.yamlFoldedScalar(
                Self.yamlHookCommand(agent: agent, state: event.state)
            )
            lines.append("        \(command)")
            lines.append("      timeout: 5")
        }
        lines.append(Self.yamlBlockEnd)
        let block = lines.joined(separator: "\n")
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeText(base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n", to: url)
    }

    /// Generates the command for a YAML-embedded hook (Hermes).
    ///
    /// Hermes runs shell hooks from its long-lived gateway process when one is
    /// active: the hook's parent is that daemon, which owns no TTY and belongs to
    /// its own process group. An OSC write from there reaches no pane, and any pgid
    /// it reports is unrelated to the pane's foreground process group. The command
    /// therefore records the event in a status file; the host resolves which pane
    /// owns the session and writes the OSC itself.
    private static func yamlHookCommand(
        agent: SupportedAgent,
        state: TabActivityState?
    ) -> String {
        let stateArg = state?.rawValue ?? "end"
        // A single stable script keeps the YAML scalar short and free of quoting
        // hazards; the script is rewritten on every install.
        return "\(yamlHookScriptPath(agent)) \(stateArg)"
    }

    /// Absolute path of the helper script a YAML-hook Agent's config invokes.
    private static func yamlHookScriptPath(_ agent: SupportedAgent) -> String {
        "~/.config/oh-my-ghostty/agent-status/\(agent.rawValue)-hook.sh"
    }

    /// Resolves `yamlHookScriptPath` against this installer's home, so a test or
    /// alternate home never writes into the real user's home directory.
    private func yamlHookScriptURL(_ agent: SupportedAgent) -> URL {
        homeURL
            .appendingPathComponent(".config/oh-my-ghostty/agent-status")
            .appendingPathComponent("\(agent.rawValue)-hook.sh")
    }

    /// Writes the helper script invoked from the Agent's YAML config.
    ///
    /// The script reads the hook payload from stdin for the conversation id and
    /// writes one status line, so it never needs a TTY and behaves the same when
    /// the Agent runs it from a pane-attached process or from its daemon.
    private func installYAMLHookScript(for agent: SupportedAgent) throws {
        let url = yamlHookScriptURL(agent)
        try writeText(
            Self.yamlHookScriptSource(for: agent),
            to: url,
            forcePermissions: 0o700
        )
    }

    /// Body of the helper script a YAML-hook Agent invokes instead of an inline
    /// command, shared by the local installer and the exported SSH installer.
    static func yamlHookScriptSource(for agent: SupportedAgent) -> String {
        "#!/usr/bin/env python3\n# marker: \(marker) v\(hookVersion)\n" +
            HermesPaneStatus.reporter
    }

    /// Renders `command` as the single continuation line of a YAML block scalar.
    /// YAML folds newlines into spaces, so an embedded newline would silently
    /// corrupt the command; the generated commands never contain one.
    private static func yamlFoldedScalar(_ command: String) -> String {
        command.replacingOccurrences(of: "\n", with: " ")
    }

    private func removeYAMLHooks(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let base = Self.removingYAMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        try writeText(base.isEmpty ? "" : base + "\n", to: url)
    }

    private func yamlHooksCurrent(at url: URL, agent: SupportedAgent) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.range(of: Self.yamlBlockBegin, options: .literal) != nil,
              text.range(of: "hooks_auto_accept: true", options: .literal) != nil else { return false }
        // Every declared event must delegate to the helper script.
        guard agent.definition.hook.events.allSatisfy({ text.range(of: "\($0.name):", options: .literal) != nil }),
              text.range(of: "\(agent.rawValue)-hook.sh", options: .literal) != nil else { return false }
        // The helper script carries the hook version; a stale script means the
        // integration needs rewriting even when the YAML block looks current.
        guard let script = try? String(
            contentsOf: yamlHookScriptURL(agent),
            encoding: .utf8
        ) else { return false }
        return script.contains("_omg_agent_status v\(Self.hookVersion)")
    }

    private static func yamlBlockPresent(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return text.range(of: yamlBlockBegin, options: .literal) != nil
    }

    private func validateYAMLHooks(_ text: String) throws {
        // Refuse an unbalanced OMG block: removal would leave half a block behind.
        let begins = text.components(separatedBy: Self.yamlBlockBegin).count - 1
        let ends = text.components(separatedBy: Self.yamlBlockEnd).count - 1
        guard begins == ends else {
            throw AgentHookInstallerError.invalidHooks("yaml")
        }
        // A top-level `hooks:` owned by the user cannot be merged without
        // re-serializing their YAML, which would rewrite unrelated content.
        let base = Self.removingYAMLBlock(from: text)
        let foreignHooksKey = base
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                line.hasPrefix("hooks:")
            }
        guard !foreignHooksKey else {
            throw AgentHookInstallerError.invalidHooks("hooks")
        }
    }

    private static func removingYAMLBlock(from text: String) -> String {
        guard let begin = text.range(of: yamlBlockBegin),
              let end = text.range(
                  of: yamlBlockEnd,
                  range: begin.upperBound..<text.endIndex
              ) else { return text }
        var result = text
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result
    }

    private func installTOMLHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        let base = Self.removingTOMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        var lines = [Self.tomlBlockBegin]
        for event in agent.definition.hook.events {
            lines.append("[[hooks]]")
            lines.append("event = \"\(event.name)\"")
            if let matcher = event.matcher {
                lines.append("matcher = \"\(matcher)\"")
            }
            let command = Self.hookCommand(
                agent: agent,
                event: event.name,
                state: event.state,
                attentionKind: Self.attentionKind(
                    event: event.name,
                    matcher: event.matcher,
                    state: event.state
                )
            )
            lines.append("command = '''\(command)'''")
            lines.append("timeout = 5")
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }
        lines.append(Self.tomlBlockEnd)
        let block = lines.joined(separator: "\n")
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeText(base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n", to: url)
    }

    private func removeTOMLHooks(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let base = Self.removingTOMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        try writeText(base.isEmpty ? "" : base + "\n", to: url)
    }

    private static func removingTOMLBlock(from text: String) -> String {
        guard let begin = text.range(of: tomlBlockBegin),
              let end = text.range(
                  of: tomlBlockEnd,
                  range: begin.upperBound..<text.endIndex
              ) else { return text }
        var result = text
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result
    }

    private func installScriptHooks(
        at directory: URL,
        agent: SupportedAgent
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for event in agent.definition.hook.events {
            let url = directory.appendingPathComponent(event.name)
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try String(contentsOf: url, encoding: .utf8)
                guard existing.contains(": \(Self.marker);") else {
                    throw AgentHookInstallerError.invalidHooks(event.name)
                }
                try backupIfNeeded(url)
            }
            let source = "#!/bin/sh\n" + Self.hookCommand(
                agent: agent,
                event: event.name,
                state: event.state,
                attentionKind: Self.attentionKind(
                    event: event.name,
                    matcher: event.matcher,
                    state: event.state
                )
            ) + "\n"
            try writeText(source, to: url, forcePermissions: 0o700)
        }
    }

    private func removeScriptHooks(
        at directory: URL,
        agent: SupportedAgent
    ) throws {
        for event in agent.definition.hook.events {
            let url = directory.appendingPathComponent(event.name)
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains(": \(Self.marker);") else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func hookURL(for agent: SupportedAgent) -> URL {
        let path = agent.definition.hook.path
        if path.hasPrefix("~/") {
            return homeURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func containsMarker(in url: URL, agent: SupportedAgent) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dictionary = root as? [String: Any],
              let hooks = dictionary[agent == .antigravity ? Self.antigravityHookName : "hooks"] as? [String: Any] else {
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
              let hooks = dictionary[agent == .antigravity ? Self.antigravityHookName : "hooks"] as? [String: Any] else {
            return false
        }
        if agent == .antigravity, hooks["enabled"] as? Bool == false { return false }
        return Self.hookEvents(agent).allSatisfy { event, state, matcher in
            guard let entries = hooks[event] as? [[String: Any]] else {
                return false
            }
            let expected = Self.jsonHookEntry(
                agent: agent,
                event: event,
                state: state,
                matcher: matcher
            )
            return entries.contains { Self.isCurrentOMGEntry($0, matching: expected) }
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
        let hooks = try hooksDictionary(root[agent == .antigravity ? Self.antigravityHookName : "hooks"])
        if agent == .antigravity, root[Self.antigravityHookName] != nil {
            // Refuse a same-named third-party hook rather than taking ownership.
            guard hooks.keys.contains(where: { $0 != "enabled" }) else {
                throw AgentHookInstallerError.invalidHooks(Self.antigravityHookName)
            }
            for (event, value) in hooks where event != "enabled" {
                let entries = try hookEntries(value, event: event)
                guard !entries.isEmpty, entries.allSatisfy({ Self.removingOMGCommands($0) == nil }) else {
                    throw AgentHookInstallerError.invalidHooks(Self.antigravityHookName)
                }
            }
        }
        for (event, _, _) in Self.hookEvents(agent) {
            _ = try hookEntries(hooks[event], event: event)
        }
    }

    private func installJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        var root = try loadJSONObject(at: url)
        let key = agent == .antigravity ? Self.antigravityHookName : "hooks"
        var hooks = try hooksDictionary(root[key])
        if agent == .antigravity {
            hooks["enabled"] = true
        } else {
            for existingKey in Array(hooks.keys) {
                guard let existingEntries = hooks[existingKey] as? [[String: Any]] else {
                    continue
                }
                let remaining = existingEntries.compactMap(Self.removingOMGCommands)
                if remaining.isEmpty {
                    hooks.removeValue(forKey: existingKey)
                } else {
                    hooks[existingKey] = remaining
                }
            }
        }
        var cleanedEvents = Set<String>()
        for (event, state, matcher) in Self.hookEvents(agent) {
            var entries: [[String: Any]]
            if cleanedEvents.insert(event).inserted {
                let existing = try hookEntries(hooks[event], event: event)
                entries = existing.compactMap(Self.removingOMGCommands)
            } else {
                entries = try hookEntries(hooks[event], event: event)
            }
            entries.append(Self.jsonHookEntry(
                agent: agent,
                event: event,
                state: state,
                matcher: matcher
            ))
            hooks[event] = entries
        }
        root[key] = hooks
        if Self.jsonHookUsesRootVersion(agent.definition.hook.dialect),
           root["version"] == nil {
            root["version"] = 1
        }
        try writeJSONObject(root, to: url)
    }

    private func removeJSONHooks(at url: URL, agent: SupportedAgent) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try loadJSONObject(at: url)
        if agent == .antigravity {
            guard root[Self.antigravityHookName] != nil else { return }
            try validateJSONHooks(at: url, agent: agent)
            root.removeValue(forKey: Self.antigravityHookName)
            try writeJSONObject(root, to: url)
            return
        }
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

    private static func ensureNotSymlink(_ url: URL) throws {
        var st = stat()
        if Darwin.lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw OMGPrivateFileWriter.WriteError.unsafePath
        }
    }

    private func writeText(
        _ text: String,
        to url: URL,
        defaultPermissions: mode_t = 0o600,
        forcePermissions: mode_t? = nil
    ) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeData(
            data,
            to: url,
            defaultPermissions: defaultPermissions,
            forcePermissions: forcePermissions
        )
    }

    struct BackupAudit: Equatable, Sendable {
        let backupCount: Int
        let insecureBackupCount: Int
    }

    func backupAudit() -> BackupAudit {
        var urls: [URL] = [homeURL.appendingPathComponent(".codex/config.toml")]
        for agent in SupportedAgent.allCases where agent.definition.hook.kind != .none {
            let base = hookURL(for: agent)
            if agent.definition.hook.kind == .scripts {
                for event in agent.definition.hook.events {
                    urls.append(base.appendingPathComponent(event.name))
                }
            } else {
                urls.append(base)
                if agent.definition.hook.kind == .yaml {
                    urls.append(yamlHookScriptURL(agent))
                }
            }
        }
        var seen = Set<String>()
        var backupCount = 0
        var insecureBackupCount = 0
        let expectedUID = getuid()
        for target in urls {
            for ext in ["omg.bak", "omg-backup"] {
                let bakURL = target.appendingPathExtension(ext)
                guard seen.insert(bakURL.path).inserted else { continue }
                var st = stat()
                guard lstat(bakURL.path, &st) == 0 else { continue }
                backupCount += 1
                let isRegular = (st.st_mode & S_IFMT) == S_IFREG
                let isPrivate = (st.st_mode & 0o777) == 0o600
                let ownedByUser = st.st_uid == expectedUID
                if !isRegular || !isPrivate || !ownedByUser {
                    insecureBackupCount += 1
                }
            }
        }
        return BackupAudit(backupCount: backupCount, insecureBackupCount: insecureBackupCount)
    }

    private func writeData(
        _ data: Data,
        to url: URL,
        defaultPermissions: mode_t = 0o600,
        forcePermissions: mode_t? = nil
    ) throws {
        try Self.ensureNotSymlink(url.deletingLastPathComponent())
        try Self.ensureNotSymlink(url)
        var st = stat()
        let existsRegular = Darwin.lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
        if existsRegular, !url.path.contains("/.config/oh-my-ghostty/agent-status/") {
            let bakURL = url.appendingPathExtension("omg.bak")
            try Self.ensureNotSymlink(bakURL)
            let existing = try Data(contentsOf: url)
            try OMGPrivateFileWriter.writeAtomically(
                existing,
                to: bakURL
            )
        }
        let permissions = forcePermissions ?? (existsRegular ? (st.st_mode & 0o777) : defaultPermissions)
        try OMGPrivateFileWriter.writeAtomically(
            data,
            to: url,
            permissions: permissions
        )
    }

    private static func isHooksAssignment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^hooks\s*="#, options: .regularExpression) != nil
    }

    private static func containsOMGCommand(_ entry: [String: Any]) -> Bool {
        if entry[marker] != nil || isLegacyOMGCommand(entry) { return true }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains(where: isLegacyOMGCommand)
    }

    private static func isCurrentOMGEntry(
        _ entry: [String: Any],
        matching expected: [String: Any]
    ) -> Bool {
        guard isCurrentOMGEntry(entry),
              (entry["matcher"] as? String) == (expected["matcher"] as? String),
              (entry["match"] as? String) == (expected["match"] as? String) else {
            return false
        }
        if let expectedCommand = expected["command"] as? String {
            return (entry["command"] as? String) == expectedCommand
        }
        if let expectedHooks = expected["hooks"] as? [[String: Any]],
           let expectedCommand = expectedHooks.first?["command"] as? String,
           let actualHooks = entry["hooks"] as? [[String: Any]] {
            return actualHooks.contains { ($0["command"] as? String) == expectedCommand }
        }
        return true
    }

    private static func isCurrentOMGEntry(_ entry: [String: Any]) -> Bool {
        let versionMarker = "_omg_agent_status_v\(hookVersion)"
        if (entry["command"] as? String)?.contains(versionMarker) == true {
            return true
        }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        let commandMatches = hooks.contains {
            ($0["command"] as? String)?.contains(versionMarker) == true
        }
        if entry[marker] != nil {
            return entry[marker] as? Int == hookVersion && commandMatches
        }
        return commandMatches
    }

    private static func removingOMGCommands(
        _ entry: [String: Any]
    ) -> [String: Any]? {
        if entry[marker] != nil || isLegacyOMGCommand(entry) { return nil }
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
        try Self.ensureNotSymlink(url.deletingLastPathComponent())
        try Self.ensureNotSymlink(url)
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else { return }
        let backup = url.appendingPathExtension("omg-backup")
        try Self.ensureNotSymlink(backup)
        var backupStat = stat()
        guard Darwin.lstat(backup.path, &backupStat) != 0 else { return }
        let existing = try Data(contentsOf: url)
        try OMGPrivateFileWriter.writeAtomically(existing, to: backup)
    }

    private static func hookEvents(
        _ agent: SupportedAgent
    ) -> [(String, TabActivityState?, String?)] {
        agent.definition.hook.events.map { event in
            (event.name, event.state, event.matcher)
        }
    }

    private static func jsonHookEntry(
        agent: SupportedAgent,
        event: String,
        state: TabActivityState?,
        matcher: String?
    ) -> [String: Any] {
        let command = hookCommand(
            agent: agent,
            event: event,
            state: state,
            attentionKind: attentionKind(
                event: event,
                matcher: matcher,
                state: state
            )
        )
        switch agent.definition.hook.dialect ?? .nested {
        case .antigravity:
            let handler: [String: Any] = ["type": "command", "command": command, "timeout": 5]
            if event == "PostToolUse" {
                return ["matcher": "*", "hooks": [handler]]
            }
            return handler
        case .flat, .cursor, .copilot:
            var entry: [String: Any] = ["command": command]
            if agent.definition.hook.dialect == .flat {
                entry["description"] = "OMG Agent Status"
            } else if agent.definition.hook.dialect == .copilot {
                entry["type"] = "command"
            }
            if let matcher { entry["match"] = matcher }
            return entry

        default:
            var entry: [String: Any] = [
                marker: hookVersion,
                "hooks": [["type": "command", "command": command]],
            ]
            if let matcher { entry["matcher"] = matcher }
            return entry
        }
    }

    private static func jsonHookUsesRootVersion(
        _ dialect: AgentDefinition.HookSpec.Dialect?
    ) -> Bool {
        dialect == .cursor || dialect == .copilot
    }

    private static func attentionKind(
        event: String,
        matcher: String?,
        state: TabActivityState?
    ) -> TabAttentionKind? {
        guard state == .needsAttention else { return nil }
        let value = "\(event) \(matcher ?? "")".lowercased()
        if value.contains("permission") || value.contains("approval") {
            return .permission
        }
        if value.contains("question") || value.contains("prompt") {
            return .question
        }
        return nil
    }

    private static func isPromptStartEvent(
        event: String?,
        state: TabActivityState?
    ) -> Bool {
        guard state == .working, let event else { return false }
        let normalized = event.lowercased()
        return normalized.contains("prompt") ||
            normalized == "preinvocation" ||
            normalized == "taskstart" ||
            normalized == "taskresume"
    }

    private static func hookCommand(
        agent: SupportedAgent,
        event: String? = nil,
        state: TabActivityState?,
        attentionKind: TabAttentionKind? = nil
    ) -> String {
        let promptEvent = isPromptStartEvent(event: event, state: state)
        if agent == .antigravity {
            return antigravityHookCommand(state: state, isPromptEvent: promptEvent)
        }
        if agent == .claude || agent == .codex {
            return subagentAwareHookCommand(
                agent: agent,
                event: event,
                state: state,
                attentionKind: attentionKind,
                isPromptEvent: promptEvent
            )
        }
        let action = state == nil ? "end" : "start"
        var metadata = "type=app;omg_agent=\(agent.rawValue);" +
            "omg_scope=%s;omg_liveness=pgid"
        if let state { metadata += ";omg_state=\(state.rawValue)" }
        if let attentionKind {
            metadata += ";omg_attention=\(attentionKind.rawValue)"
        }
        if promptEvent {
            metadata += ";omg_event=prompt"
        }
        var setup = "omg_report_conv=-; "
        var arguments = "\"$omg_pgid\" \"$omg_scope\""
        if let field = agent.definition.hook.conversationField {
            setup = "omg_pair=$(env -u SDKROOT -u DEVELOPER_DIR python3 -c " +
                "'import json,re,sys,urllib.parse; " +
                "raw=json.load(sys.stdin).get(\"\(field)\",\"\"); " +
                "raw=raw[:128] if isinstance(raw,str) else str(raw or \"\")[:128]; " +
                "rep=raw if re.fullmatch(r\"[A-Za-z0-9._][A-Za-z0-9._-]{0,127}\",raw) else \"-\"; " +
                "osc=urllib.parse.quote(raw,safe=\"._~-\"); " +
                "print(rep+\"|\"+osc,end=\"\")' " +
                "2>/dev/null || printf '%s' '-|'); " +
                "omg_report_conv=${omg_pair%%|*}; " +
                "omg_conversation=${omg_pair#*|}; "
            metadata += ";omg_conversation=%s"
            arguments += " \"$omg_conversation\""
        }
        var reportFlags = ""
        if let attentionKind {
            reportFlags += " --attention \(attentionKind.rawValue)"
        }
        if promptEvent {
            reportFlags += " --event prompt"
        }
        let runtimeReport =
            "if [ -n \"${OMG_RUNTIME_BIN-}\" ]; then " +
            "\"$OMG_RUNTIME_BIN\" report \(agent.rawValue) \(state?.rawValue ?? "end") " +
            "\"${omg_report_conv:--}\" \"$PWD\"\(reportFlags) >/dev/null 2>&1 && exit 0; fi; "
        return ": \(marker); : _omg_agent_status_v\(hookVersion); " + setup + runtimeReport +
            "omg_tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "omg_pgid=$(ps -o pgid= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "case \"$omg_pgid\" in ''|*[!0-9]*) exit 0;; esac; " +
            "case \"$omg_tty\" in ''|*[!A-Za-z0-9/._-]*) omg_tty=tty;; esac; " +
            "omg_scope=local; test -n \"${SSH_CONNECTION-}${OMG_RUNTIME_REMOTE-}\" && omg_scope=remote; " +
            "printf '\\033]3008;\(action)=omg-agent-\(agent.rawValue)-%s;" +
            "\(metadata)\\007' \(arguments) > \"/dev/$omg_tty\" " +
            "2>/dev/null || true"
    }

    private static let subagentOwnerPIDPreamble =
        "omg_owner_pid=$PPID; " +
        "for _omg_hop in 1 2 3 4; do " +
        "omg_ps=$(ps -o ppid=,comm= -p \"$omg_owner_pid\" 2>/dev/null) || break; " +
        "omg_ps=${omg_ps#\"${omg_ps%%[![:space:]]*}\"}; " +
        "omg_next_ppid=${omg_ps%%[[:space:]]*}; " +
        "omg_comm=${omg_ps#\"$omg_next_ppid\"}; " +
        "omg_comm=${omg_comm#\"${omg_comm%%[![:space:]]*}\"}; " +
        "omg_base=${omg_comm##*/}; " +
        "case \"$omg_next_ppid\" in ''|*[!0-9]*|0|1) break;; esac; " +
        "case \"$omg_base\" in -*) break;; sh|bash|dash|zsh|ksh|env) omg_owner_pid=$omg_next_ppid;; *) break;; esac; " +
        "done; " +
        "case \"$omg_owner_pid\" in ''|*[!0-9]*|0|1) omg_owner_pid=;; esac; "

    private static func subagentAwareHookCommand(
        agent: SupportedAgent,
        event: String?,
        state: TabActivityState?,
        attentionKind: TabAttentionKind?,
        isPromptEvent: Bool
    ) -> String {
        let field = agent.definition.hook.conversationField ?? "session_id"
        let toolField = agent.definition.hook.toolField ?? "tool_name"
        let isSubagentStart = event == "SubagentStart"
        let isSubagentStop = event == "SubagentStop"
        let isStop = event == "Stop"
        let isStopFailure = event == "StopFailure"
        let isPostToolFailure = event == "PostToolUseFailure"
        let isClaudeWorkingPreTool = agent == .claude && event == "PreToolUse" && state == .working && attentionKind == nil
        let isClaudeAttentionResolveCandidate =
            agent == .claude && (event == "PostToolUse" || event == "PostToolUseFailure") && state == .working
        let baseState = state?.rawValue ?? "end"
        let baseAction = state == nil ? "end" : "start"
        let skipExpr: String
        if isStop {
            skipExpr = "\"1\" if d.get(\"stop_hook_active\") is True else \"\""
        } else if isClaudeWorkingPreTool {
            skipExpr = "\"1\" if (d.get(\"\(toolField)\") in (\"AskUserQuestion\",\"ExitPlanMode\") and not sub) else \"\""
        } else if isPostToolFailure {
            skipExpr = "\"1\" if d.get(\"is_interrupt\") is True else \"\""
        } else {
            skipExpr = "\"\""
        }
        let eventExpr: String = if isClaudeAttentionResolveCandidate {
            "\"attention_resolved\" if d.get(\"\(toolField)\") in (\"AskUserQuestion\",\"ExitPlanMode\") else \"\""
        } else {
            "\"\""
        }
        let py = "import json,re,sys,urllib.parse; " +
            "d=json.load(sys.stdin); d=d if isinstance(d,dict) else {}; " +
            "raw=d.get(\"\(field)\",\"\"); " +
            "raw=raw[:128] if isinstance(raw,str) else str(raw or \"\")[:128]; " +
            "rep=raw if re.fullmatch(r\"[A-Za-z0-9._][A-Za-z0-9._-]{0,127}\",raw) else \"-\"; " +
            "osc=urllib.parse.quote(raw,safe=\"._~-\"); " +
            "sub=next((d[k][:128] for k in " +
            "(\"agent_id\",\"parent_tool_use_id\",\"subagent_id\",\"task_id\") " +
            "if isinstance(d.get(k),str) and d[k]),\"\"); " +
            "sub=sub if re.fullmatch(r\"[A-Za-z0-9._-]{1,128}\",sub) else \"\"; " +
            "skip=\(skipExpr); " +
            "ev=\(eventExpr); " +
            "print(rep+\"|\"+osc+\"|\"+sub+\"|\"+skip+\"|\"+ev,end=\"\")"
        var setup = "omg_pair=$(env -u SDKROOT -u DEVELOPER_DIR python3 -c '\(py)' " +
            "2>/dev/null || printf '%s' '-||||'); " +
            "omg_report_conv=${omg_pair%%|*}; omg_rest=${omg_pair#*|}; " +
            "omg_conversation=${omg_rest%%|*}; omg_rest=${omg_rest#*|}; " +
            "omg_sub=${omg_rest%%|*}; omg_rest=${omg_rest#*|}; " +
            "omg_skip=${omg_rest%%|*}; omg_ev=${omg_rest#*|}; "
        if isStop || isClaudeWorkingPreTool || isPostToolFailure {
            setup += "test \"$omg_skip\" = 1 && exit 0; "
        }
        if isSubagentStart || isSubagentStop {
            setup += "omg_sub=${omg_sub:-subagent}; "
        }
        if isSubagentStop {
            setup += "test -n \"$omg_sub\" || exit 0; "
        }
        setup += "omg_state=\(baseState); omg_action=\(baseAction); omg_phase=; "
        if isStop || isStopFailure {
            setup += "if [ -n \"$omg_sub\" ]; then omg_state=end; omg_action=end; fi; "
        } else if state == .working {
            setup += "if [ -n \"$omg_sub\" ]; then omg_phase=background; fi; "
        }
        if isPromptEvent {
            setup += "if [ -z \"$omg_sub\" ]; then omg_ev=prompt; fi; "
        }
        setup += subagentOwnerPIDPreamble
        var runtimeBlock = "if [ -n \"${OMG_RUNTIME_BIN-}\" ]; then " +
            "set -- report \(agent.rawValue) \"$omg_state\" \"${omg_report_conv:--}\" \"$PWD\"; " +
            "if [ -n \"$omg_owner_pid\" ] && kill -0 \"$omg_owner_pid\" 2>/dev/null; then set -- \"$@\" --pid \"$omg_owner_pid\"; fi; " +
            "if [ -n \"$omg_sub\" ]; then set -- \"$@\" --id \"$omg_sub\"; fi; " +
            "if [ -n \"$omg_phase\" ]; then set -- \"$@\" --phase \"$omg_phase\"; fi; "
        if let attentionKind {
            runtimeBlock += "set -- \"$@\" --attention \(attentionKind.rawValue); "
        }
        runtimeBlock += "if [ -n \"$omg_ev\" ]; then set -- \"$@\" --event \"$omg_ev\"; fi; "
        runtimeBlock += "\"$OMG_RUNTIME_BIN\" \"$@\" >/dev/null 2>&1 && exit 0; fi; "

        var oscExtra = "omg_extra=; " +
            "if [ \"$omg_action\" = start ]; then omg_extra=\";omg_state=$omg_state\"; fi; " +
            "if [ -n \"$omg_sub\" ]; then omg_extra=\"$omg_extra;omg_context=$omg_sub\"; fi; " +
            "if [ -n \"$omg_phase\" ]; then omg_extra=\"$omg_extra;omg_phase=$omg_phase\"; fi; "
        if let attentionKind {
            oscExtra += "omg_extra=\"$omg_extra;omg_attention=\(attentionKind.rawValue)\"; "
        }
        oscExtra += "if [ -n \"$omg_ev\" ]; then omg_extra=\"$omg_extra;omg_event=$omg_ev\"; fi; "

        return ": \(marker); : _omg_agent_status_v\(hookVersion); " + setup + runtimeBlock +
            "omg_tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "case \"$omg_tty\" in ''|'??'|'?') [ -n \"$omg_owner_pid\" ] && omg_tty=$(ps -o tty= -p \"$omg_owner_pid\" 2>/dev/null | tr -d ' ');; esac; " +
            "omg_pgid=$(ps -o pgid= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "if [ -n \"$omg_owner_pid\" ] && [ \"$omg_owner_pid\" != \"$PPID\" ]; then omg_pgid=$(ps -o pgid= -p \"$omg_owner_pid\" 2>/dev/null | tr -d ' '); fi; " +
            "case \"$omg_pgid\" in ''|*[!0-9]*) exit 0;; esac; " +
            "case \"$omg_tty\" in ''|*[!A-Za-z0-9/._-]*) omg_tty=tty;; esac; " +
            "omg_scope=local; test -n \"${SSH_CONNECTION-}${OMG_RUNTIME_REMOTE-}\" && omg_scope=remote; " +
            oscExtra +
            "printf '\\033]3008;%s=omg-agent-\(agent.rawValue)-%s;" +
            "type=app;omg_agent=\(agent.rawValue);omg_scope=%s;omg_liveness=pgid%s;" +
            "omg_conversation=%s\\007' \"$omg_action\" \"$omg_pgid\" \"$omg_scope\" " +
            "\"$omg_extra\" \"$omg_conversation\" > \"/dev/$omg_tty\" " +
            "2>/dev/null || true"
    }

    private static let antigravityHookName = "omg-agent-status"

    /// agy stdout is a JSON protocol channel; report via omgd socket when inside a
    /// managed session and fall back to the controlling TTY otherwise.
    private static func antigravityHookCommand(
        state: TabActivityState?,
        isPromptEvent: Bool = false
    ) -> String {
        let script = #"""
import json, os, re, sqlite3, subprocess, sys, urllib.parse
response = {"decision": "allow"} if sys.argv[1] == "done" else {}
try:
    payload = json.loads(sys.stdin.read(1048576))
    state = sys.argv[1]
    is_prompt = len(sys.argv) > 2 and sys.argv[2] == "prompt"
    attention = ""
    attention_kind = ""
    if state == "done":
        reason = str(payload.get("terminationReason") or "").upper()
        if payload.get("error") or reason == "ERROR": state = "error"
        elif reason == "USER_CANCELED": state = "idle"
    sid = os.getsid(0)
    owner = os.getppid()
    owner_tty = ""
    for _ in range(4):
        info = subprocess.run(["ps", "-o", "ppid=,tty=,comm=", "-p", str(owner)], capture_output=True, text=True, timeout=2).stdout.strip()
        parts = info.split(None, 2)
        if len(parts) < 3: break
        ppid, tty_col, comm = int(parts[0]), parts[1], os.path.basename(parts[2].strip()).lstrip("-")
        if re.fullmatch(r"(?:pts/[0-9]+|tty[A-Za-z0-9._-]+)", tty_col): owner_tty = tty_col
        if comm not in ("sh", "bash", "dash", "zsh") or ppid <= 1: break
        try:
            if os.getsid(ppid) != sid: break
        except OSError:
            break
        owner = ppid
    raw_conv = payload.get("conversationId", "")
    if not isinstance(raw_conv, str): raw_conv = ""
    raw_conv = raw_conv[:128]
    valid_id = lambda value: bool(re.fullmatch(r"[A-Za-z0-9._][A-Za-z0-9._-]{0,127}", value))
    root_conv = raw_conv
    is_child = False
    if valid_id(raw_conv):
        app_dir = os.environ.get("ANTIGRAVITY_APP_DATA_DIR") or os.path.expanduser("~/.gemini/antigravity-cli")
        if os.path.basename(app_dir.rstrip("/")) == "conversations":
            app_dir = os.path.dirname(app_dir.rstrip("/"))
        summary_db = os.path.join(app_dir, "conversation_summaries.db")
        if os.path.isfile(summary_db):
            for mode in ("ro", "ro&immutable=1"):
                try:
                    conn = sqlite3.connect("file:" + urllib.parse.quote(summary_db) + "?mode=" + mode, uri=True, timeout=0.2)
                    try:
                        cur_id = raw_conv
                        seen = {cur_id}
                        for _ in range(8):
                            row = conn.execute("SELECT parent_conversation_id, nesting_depth FROM conversation_summaries WHERE conversation_id = ? LIMIT 1", (cur_id,)).fetchone()
                            if not row: break
                            parent_id = str(row[0] or "").strip()[:128]
                            depth = int(row[1] or 0)
                            if not parent_id and depth <= 0: break
                            is_child = True
                            if not valid_id(parent_id) or parent_id in seen: break
                            seen.add(parent_id)
                            cur_id = parent_id
                            root_conv = cur_id
                    finally:
                        conn.close()
                    break
                except sqlite3.Error:
                    pass
    sub_id = raw_conv if (is_child and valid_id(raw_conv)) else ""
    eff_conv = root_conv if (not is_child or root_conv != raw_conv) else ""
    report_conv = eff_conv if valid_id(eff_conv) else "-"
    conversation = urllib.parse.quote(eff_conv, safe="._~-")
    if sub_id and sys.argv[1] == "done":
        state = "end"
    reported = False
    runtime_bin = os.environ.get("OMG_RUNTIME_BIN")
    if runtime_bin:
        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            try: cwd = os.getcwd()
            except OSError: cwd = "/"
        cmd = [runtime_bin, "report", "antigravity", state, report_conv, cwd, "--pid", str(owner)]
        if sub_id:
            cmd.extend(["--id", sub_id])
            if state != "end":
                cmd.extend(["--phase", "background"])
        else:
            if attention_kind: cmd.extend(["--attention", attention_kind])
            if is_prompt and state == "working": cmd.extend(["--event", "prompt"])
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        reported = res.returncode == 0
    if not reported:
        pgid = os.getpgid(owner)
        scope = "remote" if (os.environ.get("SSH_CONNECTION") or os.environ.get("OMG_RUNTIME_REMOTE")) else "local"
        if sub_id and state == "end":
            sequence = "\033]3008;end=omg-agent-antigravity-%d;omg_context=%s\007" % (pgid, urllib.parse.quote(sub_id, safe="._~-"))
        else:
            event_tag = ";omg_event=prompt" if (is_prompt and state == "working" and not sub_id) else ""
            sub_tag = (";omg_context=%s;omg_phase=background" % urllib.parse.quote(sub_id, safe="._~-")) if sub_id else ""
            conv_tag = (";omg_conversation=%s" % conversation) if (not is_child or valid_id(eff_conv)) else ""
            sequence = "\033]3008;start=omg-agent-antigravity-%d;type=app;omg_agent=antigravity;omg_scope=%s;omg_liveness=pgid;omg_state=%s%s%s%s%s\007" % (pgid, scope, state, attention, event_tag, sub_tag, conv_tag)
        try:
            fd = os.open("/dev/tty", os.O_WRONLY | os.O_NOCTTY)
        except OSError:
            if not owner_tty: raise OSError("No controlling terminal")
            fd = os.open("/dev/" + owner_tty, os.O_WRONLY | os.O_NOCTTY)
        try: os.write(fd, sequence.encode())
        finally: os.close(fd)
except (ValueError, OSError, TypeError, AttributeError, subprocess.SubprocessError):
    pass
print(json.dumps(response))
"""#
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let envCleanup = "unset SDKROOT; if [ -n \"${DEVELOPER_DIR-}\" ] && [ ! -d \"$DEVELOPER_DIR\" ]; then unset DEVELOPER_DIR; fi"
        let promptArg = isPromptEvent ? " prompt" : ""
        return ": \(marker); : _omg_agent_status_v\(hookVersion); \(envCleanup); python3 -c \(quoted) \(state?.rawValue ?? "done")\(promptArg)"
    }

    private static func pluginSource(for agent: SupportedAgent) -> String? {
        switch agent.definition.hook.dialect {
        case .pi: agent == .omp ? ompExtension : piExtension
        case .opencode: openCodeExtension
        case .amp: ampExtension
        default: nil
        }
    }

    private static let piExtension = #"""
// OMG agent status integration for Pi.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";
import { spawnSync } from "node:child_process";

const contextId = `omg-agent-pi-${process.pid}`;
const scope = process.env.SSH_CONNECTION || process.env.OMG_RUNTIME_REMOTE ? "remote" : "local";
function report(
  state?: string,
  end = false,
  context?: any,
  attention?: string,
  phase?: string,
  eventKind?: string,
) {
  let fd: number | undefined;
  try {
    const raw = context?.sessionManager?.getSessionId?.();
    const validConv = Boolean(raw && /^[A-Za-z0-9._][A-Za-z0-9._-]{0,127}$/.test(String(raw)));
    const conversation = validConv
      ? `;omg_conversation=${encodeURIComponent(String(raw))}` : "";
    // The session's own project directory can differ from the shell's cwd
    // (for example when `pi resume` picks a session from another project).
    // Restoring the conversation requires resuming it in this directory.
    const rawCwd = context?.sessionManager?.getCwd?.();
    const validCwd = Boolean(
      rawCwd && String(rawCwd).startsWith("/") &&
      String(rawCwd).length <= 4096 && !String(rawCwd).includes("\0"),
    );
    const sessionCwd = validCwd
      ? `;omg_cwd=${encodeURIComponent(String(rawCwd))}` : "";
    if (process.env.OMG_RUNTIME_BIN) {
      const args = [
        "report",
        "pi",
        end ? "end" : String(state),
        validConv ? String(raw) : "-",
        validCwd ? String(rawCwd) : process.cwd(),
        "--pid",
        String(process.pid),
      ];
      if (attention) args.push("--attention", attention);
      if (phase) args.push("--phase", phase, "--message", "Background work running");
      if (eventKind && state === "working") args.push("--event", eventKind);
      const res = spawnSync(process.env.OMG_RUNTIME_BIN, args, { stdio: "ignore", timeout: 1000 });
      if (res.status === 0) return;
    }
    const attentionKind = attention ? `;omg_attention=${attention}` : "";
    const activityPhase = phase ? `;omg_phase=${phase};message=Background%20work%20running` : "";
    const eventTag = eventKind && state === "working" ? `;omg_event=${eventKind}` : "";
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=pi;omg_scope=${scope};omg_liveness=pid${conversation}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=pi;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${conversation}${sessionCwd}${attentionKind}${activityPhase}${eventTag}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export default function (pi: any) {
  let currentContext: any;
  let closing = false;
  let requestSequence = 0;
  let completionPending = false;
  let settleVerifyTimer: any;
  let waitingUnnamedCount = 0;
  const waitingToolCalls = new Set<string>();
  const subagentRuns = new Set<string>();
  const backgroundTasks = new Set<string>();
  const waitingTools = new Set(["ask_user_question", "ask_question", "question", "confirm"]);
  const backgroundToolNames = new Set([
    "bg_run", "bg_run_pi_attested", "bg_delegate",
    "fusion_reason", "fusion_investigate", "fusion_research", "fusion_validate",
  ]);

  const clearWaitingTools = () => {
    waitingToolCalls.clear();
    waitingUnnamedCount = 0;
  };
  const clearSettleVerify = () => {
    if (settleVerifyTimer !== undefined) {
      clearTimeout(settleVerifyTimer);
      settleVerifyTimer = undefined;
    }
  };
  const activeBackgroundCount = () => subagentRuns.size + backgroundTasks.size;
  const updateSettledStatus = (context = currentContext) => {
    currentContext = context ?? currentContext;
    if (closing || !currentContext?.isIdle?.()) return;
    if (activeBackgroundCount() > 0) {
      completionPending = true;
      report("working", false, currentContext, undefined, "background");
    } else if (completionPending) {
      clearSettleVerify();
      completionPending = false;
      report("done", false, currentContext);
    }
  };
  const validID = (value: any) => typeof value === "string" && value.length > 0 && value.length <= 256;
  const refreshBackgroundTasks = (onReply?: () => void) => {
    const requestId = `omg-agent-status-${process.pid}-${++requestSequence}`;
    const unsubscribe = pi.events.on("pi-background-tasks:response:v1", (response: any) => {
      if (response?.request_id !== requestId) return;
      unsubscribe?.();
      if (!response.ok || !Array.isArray(response.result?.tasks)) return;
      onReply?.();
      backgroundTasks.clear();
      for (const task of response.result.tasks) {
        if (task?.status === "running" && validID(task.id)) backgroundTasks.add(task.id);
      }
      updateSettledStatus();
    });
    pi.events.emit("pi-background-tasks:request:v1", {
      schema_version: "pi-background-tasks.extension-request.v1",
      request_id: requestId,
      operation: "status",
      payload: {},
    });
    return unsubscribe;
  };
  const refreshSubagents = (onReply?: () => void) => {
    const requestId = `omg-agent-status-${process.pid}-${++requestSequence}`;
    const replyEvent = `subagents:rpc:v1:reply:${requestId}`;
    const unsubscribe = pi.events.on(replyEvent, (reply: any) => {
      unsubscribe?.();
      const runs = reply?.success ? reply.data?.asyncSnapshot?.runs : undefined;
      if (!Array.isArray(runs)) return;
      onReply?.();
      subagentRuns.clear();
      for (const run of runs) {
        if ((run?.state === "queued" || run?.state === "running") && validID(run.id)) {
          subagentRuns.add(run.id);
        }
      }
      updateSettledStatus();
    });
    pi.events.emit("subagents:rpc:v1:request", {
      version: 1,
      requestId,
      method: "status",
      params: {},
    });
    return unsubscribe;
  };

  pi.events.on("subagent:async-started", (event: any) => {
    if (!validID(event?.id)) return;
    subagentRuns.add(event.id);
    updateSettledStatus();
  });
  pi.events.on("subagent:async-complete", (event: any) => {
    const id = event?.runId ?? event?.id;
    if (validID(id)) subagentRuns.delete(id);
    updateSettledStatus();
  });
  pi.events.on("subagents:rpc:v1:ready", () => refreshSubagents());
  pi.events.on("pi-background-tasks:terminal:v1", (event: any) => {
    if (validID(event?.task?.id)) backgroundTasks.delete(event.task.id);
    updateSettledStatus();
  });

  pi.on("session_start", async (_event: any, context: any) => {
    closing = false;
    completionPending = false;
    clearWaitingTools();
    clearSettleVerify();
    currentContext = context;
    report("idle", false, context);
    refreshBackgroundTasks();
  });
  pi.on("before_agent_start", async (_event: any, context: any) => {
    completionPending = true;
    clearWaitingTools();
    clearSettleVerify();
    currentContext = context;
    report("working", false, context, undefined, undefined, "prompt");
  });
  pi.on("agent_start", async (_event: any, context: any) => {
    completionPending = true;
    clearWaitingTools();
    clearSettleVerify();
    currentContext = context;
    report("working", false, context, undefined, undefined, "prompt");
  });
  pi.on("tool_execution_start", async (event: any, context: any) => {
    currentContext = context;
    const waiting = waitingTools.has(String(event?.toolName));
    const callId = validID(event?.toolCallId) ? event.toolCallId : undefined;
    if (waiting) {
      if (callId) waitingToolCalls.add(callId); else waitingUnnamedCount += 1;
      report("needsAttention", false, context, "question");
    } else if (waitingToolCalls.size === 0 && waitingUnnamedCount === 0) {
      report("working", false, context);
    }
  });
  pi.on("tool_execution_end", async (event: any, context: any) => {
    currentContext = context;
    const hadWaiting = waitingToolCalls.size > 0 || waitingUnnamedCount > 0;
    const callId = validID(event?.toolCallId) ? event.toolCallId : undefined;
    if (callId && waitingToolCalls.has(callId)) {
      waitingToolCalls.delete(callId);
    } else if (!callId && waitingUnnamedCount > 0 && waitingTools.has(String(event?.toolName))) {
      waitingUnnamedCount = Math.max(0, waitingUnnamedCount - 1);
    }
    const task = event?.result?.details?.task;
    if (!event?.isError && task?.status === "running" && validID(task.id)) {
      backgroundTasks.add(task.id);
    }
    if (!event?.isError && backgroundToolNames.has(String(event?.toolName))) {
      refreshBackgroundTasks();
    }
    if (waitingToolCalls.size === 0 && waitingUnnamedCount === 0) {
      report("working", false, context, undefined, undefined, hadWaiting ? "attention_resolved" : undefined);
    }
  });
  pi.on("agent_settled", async (event: any, context: any) => {
    // A previous run can settle after Esc just as a resumed prompt starts.
    // Never let that stale completion overwrite the newer working state.
    if (!context.isIdle()) return;
    clearWaitingTools();
    clearSettleVerify();
    if (event?.aborted || event?.cancelled || event?.reason === "aborted") {
      subagentRuns.clear();
      backgroundTasks.clear();
    }
    updateSettledStatus(context);
    if (activeBackgroundCount() > 0) {
      let bgConfirmed = backgroundTasks.size === 0;
      let subConfirmed = subagentRuns.size === 0;
      const unsubBg = backgroundTasks.size > 0
        ? refreshBackgroundTasks(() => { bgConfirmed = true; })
        : undefined;
      const unsubSub = subagentRuns.size > 0
        ? refreshSubagents(() => { subConfirmed = true; })
        : undefined;
      settleVerifyTimer = setTimeout(() => {
        settleVerifyTimer = undefined;
        unsubBg?.();
        unsubSub?.();
        if (closing || !currentContext?.isIdle?.()) return;
        if (!bgConfirmed) backgroundTasks.clear();
        if (!subConfirmed) subagentRuns.clear();
        updateSettledStatus(currentContext);
      }, 1500);
      settleVerifyTimer?.unref?.();
    }
  });
  pi.on("session_shutdown", async (_event: any, context: any) => {
    closing = true;
    clearWaitingTools();
    clearSettleVerify();
    subagentRuns.clear();
    backgroundTasks.clear();
    // Session shutdown is lifecycle cleanup, not task completion. Clear Pi's
    // identity so Ctrl-D, /new, /resume, /fork and /reload leave no done badge.
    report("idle", false, context);
    report(undefined, true, context);
  });
}
"""#

    private static let ampExtension = #"""
// OMG agent status integration for Amp.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";
import { spawnSync } from "node:child_process";

const contextId = `omg-agent-amp-${process.pid}`;
const scope = process.env.SSH_CONNECTION || process.env.OMG_RUNTIME_REMOTE ? "remote" : "local";
function report(state, end = false, isPrompt = false) {
  let fd;
  try {
    if (process.env.OMG_RUNTIME_BIN) {
      const args = [
        "report",
        "amp",
        end ? "end" : String(state),
        "-",
        process.cwd(),
        "--pid",
        String(process.pid),
      ];
      if (isPrompt && state === "working") args.push("--event", "prompt");
      const res = spawnSync(process.env.OMG_RUNTIME_BIN, args, { stdio: "ignore", timeout: 1000 });
      if (res.status === 0) return;
    }
    fd = openSync("/dev/tty", "w");
    const promptTag = isPrompt && state === "working" ? ";omg_event=prompt" : "";
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=amp;omg_scope=${scope};omg_liveness=pid\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=amp;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${promptTag}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export default function (amp) {
  amp.on("agent.start", () => report("working", false, true));
  amp.on("agent.end", () => report("done"));
}
"""#

    private static let ompExtension = #"""
// OMG agent status integration for OMP.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";
import { spawnSync } from "node:child_process";

const contextId = `omg-agent-omp-${process.pid}`;
const scope = process.env.SSH_CONNECTION || process.env.OMG_RUNTIME_REMOTE ? "remote" : "local";
function report(state?: string, end = false, context?: any, attention?: string, eventKind?: string) {
  let fd: number | undefined;
  try {
    const raw = context?.sessionManager?.getSessionId?.();
    const validConv = Boolean(raw && /^[A-Za-z0-9._][A-Za-z0-9._-]{0,127}$/.test(String(raw)));
    const conversation = validConv
      ? `;omg_conversation=${encodeURIComponent(String(raw))}` : "";
    // Report the session's project directory so restoration resumes the
    // conversation in the directory that owns it, not the shell's cwd.
    const rawCwd = context?.sessionManager?.getCwd?.();
    const validCwd = Boolean(
      rawCwd && String(rawCwd).startsWith("/") &&
      String(rawCwd).length <= 4096 && !String(rawCwd).includes("\0"),
    );
    const sessionCwd = validCwd
      ? `;omg_cwd=${encodeURIComponent(String(rawCwd))}` : "";
    if (process.env.OMG_RUNTIME_BIN) {
      const args = [
        "report",
        "omp",
        end ? "end" : String(state),
        validConv ? String(raw) : "-",
        validCwd ? String(rawCwd) : process.cwd(),
        "--pid",
        String(process.pid),
      ];
      if (attention) args.push("--attention", attention);
      if (eventKind && state === "working") args.push("--event", eventKind);
      const res = spawnSync(process.env.OMG_RUNTIME_BIN, args, { stdio: "ignore", timeout: 1000 });
      if (res.status === 0) return;
    }
    const attentionKind = attention ? `;omg_attention=${attention}` : "";
    const eventTag = eventKind && state === "working" ? `;omg_event=${eventKind}` : "";
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=omp;omg_scope=${scope};omg_liveness=pid${conversation}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=omp;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${conversation}${sessionCwd}${attentionKind}${eventTag}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export default function (omp: any) {
  let waitingUnnamedCount = 0;
  const waitingToolCalls = new Set<string>();
  const waitingTools = new Set(["ask_user_question", "ask_question", "question", "confirm"]);
  const validID = (value: any) => typeof value === "string" && value.length > 0 && value.length <= 256;
  const clearWaitingTools = () => {
    waitingToolCalls.clear();
    waitingUnnamedCount = 0;
  };
  omp.on("session_start", async (_event: any, context: any) => {
    clearWaitingTools();
    report("idle", false, context);
  });
  omp.on("agent_start", async (_event: any, context: any) => {
    clearWaitingTools();
    report("working", false, context, undefined, "prompt");
  });
  omp.on("tool_call", async (event: any, context: any) => {
    const waiting = waitingTools.has(String(event?.toolName));
    const callId = validID(event?.toolCallId) ? event.toolCallId : undefined;
    if (waiting) {
      if (callId) waitingToolCalls.add(callId); else waitingUnnamedCount += 1;
      report("needsAttention", false, context, "question");
    }
  });
  omp.on("tool_result", async (event: any, context: any) => {
    const hadWaiting = waitingToolCalls.size > 0 || waitingUnnamedCount > 0;
    const callId = validID(event?.toolCallId) ? event.toolCallId : undefined;
    if (callId && waitingToolCalls.has(callId)) {
      waitingToolCalls.delete(callId);
    } else if (!callId && waitingUnnamedCount > 0 && waitingTools.has(String(event?.toolName))) {
      waitingUnnamedCount = Math.max(0, waitingUnnamedCount - 1);
    }
    if (hadWaiting && waitingToolCalls.size === 0 && waitingUnnamedCount === 0) {
      report("working", false, context, undefined, "attention_resolved");
    }
  });
  omp.on("agent_end", async (_event: any, context: any) => {
    clearWaitingTools();
    report("done", false, context);
  });
  omp.on("session_shutdown", async (_event: any, context: any) => {
    clearWaitingTools();
    report("idle", false, context);
    report(undefined, true, context);
  });
}
"""#

    private static let openCodeExtension = #"""
// OMG agent status integration for OpenCode.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";
import { spawnSync } from "node:child_process";

const contextId = `omg-agent-opencode-${process.pid}`;
const scope = process.env.SSH_CONNECTION || process.env.OMG_RUNTIME_REMOTE ? "remote" : "local";
const roots = new Set();
const children = new Map();
const busySessions = new Set();
const busyChildren = new Set();
const pendingDoneRoots = new Set();
let lastConversation;
let exitHookRegistered = false;

function report(state, conversation, end = false, attention, eventKind, phase) {
  let fd;
  try {
    const validConv = Boolean(
      conversation && /^[A-Za-z0-9._][A-Za-z0-9._-]{0,127}$/.test(String(conversation)),
    );
    if (validConv) lastConversation = String(conversation);
    if (process.env.OMG_RUNTIME_BIN) {
      const args = [
        "report",
        "opencode",
        end ? "end" : String(state),
        validConv ? String(conversation) : "-",
        process.cwd(),
        "--pid",
        String(process.pid),
      ];
      if (attention) args.push("--attention", attention);
      if (phase) args.push("--phase", phase, "--message", "Background work running");
      if (eventKind && state === "working") args.push("--event", eventKind);
      const res = spawnSync(process.env.OMG_RUNTIME_BIN, args, { stdio: "ignore", timeout: 1000 });
      if (res.status === 0) return;
    }
    const safe = validConv
      ? `;omg_conversation=${encodeURIComponent(String(conversation))}` : "";
    const attentionKind = attention ? `;omg_attention=${attention}` : "";
    const activityPhase = phase ? `;omg_phase=${phase};message=Background%20work%20running` : "";
    const eventTag = eventKind && state === "working" ? `;omg_event=${eventKind}` : "";
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=opencode;omg_scope=${scope};omg_liveness=pid${safe}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=opencode;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${safe}${attentionKind}${activityPhase}${eventTag}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

function resolveRoot(id) {
  let current = id;
  let hops = 0;
  while (children.has(current) && hops++ < 8) {
    current = children.get(current);
  }
  roots.add(current);
  return current;
}

function hasBusyChildren(rootId) {
  for (const childId of busyChildren) {
    if (resolveRoot(childId) === rootId) return true;
  }
  return false;
}

function registerExitHook() {
  if (exitHookRegistered) return;
  exitHookRegistered = true;
  process.once("exit", () => {
    if (roots.size === 0 && !lastConversation) return;
    report("idle", lastConversation, false);
    report(undefined, lastConversation, true);
  });
}

export const OmgAgentStatus = async () => {
  registerExitHook();
  return {
    event: async ({ event }) => {
      const info = event.properties?.info;
      if (event.type === "session.created" || event.type === "session.updated") {
        if (info?.id) {
          if (info.parentID) {
            roots.delete(info.id);
            children.set(info.id, info.parentID);
          } else {
            children.delete(info.id);
            roots.add(info.id);
          }
        }
        return;
      }
      if (event.type === "session.deleted") {
        if (info?.id) {
          const parentRoot = children.has(info.id) ? resolveRoot(info.id) : undefined;
          children.delete(info.id);
          busySessions.delete(info.id);
          const wasBusyChild = busyChildren.delete(info.id);
          if (roots.delete(info.id)) {
            pendingDoneRoots.delete(info.id);
            report(undefined, info.id, true);
          } else if (
            wasBusyChild &&
            parentRoot &&
            !busySessions.has(parentRoot) &&
            pendingDoneRoots.has(parentRoot) &&
            !hasBusyChildren(parentRoot)
          ) {
            pendingDoneRoots.delete(parentRoot);
            report("done", parentRoot);
          }
        }
        return;
      }
      const id = event.properties?.sessionID ?? info?.sessionID ?? info?.id;
      if (!id) return;
      if (
        event.type === "permission.updated" ||
        event.type === "permission.asked" ||
        event.type === "question.asked"
      ) {
        const rootId = resolveRoot(id);
        if (!hasBusyChildren(rootId)) busySessions.add(rootId);
        const kind = event.type === "question.asked" ? "question" : "permission";
        return report("needsAttention", rootId, false, kind);
      }
      if (
        event.type === "permission.replied" ||
        event.type === "question.replied" ||
        event.type === "question.rejected"
      ) {
        const rootId = resolveRoot(id);
        if (busySessions.has(rootId)) {
          return report("working", rootId, false, undefined, "attention_resolved");
        }
        if (hasBusyChildren(rootId)) {
          return report("working", rootId, false, undefined, "attention_resolved", "background");
        }
        return;
      }
      if (children.has(id)) {
        const rootId = resolveRoot(id);
        if (event.type === "session.status") {
          const statusType = event.properties?.status?.type ?? event.properties?.status;
          if (statusType === "busy" || statusType === "retry") {
            busyChildren.add(id);
            if (!busySessions.has(rootId)) {
              pendingDoneRoots.add(rootId);
              return report("working", rootId, false, undefined, undefined, "background");
            }
            return;
          }
          if (statusType === "idle") {
            const wasBusy = busyChildren.delete(id);
            if (wasBusy && !busySessions.has(rootId) && pendingDoneRoots.has(rootId) && !hasBusyChildren(rootId)) {
              pendingDoneRoots.delete(rootId);
              return report("done", rootId);
            }
            return;
          }
        }
        if (event.type === "session.idle" || event.type === "session.error") {
          const wasBusy = busyChildren.delete(id);
          if (wasBusy && !busySessions.has(rootId) && pendingDoneRoots.has(rootId) && !hasBusyChildren(rootId)) {
            pendingDoneRoots.delete(rootId);
            return report("done", rootId);
          }
        }
        return;
      }
      roots.add(id);
      if (event.type === "session.error") {
        busySessions.delete(id);
        pendingDoneRoots.delete(id);
        return report("error", id);
      }
      if (event.type === "session.status") {
        const statusType = event.properties?.status?.type ?? event.properties?.status;
        if (statusType === "busy" || statusType === "retry") {
          const isFirstBusy = !busySessions.has(id);
          busySessions.add(id);
          pendingDoneRoots.delete(id);
          return report("working", id, false, undefined, isFirstBusy ? "prompt" : undefined);
        }
        if (statusType === "idle") {
          const wasBusy = busySessions.delete(id);
          if (hasBusyChildren(id)) {
            if (wasBusy) pendingDoneRoots.add(id);
            return report("working", id, false, undefined, undefined, "background");
          }
          pendingDoneRoots.delete(id);
          return report(wasBusy ? "done" : "idle", id);
        }
      }
      if (event.type === "session.idle") {
        const wasBusy = busySessions.delete(id);
        if (hasBusyChildren(id)) {
          if (wasBusy) pendingDoneRoots.add(id);
          return report("working", id, false, undefined, undefined, "background");
        }
        pendingDoneRoots.delete(id);
        return report(wasBusy ? "done" : "idle", id);
      }
    },
  };
};
"""#
}

enum AgentActivityUpdate: Equatable, Sendable {
    case set(TabActivity)
    case clear
}

struct AgentSessionSignal: Equatable, Sendable {
    let contextID: String
    let agent: SupportedAgent
    let scope: AgentExecutionScope
    let conversationID: AgentConversationID?
    /// The session's own project directory reported by the agent hook via
    /// `omg_cwd`, when the hook supports it. Resuming a conversation is
    /// directory-scoped for agents such as Pi, so restoration must prefer
    /// this over the pane's shell working directory.
    let workingDirectory: String?
    /// True when the signal represents a scoped subagent/background task (`omg_context` or `omg_phase=background`).
    let isBackgroundSubcontext: Bool

    init(
        contextID: String,
        agent: SupportedAgent,
        scope: AgentExecutionScope,
        conversationID: AgentConversationID?,
        workingDirectory: String?,
        isBackgroundSubcontext: Bool = false
    ) {
        self.contextID = contextID
        self.agent = agent
        self.scope = scope
        self.conversationID = conversationID
        self.workingDirectory = workingDirectory
        self.isBackgroundSubcontext = isBackgroundSubcontext
    }
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
            let lhsPriority = priority(lhs.activity)
            let rhsPriority = priority(rhs.activity)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.isFocused != rhs.isFocused {
                return !lhs.isFocused && rhs.isFocused
            }
            return false
        }?.activity
    }

    static func priority(_ activity: TabActivity) -> Int {
        switch activity.state {
        case .needsAttention: 5
        case .working: activity.phase == .background ? 3 : 4
        case .error: 2
        case .done: 1
        case .idle: 0
        }
    }
}

enum AgentLivenessIdentity: Equatable, Sendable {
    case process(Int)
    case processGroup(Int)

    func matchesProcessGroup(_ value: Int?) -> Bool {
        guard case .processGroup(let processGroupID) = self else { return false }
        return processGroupID == value
    }
}

struct AgentContextSignalReducer: Sendable {
    private enum Scope: String, Sendable {
        case local
        case remote
        case legacy
    }

    private struct Identity: Sendable {
        let value: Int?
    }

    private struct Record: Sendable {
        let id: String
        let context: String?
        let activity: TabActivity
        let scope: Scope
        let liveness: AgentLivenessIdentity?
        let updatedAt: Date
        let terminated: Bool
        let isFallbackTier: Bool
    }

    static let maximumTrackedContexts = 32
    private static let startupValidationGrace: TimeInterval = 4
    private var activities: [Record] = []

    var trackedContextCount: Int { activities.count }
    var currentContextID: String? { currentRecord?.id }
    var currentActivity: TabActivity? { currentRecord?.activity }
    var hasRemoteActivity: Bool { activities.contains { $0.scope == .remote } }

    func hasActiveLocalContext(
        for agent: SupportedAgent,
        processGroupID: Int,
        isProcessAlive: (Int) -> Bool,
        isProcessGroupAlive: (Int) -> Bool = { _ in false }
    ) -> Bool {
        guard let current = currentRecord,
              !current.terminated,
              current.scope == .local,
              current.activity.source == agent.rawValue else { return false }
        if current.id == "omg-agent-\(agent.rawValue)-\(processGroupID)" {
            return true
        }
        switch current.liveness {
        case .process(let pid)?:
            return isProcessAlive(pid)
        case .processGroup(let pgid)?:
            return (current.activity.state == .working ||
                current.activity.state == .needsAttention) &&
                isProcessGroupAlive(pgid)
        case nil:
            return false
        }
    }

    var validationIdentity: AgentLivenessIdentity? {
        guard let current = currentRecord,
              current.scope == .local else { return nil }
        return current.liveness
    }

    var requiresForegroundValidation: Bool {
        validationIdentity != nil
    }

    static func sessionSignal(
        from signal: Ghostty.ContextSignal
    ) -> AgentSessionSignal? {
        guard signal.action == .start else { return nil }
        let metadata = metadata(signal.metadata)
        guard metadata["type"] == "app",
              let rawAgent = metadata["omg_agent"],
              let agent = SupportedAgent(rawValue: rawAgent),
              identity(signal.id, agent: agent) != nil,
              let rawScope = metadata["omg_scope"],
              let scope = AgentExecutionScope(rawValue: rawScope) else { return nil }
        let conversationID = metadata["omg_conversation"]?
            .removingPercentEncoding
            .flatMap(AgentConversationID.init)
        let workingDirectory = metadata["omg_cwd"]?
            .removingPercentEncoding
            .flatMap(Self.validatedSessionWorkingDirectory)
        let isBackgroundSubcontext = subContext(from: metadata) != nil || metadata["omg_phase"] == "background"
        return .init(
            contextID: signal.id,
            agent: agent,
            scope: scope,
            conversationID: conversationID,
            workingDirectory: workingDirectory,
            isBackgroundSubcontext: isBackgroundSubcontext
        )
    }

    /// Validates a session working directory reported via `omg_cwd`. The
    /// value must be an absolute POSIX path with bounded length and no NUL
    /// bytes; anything else is treated as absent so restoration falls back
    /// to the pane's shell working directory.
    private static func validatedSessionWorkingDirectory(
        _ value: String
    ) -> String? {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              value.utf8.count <= 4_096 else { return nil }
        return value
    }

    private static func subContext(from metadata: [String: String]) -> String? {
        guard let raw = metadata["omg_context"]?.removingPercentEncoding,
              !raw.isEmpty,
              raw.utf8.count <= 128 else { return nil }
        return raw
    }

    mutating func consume(_ signal: Ghostty.ContextSignal) -> AgentActivityUpdate? {
        guard signal.id.hasPrefix("omg-agent-") else { return nil }
        switch signal.action {
        case .end:
            return consumeEnd(signal)

        case .start:
            let metadata = Self.metadata(signal.metadata)
            guard metadata["type"] == "app",
                  let rawAgent = metadata["omg_agent"],
                  let agent = SupportedAgent(rawValue: rawAgent),
                  let identity = Self.identity(signal.id, agent: agent),
                  let rawState = metadata["omg_state"],
                  let state = Self.state(rawState) else { return nil }
            let scope = metadata["omg_scope"].flatMap(Scope.init) ?? .legacy
            let context = Self.subContext(from: metadata)
            let isFallbackTier = metadata["omg_tier"] == "fallback"
            let liveness = Self.liveness(
                identity: identity,
                agent: agent,
                scope: scope,
                metadata: metadata
            )
            let progress = metadata["progress"].flatMap(Double.init).flatMap {
                (0...1).contains($0) ? $0 : nil
            }
            let attentionKind = state == .needsAttention
                ? metadata["omg_attention"].flatMap(TabAttentionKind.init)
                : nil
            let phase: TabActivityPhase? = if state == .working {
                if metadata["omg_phase"] == "background" {
                    .background
                } else if metadata["omg_phase"] == "foreground" {
                    nil
                } else if context != nil {
                    .background
                } else {
                    nil
                }
            } else {
                nil
            }
            let eventKind = metadata["omg_event"]
            let isPrompt = eventKind == "prompt"
            let unlocksAttention = isPrompt || eventKind == "attention_resolved"
            if state == .working,
               let existing = activities.first(where: {
                   $0.id == signal.id && $0.context == context
               }),
               !existing.terminated,
               existing.activity.state == .needsAttention,
               !unlocksAttention || (phase == .background && isPrompt) {
                return nil
            }
            activities.removeAll { $0.terminated && $0.scope == scope }
            if state == .working, phase != .background {
                activities.removeAll {
                    $0.terminated &&
                        ($0.activity.state == .done || $0.activity.state == .error)
                }
                for idx in activities.indices
                where !(activities[idx].id == signal.id && activities[idx].context == context) &&
                    (activities[idx].activity.state == .done ||
                        activities[idx].activity.state == .error ||
                        (unlocksAttention && activities[idx].activity.state == .needsAttention &&
                            (isPrompt || activities[idx].id == signal.id))) {
                    let old = activities[idx]
                    activities[idx] = Record(
                        id: old.id,
                        context: old.context,
                        activity: TabActivity(
                            source: old.activity.source,
                            state: .idle,
                            label: old.activity.label,
                            message: nil,
                            detail: nil,
                            progress: nil,
                            icon: old.activity.icon
                        ),
                        scope: old.scope,
                        liveness: old.liveness,
                        updatedAt: old.updatedAt,
                        terminated: false,
                        isFallbackTier: old.isFallbackTier
                    )
                }
            }
            let activity = TabActivity(
                source: agent.rawValue,
                state: state,
                phase: phase,
                attentionKind: attentionKind,
                label: agent.displayName,
                message: metadata["message"]?.removingPercentEncoding,
                detail: nil,
                progress: progress,
                icon: agent.icon
            )
            activities.removeAll { $0.id == signal.id && $0.context == context }
            if activities.count >= Self.maximumTrackedContexts {
                activities.removeFirst(
                    activities.count - Self.maximumTrackedContexts + 1
                )
            }
            activities.append(Record(
                id: signal.id,
                context: context,
                activity: activity,
                scope: scope,
                liveness: liveness,
                updatedAt: Date(),
                terminated: false,
                isFallbackTier: isFallbackTier
            ))
            return currentRecord.map { .set($0.activity) } ?? .clear
        }
    }

    mutating func reconcileLocalForegroundProcess(
        _ foregroundPID: Int?,
        livenessIsAlive: Bool? = nil,
        confirmedProcessExit: Bool = false,
        now: Date = Date()
    ) -> AgentActivityUpdate? {
        var removedCurrent = false
        while let index = selectedIndex {
            let current = activities[index]
            guard current.scope == .local,
                  let liveness = current.liveness else { break }
            if livenessIsAlive == true || liveness.matchesProcessGroup(foregroundPID) {
                break
            }
            guard livenessIsAlive != nil else { return nil }
            if !confirmedProcessExit {
                guard now.timeIntervalSince(current.updatedAt) >=
                        Self.startupValidationGrace else { return nil }
            }
            if current.activity.state == .working ||
                current.activity.state == .needsAttention {
                activities.removeAll { $0.id == current.id && $0.context != current.context }
                return markUnexpectedInterruption(record: current, now: now)
            }
            activities.remove(at: index)
            removedCurrent = true
        }
        guard removedCurrent else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    var acknowledgmentCandidate: AcknowledgedAgentStatus.ReducerRecord? {
        guard let current = currentRecord,
              current.activity.state == .done ||
                current.activity.state == .error else { return nil }
        return .init(
            contextID: current.id,
            source: current.activity.source,
            state: current.activity.state,
            message: current.activity.message
        )
    }

    mutating func acknowledgeTerminalState(
        liveProcessGroupID: Int? = nil
    ) -> AgentActivityUpdate? {
        guard let index = selectedIndex else { return nil }
        let current = activities[index]
        guard current.activity.state == .done ||
                current.activity.state == .error else { return nil }
        let idle = TabActivity(
            source: current.activity.source,
            state: .idle,
            label: current.activity.label,
            message: nil,
            detail: nil,
            progress: nil,
            icon: current.activity.icon
        )
        if current.terminated {
            if let livePGID = liveProcessGroupID, livePGID > 0 {
                let revivedID = "omg-agent-\(current.activity.source)-\(livePGID)"
                activities[index] = Record(
                    id: revivedID,
                    context: nil,
                    activity: idle,
                    scope: current.scope,
                    liveness: current.scope == .local ? .processGroup(livePGID) : nil,
                    updatedAt: Date(),
                    terminated: false,
                    isFallbackTier: current.isFallbackTier
                )
                return currentRecord.map { .set($0.activity) } ?? .set(idle)
            }
            activities.remove(at: index)
            return currentRecord.map { .set($0.activity) } ?? .clear
        }
        activities[index] = Record(
            id: current.id,
            context: current.context,
            activity: idle,
            scope: current.scope,
            liveness: current.liveness,
            updatedAt: current.updatedAt,
            terminated: false,
            isFallbackTier: current.isFallbackTier
        )
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    mutating func consumeRemotePrompt(
        _ signal: Ghostty.ContextSignal
    ) -> AgentActivityUpdate? {
        guard signal.action == .start,
              signal.id.hasPrefix("omg-ssh-"),
              Self.metadata(signal.metadata)["cwd"] != nil ||
                Self.metadata(signal.metadata)["cwdhex"] != nil else { return nil }
        return clearRemoteActivities()
    }

    /// Removes all remote-owned presentation after the local SSH transport is
    /// known to have ended. Local nested contexts, if any, become visible
    /// again instead of being discarded with the remote connection.
    mutating func clearRemoteActivities() -> AgentActivityUpdate? {
        let previous = currentRecord?.activity
        let previousID = currentRecord?.id
        activities.removeAll { $0.scope == .remote }
        guard previousID != currentRecord?.id || previous != currentRecord?.activity else {
            return nil
        }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private var selectedIndex: Int? {
        guard !activities.isEmpty else { return nil }
        let useRemote = hasRemoteActivity
        let scopedIndices = activities.indices.filter {
            !useRemote || activities[$0].scope == .remote
        }
        let typedAgents = Set(scopedIndices.compactMap { idx -> String? in
            let rec = activities[idx]
            return rec.isFallbackTier ? nil : rec.activity.source
        })
        let candidateIndices = scopedIndices.filter { idx in
            let rec = activities[idx]
            return !rec.isFallbackTier || !typedAgents.contains(rec.activity.source)
        }
        var bestIndex: Int?
        var bestPriority = -1
        for index in candidateIndices {
            let priority = AgentActivitySelection.priority(activities[index].activity)
            if priority >= bestPriority {
                bestPriority = priority
                bestIndex = index
            }
        }
        return bestIndex ?? scopedIndices.last ?? activities.indices.last
    }

    private var currentRecord: Record? {
        selectedIndex.map { activities[$0] }
    }

    private mutating func consumeEnd(_ signal: Ghostty.ContextSignal) -> AgentActivityUpdate? {
        let metadata = Self.metadata(signal.metadata)
        if let context = Self.subContext(from: metadata) {
            return remove(id: signal.id, context: context)
        }
        guard let index = activities.firstIndex(where: { $0.id == signal.id && $0.context == nil })
            ?? activities.lastIndex(where: { $0.id == signal.id }) else {
            return nil
        }
        let current = activities[index]
        if current.id == currentRecord?.id,
           current.context == currentRecord?.context,
           current.activity.state == .working ||
            current.activity.state == .needsAttention {
            activities.removeAll { $0.id == signal.id && $0.context != current.context }
            return markUnexpectedInterruption(record: current)
        }
        if current.activity.state == .error,
           current.terminated {
            return nil
        }
        return removeAll(id: signal.id)
    }

    private mutating func markUnexpectedInterruption(
        record: Record,
        now: Date = Date()
    ) -> AgentActivityUpdate {
        let error = TabActivity(
            source: record.activity.source,
            state: .error,
            label: record.activity.label,
            message: "Agent process exited unexpectedly.",
            detail: nil,
            progress: nil,
            icon: record.activity.icon
        )
        if let index = activities.firstIndex(where: {
            $0.id == record.id && $0.context == record.context
        }) {
            activities[index] = Record(
                id: record.id,
                context: record.context,
                activity: error,
                scope: record.scope,
                liveness: nil,
                updatedAt: now,
                terminated: true,
                isFallbackTier: record.isFallbackTier
            )
        }
        return currentRecord.map { .set($0.activity) } ?? .set(error)
    }

    private mutating func remove(id: String, context: String?) -> AgentActivityUpdate? {
        let previous = currentRecord?.activity
        let previousID = currentRecord?.id
        let previousContext = currentRecord?.context
        guard let index = activities.firstIndex(where: {
            $0.id == id && $0.context == context
        }) else {
            return nil
        }
        activities.remove(at: index)
        guard previousID != currentRecord?.id ||
                previousContext != currentRecord?.context ||
                previous != currentRecord?.activity else {
            return nil
        }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private mutating func removeAll(id: String) -> AgentActivityUpdate? {
        let previous = currentRecord?.activity
        let previousID = currentRecord?.id
        let previousContext = currentRecord?.context
        guard activities.contains(where: { $0.id == id }) else {
            return nil
        }
        activities.removeAll { $0.id == id }
        guard previousID != currentRecord?.id ||
                previousContext != currentRecord?.context ||
                previous != currentRecord?.activity else {
            return nil
        }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private static func identity(
        _ id: String,
        agent: SupportedAgent
    ) -> Identity? {
        let prefix = "omg-agent-\(agent.rawValue)"
        if id == prefix { return Identity(value: nil) }
        guard id.hasPrefix(prefix + "-") else { return nil }
        let raw = id.dropFirst(prefix.count + 1)
        guard !raw.isEmpty,
              raw.count <= 20,
              raw.allSatisfy(\.isNumber),
              let value = Int(raw),
              value > 0 else { return nil }
        return Identity(value: value)
    }

    private static func liveness(
        identity: Identity,
        agent: SupportedAgent,
        scope: Scope,
        metadata: [String: String]
    ) -> AgentLivenessIdentity? {
        guard scope == .local, let value = identity.value else { return nil }
        switch metadata["omg_liveness"] {
        case "pid": return .process(value)
        case "pgid": return .processGroup(value)
        case nil:
            // Hook plugins historically used their process PID in the context
            // suffix, while shell/config hooks and foreground synthesis used a
            // process-group ID. Preserve both old formats during hook upgrades.
            return agent.definition.hook.kind == .plugin
                ? .process(value)
                : .processGroup(value)
        default: return nil
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
