import Darwin
import Foundation

/// Discovers an active Agent conversation on a remote SSH pane (or local process group)
/// before any new prompt triggers lifecycle hooks.
///
/// Multi-pane disambiguation resolves each pane to its own remote TTY (via the managed
/// `omgd` session record or shell-reported `remoteTTY`), inspects only the foreground
/// Agent process on that TTY, and prefers per-process live conversation locks
/// (`~/.gemini/antigravity-cli/presence/<id>.lock`), explicit CLI resume flags, and
/// open `brain/<id>` handles before consulting workspace summary timestamps.
enum AgentRemoteConversationDiscovery {
    struct Request: Equatable, Sendable {
        var agent: SupportedAgent?
        var connection: GitSSHConnection
        var runtimeRevision: String?
        var runtimePaneID: UUID?
        var remoteTTY: String?
        var remoteWorkingDirectory: String?
        var launchedAfter: Date
        var excludedConversationIDs: Set<AgentConversationID> = []
        var homeDirectoryOverride: String?
    }

    struct Result: Equatable, Sendable {
        let agent: SupportedAgent?
        let conversationID: AgentConversationID?
        let workingDirectory: String?
        let isAuthoritative: Bool

        init(
            agent: SupportedAgent?,
            conversationID: AgentConversationID?,
            workingDirectory: String?,
            isAuthoritative: Bool = true
        ) {
            self.agent = agent
            self.conversationID = conversationID
            self.workingDirectory = workingDirectory
            self.isAuthoritative = isAuthoritative
        }
    }

    typealias Discoverer = @Sendable (Request) async -> Result?

    private struct WireRequest: Encodable {
        let agent: String?
        let runtimeRevision: String?
        let runtimePaneID: String?
        let remoteTTY: String?
        let remoteWorkingDirectory: String?
        let launchedAfterEpoch: Double
        let excludedIDs: [String]
        let homeOverride: String?

        enum CodingKeys: String, CodingKey {
            case agent
            case runtimeRevision = "runtime_revision"
            case runtimePaneID = "runtime_pane_id"
            case remoteTTY = "remote_tty"
            case remoteWorkingDirectory = "remote_cwd"
            case launchedAfterEpoch = "launched_after"
            case excludedIDs = "excluded_ids"
            case homeOverride = "home_override"
        }
    }

    private struct WireResponse: Decodable {
        let agent: String?
        let conversationID: String?
        let workingDirectory: String?
        let authoritative: Bool?

        enum CodingKeys: String, CodingKey {
            case agent
            case conversationID = "conversation_id"
            case workingDirectory = "cwd"
            case authoritative
        }
    }

    private static let pythonPathPrefix = "unset SDKROOT; PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; export PATH; "

    static let live: Discoverer = { request in
        guard let encoded = try? encodeWireRequest(request) else { return nil }
        let command = pythonPathPrefix + "exec python3 - " + Ghostty.Shell.quote(encoded)
        guard let result = try? await SSHSessionTransport.run(
            connection: request.connection,
            command: command,
            stdin: Data(probeScript.utf8),
            limit: 16_384,
            timeout: 8,
            multiplexing: true,
            idempotent: true
        ), result.isSuccess else {
            return nil
        }
        return decodeWireResponse(result.stdout)
    }

    nonisolated static func encodeWireRequest(_ request: Request) throws -> String {
        let payload = WireRequest(
            agent: request.agent?.rawValue,
            runtimeRevision: request.runtimeRevision,
            runtimePaneID: request.runtimePaneID?.uuidString.lowercased(),
            remoteTTY: request.remoteTTY,
            remoteWorkingDirectory: request.remoteWorkingDirectory,
            launchedAfterEpoch: request.launchedAfter.timeIntervalSince1970,
            excludedIDs: request.excludedConversationIDs.map(\.rawValue).sorted(),
            homeOverride: request.homeDirectoryOverride
        )
        return try JSONEncoder().encode(payload).base64EncodedString()
    }

    nonisolated static func decodeWireResponse(_ data: Data) -> Result? {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              let jsonData = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WireResponse.self, from: jsonData) else {
            return nil
        }
        let resolvedAgent = decoded.agent.flatMap(AgentProgramStatus.resolveAgent)
        let resolvedConversation = decoded.conversationID.flatMap(AgentConversationID.init)
        let resolvedCwd = SessionRuntimeDescriptor.validWorkingDirectory(decoded.workingDirectory)
        if resolvedAgent == nil && resolvedConversation == nil && resolvedCwd == nil {
            return nil
        }
        return Result(
            agent: resolvedAgent,
            conversationID: resolvedConversation,
            workingDirectory: resolvedCwd,
            isAuthoritative: resolvedConversation != nil && (decoded.authoritative ?? false)
        )
    }

    /// Inspects live processes in a local foreground process group for an active
    /// Antigravity conversation (via `presence/<id>.lock`, CLI resume flags, or `brain/<id>`),
    /// resolving child/worker IDs to their top-level user conversation.
    nonisolated static func discoverLocalAntigravity(
        processGroupID: Int,
        workingDirectory: String,
        excluding claimedConversationIDs: Set<AgentConversationID>,
        rootURL: URL? = nil
    ) -> AgentConversationID? {
        guard processGroupID > 1 else { return nil }
        let root = rootURL ?? URL(
            fileURLWithPath: ("~/.gemini/antigravity-cli/conversations" as NSString).expandingTildeInPath
        )
        let appDir = root.deletingLastPathComponent()
        let brainDir = appDir.appendingPathComponent("brain", isDirectory: true)

        func storeExists(_ id: AgentConversationID) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(id.rawValue + ".db").path)
                || (FileManager.default.fileExists(atPath: brainDir.appendingPathComponent(id.rawValue).path, isDirectory: &isDir) && isDir.boolValue)
        }

        func validRoot(_ raw: String) -> AgentConversationID? {
            guard let candidate = AgentConversationID(raw) else { return nil }
            let resolution = AgentHistoryStore.resolveAntigravityRootConversation(
                conversationID: candidate,
                rootURL: root
            )
            let rootID = resolution.rootID
            if resolution.isChild && rootID == candidate { return nil }
            guard !claimedConversationIDs.contains(rootID), storeExists(rootID) else { return nil }
            return rootID
        }

        guard let psOutput = runLocalCommand("/bin/ps", arguments: ["-o", "pid=,args=", "-g", String(processGroupID)]) else {
            return nil
        }
        var matchedProcs: [(pid: Int, cmd: String)] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int(parts[0]), pid > 1 else { continue }
            let cmd = String(parts[1])
            if LocalAgentProcessDetector.detect(in: cmd) == .antigravity {
                matchedProcs.append((pid: pid, cmd: cmd))
            }
        }
        guard !matchedProcs.isEmpty else { return nil }
        matchedProcs.sort { lhs, rhs in
            (lhs.pid == processGroupID ? 0 : 1) < (rhs.pid == processGroupID ? 0 : 1)
        }
        let agyPIDs = matchedProcs.map(\.pid)
        let agyArgvLines = matchedProcs.map(\.cmd)

        // 1. Live `presence/<id>.lock` open FD on the Antigravity process.
        let pidList = agyPIDs.map(String.init).joined(separator: ",")
        if let lsofOut = runLocalCommand("/usr/sbin/lsof", arguments: ["-Fn", "-p", pidList]) {
            var lockRoots = Set<AgentConversationID>()
            var brainRoots = Set<AgentConversationID>()
            for line in lsofOut.split(separator: "\n") where line.first == "n" {
                let path = String(line.dropFirst())
                if let range = path.range(of: #"/presence/([A-Za-z0-9._-]{1,128})\.lock$"#, options: .regularExpression) {
                    let name = URL(fileURLWithPath: String(path[range])).deletingPathExtension().lastPathComponent
                    if let resolved = validRoot(name) { lockRoots.insert(resolved) }
                } else if let marker = path.range(of: "/antigravity-cli/brain/") {
                    let tail = path[marker.upperBound...]
                    let segment = tail.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                    if let resolved = validRoot(segment) { brainRoots.insert(resolved) }
                }
            }
            if lockRoots.count == 1, let sole = lockRoots.first { return sole }
            for cmd in agyArgvLines {
                if let explicit = parseExplicitAntigravityFlag(in: cmd).flatMap(validRoot) {
                    return explicit
                }
            }
            if brainRoots.count == 1, let sole = brainRoots.first { return sole }
        } else {
            for cmd in agyArgvLines {
                if let explicit = parseExplicitAntigravityFlag(in: cmd).flatMap(validRoot) {
                    return explicit
                }
            }
        }

        // 2. Explicit `-c` / `--continue` resumes the most recent top-level workspace conversation.
        let hasContinue = agyArgvLines.contains { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().contains { $0 == "-c" || $0 == "--continue" }
        }
        if hasContinue {
            return latestUnclaimedAntigravityWorkspaceConversation(
                workingDirectory: workingDirectory,
                excluding: claimedConversationIDs,
                root: root
            )
        }
        return nil
    }

    nonisolated private static func parseExplicitAntigravityFlag(in commandLine: String) -> String? {
        let tokens = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--conversation" || token == "--resume" || token == "-r" {
                if index + 1 < tokens.count {
                    return tokens[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
                break
            }
            for prefix in ["--conversation=", "--resume=", "-r="] where token.hasPrefix(prefix) {
                return String(token.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            index += 1
        }
        return nil
    }

    nonisolated private static func latestUnclaimedAntigravityWorkspaceConversation(
        workingDirectory: String,
        excluding claimedConversationIDs: Set<AgentConversationID>,
        root: URL
    ) -> AgentConversationID? {
        let index = root.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db")
        guard let database = AgentHistoryDatabase(path: index.path) else { return nil }
        let target = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        var resolved: AgentConversationID?
        let sql = """
        SELECT conversation_id, workspace_uris FROM conversation_summaries
        WHERE nesting_depth = 0 ORDER BY last_modified_time DESC LIMIT 100
        """
        database.query(sql) { row in
            guard let id = row.text(0).flatMap(AgentConversationID.init),
                  !claimedConversationIDs.contains(id) else { return true }
            let uris = (row.text(1) ?? "").data(using: .utf8).flatMap {
                try? JSONDecoder().decode([String].self, from: $0)
            } ?? []
            let matches = uris.compactMap(URL.init(string:)).contains {
                $0.isFileURL && $0.resolvingSymlinksInPath().standardizedFileURL.path == target
            }
            guard matches,
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(id.rawValue + ".db").path) else {
                return true
            }
            resolved = id
            return false
        }
        return resolved
    }

    nonisolated private static func runLocalCommand(_ executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            let pid = process.processIdentifier
            let watchdog = DispatchWorkItem {
                if pid > 1 { Darwin.kill(pid, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: watchdog)
            defer { watchdog.cancel() }
            let handle = output.fileHandleForReading
            var captured = Data()
            while let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty {
                let remaining = max(0, 131_072 - captured.count)
                if remaining > 0 { captured.append(chunk.prefix(remaining)) }
            }
            guard exited.wait(timeout: .now() + 2) == .success,
                  process.terminationStatus == 0 else {
                if pid > 1 { Darwin.kill(pid, SIGKILL) }
                return nil
            }
            return String(data: captured, encoding: .utf8)
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
    }

    nonisolated static let probeScript = #"""
import base64
import hashlib
import json
import os
import pathlib
import re
import shlex
import sqlite3
import stat
import subprocess
import sys
import time
import urllib.parse

VALID_ID_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]{0,127}$")
VALID_TTY_RE = re.compile(r"^/dev/(?:ttys[0-9]+|tty[A-Za-z0-9._-]+|pts/[0-9]+)$")

AGENT_ALIASES = {
    "agy": "antigravity",
    "antigravity": "antigravity",
    "antigravity-cli": "antigravity",
    "jetski": "antigravity",
    "jetski-cli": "antigravity",
    "claude": "claude",
    "claude-code": "claude",
    "claude_code": "claude",
    "codex": "codex",
    "openai-codex": "codex",
    "pi": "pi",
    "pi-coding-agent": "pi",
    "omp": "omp",
    "oh-my-pi": "omp",
    "opencode": "opencode",
    "qwen": "qwen",
    "qwen-code": "qwen",
    "qoder": "qoder",
    "qodercli": "qoder",
    "grok": "grok",
    "hermes": "hermes",
    "cursor-agent": "cursor",
    "copilot": "copilot",
    "github-copilot-cli": "copilot",
    "gh-copilot": "copilot",
    "amp": "amp",
    "cline": "cline",
    "kimi": "kimi",
    "kimi-code": "kimi",
    "crush": "crush",
    "droid": "droid",
    "reasonix": "reasonix",
}

WRAPPERS = {
    "env", "login", "sh", "bash", "zsh", "fish", "dash", "ksh",
    "node", "nodejs", "bun", "deno", "python", "python3",
}

WRAPPER_VALUE_FLAGS = {
    "-r", "--require", "--import", "--loader", "--conditions",
    "--rcfile", "--init-file", "-u", "--unset", "-C", "--chdir",
}


def valid_id(raw):
    return isinstance(raw, str) and bool(VALID_ID_RE.match(raw))


def elapsed_seconds(text):
    text = (text or "").strip()
    if not text:
        return 0.0
    days, _, rest = text.rpartition("-")
    parts = [int(part) for part in rest.split(":")]
    secs = sum(val * (60 ** idx) for idx, val in enumerate(reversed(parts)))
    return float(secs + (int(days) * 86400 if days else 0))


def detect_agent_and_args(tokens):
    if not tokens:
        return None, []
    idx = 0
    while idx < len(tokens) and idx < 10:
        tok = tokens[idx]
        base = os.path.basename(tok.lstrip("-")).lower()
        if base in AGENT_ALIASES:
            return AGENT_ALIASES[base], tokens[idx + 1:]
        if "/versions/" in tok.lower():
            segs = [s for s in tok.lower().split("/") if s]
            if len(segs) >= 3 and segs[-2] == "versions" and segs[-3] in AGENT_ALIASES:
                return AGENT_ALIASES[segs[-3]], tokens[idx + 1:]
        if "@anthropic-ai/claude-code" in tok.lower():
            return "claude", tokens[idx + 1:]
        if idx == 0 or base in WRAPPERS or base.startswith("python3."):
            idx += 1
            while idx < len(tokens) and idx < 12:
                arg = tokens[idx]
                if arg == "--":
                    idx += 1
                    break
                if arg in WRAPPER_VALUE_FLAGS:
                    idx += 2
                    continue
                if arg in ("-c", "-lc", "-lic", "-ic") and idx + 1 < len(tokens):
                    try:
                        inner = shlex.split(tokens[idx + 1])
                    except ValueError:
                        inner = tokens[idx + 1].split()
                    return detect_agent_and_args(inner)
                if arg.startswith("-") or ("=" in arg and not arg.startswith("/")):
                    idx += 1
                    continue
                break
            continue
        break
    return None, []


def read_proc_cmdline(pid):
    try:
        raw = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().rstrip(b"\0")
        if raw:
            return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
    except OSError:
        pass
    return None


def read_proc_cwd(pid):
    try:
        target = os.readlink(f"/proc/{pid}/cwd")
        if target.startswith("/") and "\0" not in target and len(target) <= 4096:
            return target
    except OSError:
        pass
    try:
        out = subprocess.run(
            ["lsof", "-a", "-d", "cwd", "-Fn", "-p", str(pid)],
            capture_output=True, text=True, timeout=2
        ).stdout
        for line in out.splitlines():
            if line.startswith("n/") and "\0" not in line and len(line) <= 4097:
                return line[1:]
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def read_open_paths(pid):
    paths = []
    fd_dir = pathlib.Path(f"/proc/{pid}/fd")
    if fd_dir.is_dir():
        try:
            for idx, entry in enumerate(os.listdir(fd_dir)):
                if idx >= 4096:
                    break
                try:
                    paths.append(os.readlink(fd_dir / entry))
                except OSError:
                    continue
            return paths
        except OSError:
            pass
    try:
        out = subprocess.run(
            ["lsof", "-Fn", "-p", str(pid)],
            capture_output=True, text=True, timeout=2
        ).stdout
        for line in out.splitlines():
            if line.startswith("n"):
                paths.append(line[1:])
    except (OSError, subprocess.SubprocessError):
        pass
    return paths


def resolve_runtime_tty(home, revision, pane_id):
    if not revision or not pane_id:
        return None
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", revision):
        return None
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", pane_id):
        return None
    pane_lower = pane_id.lower()
    run_root = home / ".omg" / "run"
    candidates = []
    rstate_file = home / ".local/share/oh-my-ghostty/session-runtime/versions" / revision / "remote-state-dir"
    try:
        if rstate_file.is_file() and not rstate_file.is_symlink():
            rstate = rstate_file.read_text(errors="replace").strip()
            if re.fullmatch(r"[A-Za-z0-9._-]{1,64}", rstate) and rstate not in (".", ".."):
                candidates.append(run_root / rstate)
    except OSError:
        pass
    legacy = run_root / hashlib.sha256(revision.encode()).hexdigest()[:12]
    if legacy not in candidates:
        candidates.append(legacy)
    try:
        if run_root.is_dir() and not run_root.is_symlink():
            epochs = []
            for entry in run_root.iterdir():
                if entry not in candidates and re.fullmatch(r"s-[0-9a-f]{12}", entry.name):
                    try:
                        st = entry.lstat()
                        if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid():
                            epochs.append((st.st_mtime, entry))
                    except OSError:
                        continue
            for _, entry in sorted(epochs, reverse=True):
                candidates.append(entry)
    except OSError:
        pass

    uid = os.getuid()
    record = None
    for cand in candidates:
        try:
            st = cand.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid:
                continue
        except OSError:
            continue
        for name in (pane_lower, pane_lower.upper()):
            rec_path = cand / "sessions" / f"{name}.json"
            try:
                rst = rec_path.lstat()
                if not stat.S_ISREG(rst.st_mode) or rst.st_uid != uid or rst.st_size > 65536:
                    continue
                loaded = json.loads(rec_path.read_bytes())
            except (OSError, ValueError):
                continue
            if str(loaded.get("id", "")).lower() != pane_lower:
                continue
            if loaded.get("ended") is not None:
                continue
            record = loaded
            break
        if record is not None:
            break

    if not isinstance(record, dict):
        return None
    pid = record.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        return None
    try:
        tty = subprocess.run(
            ["ps", "-o", "tty=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2
        ).stdout.strip()
        if tty and tty not in ("?", "??"):
            full = tty if tty.startswith("/dev/") else "/dev/" + tty
            if VALID_TTY_RE.match(full):
                return full
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text(errors="replace")
        fields = raw[raw.rfind(")") + 2:].split()
        tty_nr = int(fields[4])
        if tty_nr > 0:
            for pts in pathlib.Path("/dev/pts").iterdir():
                if pts.name.isdigit() and os.stat(pts).st_rdev == tty_nr:
                    return str(pts)
    except (OSError, ValueError, IndexError):
        pass
    return None


def foreground_processes_on_tty(tty):
    now = time.time()
    short = tty[5:] if tty.startswith("/dev/") else tty
    procs = []
    try:
        res = subprocess.run(
            ["ps", "-t", short, "-o", "pid=,pgid=,tpgid=,etime=,args="],
            capture_output=True, text=True, timeout=2
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                fields = line.strip().split(None, 4)
                if len(fields) < 5:
                    continue
                try:
                    pid, pgid, tpgid = int(fields[0]), int(fields[1]), int(fields[2])
                    started = now - elapsed_seconds(fields[3])
                except ValueError:
                    continue
                if pid <= 1 or pgid <= 0 or pgid != tpgid:
                    continue
                tokens = read_proc_cmdline(pid)
                if not tokens:
                    try:
                        tokens = shlex.split(fields[4])
                    except ValueError:
                        tokens = fields[4].split()
                agent, rest = detect_agent_and_args(tokens)
                if agent:
                    procs.append({
                        "pid": pid,
                        "pgid": pgid,
                        "tty": tty,
                        "agent": agent,
                        "args": rest,
                        "started": started,
                    })
            return procs
    except (OSError, subprocess.SubprocessError):
        pass

    proc_dir = pathlib.Path("/proc")
    if proc_dir.is_dir() and os.path.exists(tty):
        try:
            tty_rdev = os.stat(tty).st_rdev
            uptime = float(pathlib.Path("/proc/uptime").read_text().split()[0])
            clk = os.sysconf("SC_CLK_TCK")
            for entry in proc_dir.iterdir():
                if not entry.name.isdigit():
                    continue
                pid = int(entry.name)
                try:
                    raw = (entry / "stat").read_text(errors="replace")
                    f = raw[raw.rfind(")") + 2:].split()
                    pgrp, tpgid, tty_nr, start_ticks = int(f[2]), int(f[5]), int(f[4]), int(f[19])
                    if tty_nr != tty_rdev or pgrp <= 0 or pgrp != tpgid:
                        continue
                    tokens = read_proc_cmdline(pid) or []
                    agent, rest = detect_agent_and_args(tokens)
                    if agent:
                        started = now - max(0.0, uptime - (start_ticks / float(clk)))
                        procs.append({
                            "pid": pid,
                            "pgid": pgrp,
                            "tty": tty,
                            "agent": agent,
                            "args": rest,
                            "started": started,
                        })
                except (OSError, ValueError, IndexError):
                    continue
        except (OSError, ValueError):
            pass
    return procs


def all_foreground_agent_processes(target_agent):
    now = time.time()
    procs = []
    try:
        res = subprocess.run(
            ["ps", "-eo", "pid=,pgid=,tpgid=,tty=,etime=,args="],
            capture_output=True, text=True, timeout=3
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                fields = line.strip().split(None, 5)
                if len(fields) < 6:
                    continue
                try:
                    pid, pgid, tpgid = int(fields[0]), int(fields[1]), int(fields[2])
                    raw_tty = fields[3]
                    started = now - elapsed_seconds(fields[4])
                except ValueError:
                    continue
                if pid <= 1 or pgid <= 0 or pgid != tpgid or raw_tty in ("?", "??"):
                    continue
                tty = raw_tty if raw_tty.startswith("/dev/") else "/dev/" + raw_tty
                if not VALID_TTY_RE.match(tty):
                    continue
                tokens = read_proc_cmdline(pid)
                if not tokens:
                    try:
                        tokens = shlex.split(fields[5])
                    except ValueError:
                        tokens = fields[5].split()
                agent, rest = detect_agent_and_args(tokens)
                if agent and (target_agent is None or agent == target_agent):
                    procs.append({
                        "pid": pid,
                        "pgid": pgid,
                        "tty": tty,
                        "agent": agent,
                        "args": rest,
                        "started": started,
                    })
    except (OSError, subprocess.SubprocessError):
        pass
    return procs


def open_ro_sqlite(db_path):
    if not db_path.is_file() or db_path.is_symlink():
        return None
    quoted = urllib.parse.quote(str(db_path))
    for mode in ("ro", "ro&immutable=1"):
        try:
            conn = sqlite3.connect(f"file:{quoted}?mode={mode}", uri=True, timeout=0.25)
            conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
            return conn
        except sqlite3.Error:
            pass
    return None


def resolve_antigravity_root(cid, app_dir):
    if not valid_id(cid):
        return None, False
    summary_db = app_dir / "conversation_summaries.db"
    conn = open_ro_sqlite(summary_db)
    if conn is None:
        return cid, False
    try:
        cur = cid
        seen = {cur}
        is_child = False
        for _ in range(8):
            try:
                row = conn.execute(
                    "SELECT parent_conversation_id, nesting_depth FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
                    (cur,)
                ).fetchone()
            except sqlite3.Error:
                return cid, False
            if not row:
                break
            parent = str(row[0] or "").strip()
            depth = int(row[1] or 0)
            if not parent and depth <= 0:
                return cur, is_child
            is_child = True
            if not valid_id(parent) or parent in seen:
                break
            seen.add(parent)
            cur = parent
        return cur, is_child
    finally:
        conn.close()


def antigravity_store_exists(cid, app_dir):
    return (app_dir / "conversations" / f"{cid}.db").is_file() or (app_dir / "brain" / cid).is_dir()


def parse_flag_value(args, flags, allow_positional_subcommand=None):
    idx = 0
    while idx < len(args):
        tok = args[idx]
        if allow_positional_subcommand and tok == allow_positional_subcommand and idx + 1 < len(args):
            cand = args[idx + 1]
            if valid_id(cand):
                return cand
        if tok in flags and idx + 1 < len(args):
            cand = args[idx + 1]
            if valid_id(cand):
                return cand
            idx += 2
            continue
        for flag in flags:
            prefix = flag + "="
            if tok.startswith(prefix):
                cand = tok[len(prefix):]
                if valid_id(cand):
                    return cand
        idx += 1
    return None


def resolve_antigravity_for_proc(proc, home, fallback_cwd, excluded, allow_cwd_fallback):
    app_dir = home / ".gemini" / "antigravity-cli"
    proc_cwd = read_proc_cwd(proc["pid"]) or fallback_cwd

    def accept_candidate(raw_id):
        root_id, is_child = resolve_antigravity_root(raw_id, app_dir)
        if not root_id or (is_child and root_id == raw_id):
            return None
        if root_id in excluded or not antigravity_store_exists(root_id, app_dir):
            return None
        return root_id

    open_paths = read_open_paths(proc["pid"])
    lock_roots = set()
    brain_roots = set()
    for p in open_paths:
        m_lock = re.search(r"/presence/([A-Za-z0-9._-]{1,128})\.lock$", p)
        if m_lock:
            resolved = accept_candidate(m_lock.group(1))
            if resolved:
                lock_roots.add(resolved)
            continue
        m_brain = re.search(r"/antigravity-cli/brain/([A-Za-z0-9._-]{1,128})(?:/|$)", p)
        if m_brain:
            resolved = accept_candidate(m_brain.group(1))
            if resolved:
                brain_roots.add(resolved)

    if len(lock_roots) == 1:
        return next(iter(lock_roots)), proc_cwd, True

    flag_id = parse_flag_value(proc["args"], ("--conversation", "--resume", "-r"))
    if flag_id:
        resolved = accept_candidate(flag_id)
        if resolved:
            return resolved, proc_cwd, True

    if len(brain_roots) == 1:
        return next(iter(brain_roots)), proc_cwd, True

    if not allow_cwd_fallback or not proc_cwd:
        return None, proc_cwd, False

    summary_db = app_dir / "conversation_summaries.db"
    conn = open_ro_sqlite(summary_db)
    if conn is None:
        return None, proc_cwd, False
    try:
        target_cwd = os.path.realpath(proc_cwd)
        has_continue = any(arg in ("-c", "--continue") for arg in proc["args"])
        try:
            rows = conn.execute(
                "SELECT conversation_id, workspace_uris, strftime('%s', last_modified_time) "
                "FROM conversation_summaries WHERE nesting_depth = 0 ORDER BY last_modified_time DESC LIMIT 200"
            ).fetchall()
        except sqlite3.Error:
            rows = conn.execute(
                "SELECT conversation_id, workspace_uris, strftime('%s', last_modified_time) "
                "FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 200"
            ).fetchall()

        matched_rows = []
        for raw_cid, raw_uris, raw_mod in rows:
            if not valid_id(raw_cid) or raw_cid in excluded:
                continue
            db_file = app_dir / "conversations" / f"{raw_cid}.db"
            if not db_file.is_file():
                continue
            try:
                uris = json.loads(raw_uris) if raw_uris else []
            except ValueError:
                uris = []
            cwd_ok = False
            for uri in uris:
                if isinstance(uri, str) and uri.startswith("file://"):
                    parsed_path = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
                    if os.path.realpath(parsed_path) == target_cwd:
                        cwd_ok = True
                        break
            if not cwd_ok:
                continue
            try:
                st = db_file.stat()
            except OSError:
                continue
            mod_ts = float(raw_mod) if (raw_mod is not None and float(raw_mod) > 0) else st.st_mtime
            matched_rows.append((raw_cid, st.st_ctime, mod_ts))

        if has_continue:
            return (matched_rows[0][0] if matched_rows else None), proc_cwd, False

        threshold = proc["started"] - 2.0
        created = []
        resumed = []
        for cid, ctime, mtime in matched_rows:
            if ctime >= threshold:
                created.append(cid)
            elif mtime >= threshold:
                resumed.append((cid, mtime))
        if len(created) == 1:
            return created[0], proc_cwd, False
        if len(created) > 1:
            return None, proc_cwd, False
        resumed.sort(key=lambda item: item[1], reverse=True)
        if not resumed:
            return None, proc_cwd, False
        if len(resumed) > 1 and (resumed[0][1] - resumed[1][1]) < 2.0:
            return None, proc_cwd, False
        return resumed[0][0], proc_cwd, False
    finally:
        conn.close()


def generic_store_contains(agent, cid, home):
    roots = {
        "claude": (".claude/projects", ".jsonl"),
        "codex": (".codex/sessions", ".jsonl"),
        "pi": (".pi/agent/sessions", ".jsonl"),
        "omp": (".omp/agent/sessions", ".jsonl"),
        "qwen": (".qwen/tmp", ".jsonl"),
        "qoder": (".qoder/projects", ".jsonl"),
        "grok": (".grok/sessions", ""),
    }
    if agent == "opencode":
        return (home / ".local/share/opencode/opencode.db").is_file()
    if agent == "hermes":
        return (home / ".hermes/state.db").is_file()
    spec = roots.get(agent)
    if not spec:
        return False
    base = home / spec[0]
    suffix = spec[1]
    if not base.is_dir():
        return False
    inspected = 0
    for root_dir, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fname in files:
            inspected += 1
            if inspected > 50000:
                return False
            if suffix and not (fname.endswith(suffix) or fname.endswith(suffix + ".zst")):
                continue
            if cid in fname:
                return True
    return False


def resolve_generic_for_proc(proc, home, fallback_cwd, excluded):
    proc_cwd = read_proc_cwd(proc["pid"]) or fallback_cwd
    agent = proc["agent"]
    flags_by_agent = {
        "claude": (("--resume", "-r"), None),
        "codex": (("--resume",), "resume"),
        "pi": (("--session-id", "--session"), None),
        "omp": (("--resume",), None),
        "opencode": (("--session", "-s"), None),
        "qwen": (("--resume",), None),
        "qoder": (("--resume",), None),
        "grok": (("--resume",), None),
        "hermes": (("--resume",), None),
    }
    spec = flags_by_agent.get(agent)
    if not spec:
        return None, proc_cwd, False
    cid = parse_flag_value(proc["args"], spec[0], spec[1])
    if cid and cid not in excluded and generic_store_contains(agent, cid, home):
        return cid, proc_cwd, True
    return None, proc_cwd, False


def main():
    if len(sys.argv) < 2:
        print("{}")
        return
    req = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
    home_override = req.get("home_override")
    home = pathlib.Path(home_override) if home_override else pathlib.Path.home()
    requested_agent = req.get("agent")
    excluded = {cid for cid in (req.get("excluded_ids") or []) if valid_id(cid)}
    fallback_cwd = req.get("remote_cwd")
    if not (isinstance(fallback_cwd, str) and fallback_cwd.startswith("/") and len(fallback_cwd) <= 4096):
        fallback_cwd = None

    tty = resolve_runtime_tty(home, req.get("runtime_revision"), req.get("runtime_pane_id"))
    if not tty:
        raw_tty = req.get("remote_tty")
        if isinstance(raw_tty, str) and VALID_TTY_RE.match(raw_tty):
            tty = raw_tty

    if tty:
        procs = foreground_processes_on_tty(tty)
        if requested_agent:
            procs = [p for p in procs if p["agent"] == requested_agent]
        if not procs:
            print("{}")
            return
        procs.sort(key=lambda p: (0 if p["pid"] == p["pgid"] else 1, -p["started"]))
        siblings = None
        chosen_agent = procs[0]["agent"]
        chosen_cwd = None
        chosen_cid = None
        chosen_auth = False
        for proc in procs:
            agent = proc["agent"]
            if agent == "antigravity":
                allow_cwd_fallback = True
                if siblings is None:
                    siblings = [
                        p for p in all_foreground_agent_processes("antigravity")
                        if p["tty"] != tty
                    ]
                if siblings:
                    sel_cwd = os.path.realpath(read_proc_cwd(proc["pid"]) or fallback_cwd or "")
                    for sib in siblings:
                        sib_cwd = os.path.realpath(read_proc_cwd(sib["pid"]) or "")
                        if sel_cwd and sib_cwd == sel_cwd:
                            sib_cid, _, _ = resolve_antigravity_for_proc(sib, home, None, set(), False)
                            if not sib_cid or sib_cid not in excluded:
                                allow_cwd_fallback = False
                                break
                cid, resolved_cwd, auth = resolve_antigravity_for_proc(
                    proc, home, fallback_cwd, excluded, allow_cwd_fallback
                )
            else:
                cid, resolved_cwd, auth = resolve_generic_for_proc(proc, home, fallback_cwd, excluded)
            if chosen_cwd is None and resolved_cwd:
                chosen_cwd = resolved_cwd
            if cid:
                chosen_agent = agent
                chosen_cid = cid
                chosen_cwd = resolved_cwd or chosen_cwd
                chosen_auth = bool(auth)
                break
        out = {"agent": chosen_agent, "authoritative": bool(chosen_cid and chosen_auth)}
        if chosen_cid:
            out["conversation_id"] = chosen_cid
        if chosen_cwd:
            out["cwd"] = chosen_cwd
        print(json.dumps(out))
        return

    # Plain SSH fallback without runtime record or remoteTTY: succeed ONLY when all
    # unclaimed foreground processes for the target agent resolve to a single conversation.
    candidates = all_foreground_agent_processes(requested_agent)
    if not candidates:
        print("{}")
        return
    by_tty = {}
    for proc in candidates:
        by_tty.setdefault(proc["tty"], []).append(proc)
    resolved = []
    single_tty = len(by_tty) == 1
    for tty_key, tty_procs in by_tty.items():
        tty_procs.sort(key=lambda p: (0 if p["pid"] == p["pgid"] else 1, -p["started"]))
        tty_resolved = None
        for proc in tty_procs:
            if proc["agent"] == "antigravity":
                cid, cwd, auth = resolve_antigravity_for_proc(
                    proc, home, fallback_cwd, excluded, single_tty
                )
            else:
                cid, cwd, auth = resolve_generic_for_proc(proc, home, fallback_cwd, excluded)
            if cid:
                tty_resolved = (proc["agent"], cid, cwd, auth)
                break
        if tty_resolved:
            resolved.append(tty_resolved)
        elif not single_tty:
            # Another TTY has an unresolved foreground agent; refuse to guess across TTYs.
            print("{}")
            return
    unique = {(a, cid) for a, cid, _, _ in resolved}
    if len(unique) == 1:
        agent, cid, cwd, auth = resolved[0]
        out = {"agent": agent, "conversation_id": cid, "authoritative": bool(auth)}
        if cwd:
            out["cwd"] = cwd
        print(json.dumps(out))
    else:
        print("{}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("{}")
"""#
}
