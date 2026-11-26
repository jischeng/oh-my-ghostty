import Foundation

/// Uses the unified OMG command installed by +ssh. Never installs an editor or
/// sends keys to an unprepared remote session from an auxiliary SSH connection.
enum QuickInputRemoteDraftBridge {
    struct Target: Decodable {
        let session: String
        let tty: String
        var root: String?
        var commands: String?
        var generation: String?
    }

    private static let pythonPathPrefix = "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin\"; export PATH; "

    static func command(_ action: String, session: String, request: String, tty: String? = nil, root: String? = nil,
                        generation: String? = nil) -> String {
        let arguments = [action, session, request] + (tty.map { [$0] } ?? []) + (generation.map { [$0] } ?? [])
        let prefix = root.map {
            pythonPathPrefix + "exec env OMG_REMOTE_ROOT=" + Ghostty.Shell.quote($0) + " python3 " + Ghostty.Shell.quote($0 + "/omg")
        } ?? (pythonPathPrefix + "exec python3 \"$HOME/.local/share/oh-my-ghostty/remote/omg\"")
        let script = prefix + " " +
            arguments.map(Ghostty.Shell.quote).joined(separator: " ")
        return SSHSessionTransport.shellCommand(script)
    }

    static func runtimeTarget(connection: GitSSHConnection, revision: String, pane: UUID) async throws -> Target {
        let command = pythonPathPrefix + "exec python3 - " + [revision, pane.uuidString].map(Ghostty.Shell.quote).joined(separator: " ")
        let result = try await SSHSessionTransport.run(connection: connection, command: command,
            stdin: Data(runtimeProbe.utf8), limit: 65_536, timeout: 10)
        guard result.isSuccess else {
            throw NSError(domain: "OMGRemoteDraft", code: result.stderrString.contains("OMG_RUNTIME_DRAFT_UNAVAILABLE") ? 1 : 2)
        }
        return try JSONDecoder().decode(Target.self, from: result.stdout)
    }

    static let runtimeProbe = #"""
    import hashlib, json, os, pathlib, re, stat, subprocess, sys, uuid
    revision, pane = sys.argv[1:]
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', revision):
        raise ValueError('Invalid runtime revision')
    pane = str(uuid.UUID(pane))
    home = pathlib.Path.home()
    run_root = home / '.omg/run'
    def read(path):
        data = path.read_bytes()
        if len(data) > 65536: raise ValueError('Invalid runtime metadata')
        return json.loads(data)
    def safe_identity(tokens):
        known = {
            'agy', 'antigravity', 'antigravity-cli', 'jetski', 'jetski-cli',
            'claude', 'claude-code', 'codex', 'openai-codex', 'gemini',
            'opencode', 'pi', 'pi-coding-agent', 'omp', 'oh-my-pi', 'aider',
            'goose', 'amp', 'crush', 'droid', 'kimi', 'kimi-code', 'qwen',
            'qwen-code', 'qoder', 'copilot', 'gh-copilot', 'github-copilot-cli',
            'cline', 'cursor', 'hermes', 'grok', 'reasonix',
        }
        def is_wrapper(name):
            return (
                name in ('env', 'login', 'sh', 'bash', 'zsh', 'fish', 'node', 'bun', 'deno', 'python', 'python3')
                or name.startswith('python3.')
            )
        first = os.path.basename(tokens[0]).lstrip('-').lower()
        if not is_wrapper(first):
            return tokens[:1]
        out = [tokens[0]]
        takes_value = False
        for t in tokens[1:7]:
            if takes_value:
                takes_value = False
                out.append(t)
                continue
            if '=' in t and not t.startswith('-'):
                continue
            if t.startswith('-'):
                out.append(t)
                if t in ('-r', '--require', '--import', '--loader', '--conditions'):
                    takes_value = True
                continue
            base = os.path.basename(t).lower()
            if is_wrapper(base):
                out.append(t)
                continue
            if '/' in t or base in known:
                out.append(t)
            break
        return out
    def probe_tty_and_foreground(pid, expected_tty):
        try:
            tty = subprocess.run(['ps', '-o', 'tty=', '-p', str(pid)],
                                 capture_output=True, text=True, check=True, timeout=3).stdout.strip()
            tty = tty if tty.startswith('/dev/') else '/dev/' + tty
            if tty != expected_tty:
                raise ValueError('Runtime TTY changed')
            result = subprocess.run(['ps', '-t', tty[5:], '-o', 'pgid=,tpgid=,args='],
                                    capture_output=True, text=True, check=True, timeout=3)
            commands = []
            for line in result.stdout.splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3 and fields[0] == fields[1] and int(fields[0]) > 0:
                    tokens = fields[2].split()
                    if tokens:
                        commands.append(' '.join(safe_identity(tokens))[:4096])
                        if len(commands) >= 8: break
            return tty, commands
        except (OSError, subprocess.SubprocessError):
            proc = pathlib.Path('/proc')
            stat_path = proc / str(pid) / 'stat'
            if not expected_tty or not stat_path.is_file():
                raise
            raw = stat_path.read_text(errors='replace')
            fields = raw[raw.rfind(')') + 2:].split()
            tty_nr = int(fields[4])
            if tty_nr <= 0 or os.stat(expected_tty).st_rdev != tty_nr:
                raise ValueError('Runtime TTY changed')
            commands = []
            for entry in proc.iterdir():
                if not entry.name.isdigit(): continue
                try:
                    p_raw = (entry / 'stat').read_text(errors='replace')
                    p_fields = p_raw[p_raw.rfind(')') + 2:].split()
                    if int(p_fields[4]) == tty_nr and p_fields[2] == p_fields[5] and int(p_fields[2]) > 0:
                        cmdline = (entry / 'cmdline').read_bytes().rstrip(b'\0')
                        tokens = [part.decode('utf-8', 'replace') for part in cmdline.split(b'\0') if part]
                        if tokens:
                            commands.append(' '.join(safe_identity(tokens))[:4096])
                            if len(commands) >= 8: break
                except (OSError, ValueError, IndexError):
                    continue
            return expected_tty, commands
    candidates = []
    rstate_file = home / '.local/share/oh-my-ghostty/session-runtime/versions' / revision / 'remote-state-dir'
    try:
        if rstate_file.is_file() and not rstate_file.is_symlink():
            rstate = rstate_file.read_text(errors='replace').strip()
            if re.fullmatch(r'[A-Za-z0-9._-]{1,64}', rstate) and rstate not in ('.', '..'):
                candidates.append(run_root / rstate)
    except OSError:
        pass
    legacy_state = run_root / hashlib.sha256(revision.encode()).hexdigest()[:12]
    if legacy_state not in candidates:
        candidates.append(legacy_state)
    try:
        if run_root.is_dir() and not run_root.is_symlink():
            epochs = []
            for entry in run_root.iterdir():
                if entry not in candidates and re.fullmatch(r's-[0-9a-f]{12}', entry.name):
                    try:
                        st = entry.lstat()
                        if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid():
                            epochs.append((st.st_mtime, entry.name, entry))
                    except OSError:
                        continue
            for _, _, entry in sorted(epochs, reverse=True):
                candidates.append(entry)
    except OSError:
        pass
    state = None
    record = None
    saw_ended = False
    for candidate in candidates:
        try:
            info = candidate.lstat()
        except OSError:
            continue
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            continue
        for value in (pane, pane.upper()):
            record_path = candidate / 'sessions' / (value + '.json')
            try:
                rec_info = record_path.lstat()
            except OSError:
                continue
            if not stat.S_ISREG(rec_info.st_mode) or rec_info.st_uid != os.getuid():
                continue
            try:
                loaded = read(record_path)
            except (OSError, ValueError):
                continue
            if str(loaded.get('id', '')).lower() != pane:
                continue
            if loaded.get('ended') is not None:
                saw_ended = True
                continue
            state = candidate
            record = loaded
            break
        if record is not None:
            break
    if state is None or record is None:
        if saw_ended:
            raise ValueError('Runtime session is not active')
        raise FileNotFoundError('Runtime session record not found')
    session = 'omg-runtime-' + pane
    root = state / 'draft'
    metadata_path = root / 'sessions' / hashlib.sha256(session.encode()).hexdigest() / 'session.json'
    if not metadata_path.exists() or not (root / 'omg').is_file():
        raise ValueError('OMG_RUNTIME_DRAFT_UNAVAILABLE')
    metadata = read(metadata_path)
    if (metadata.get('protocol') != 1 or str(metadata.get('runtime_id', '')).lower() != pane
            or metadata.get('runtime_generation') != record.get('generation')):
        raise ValueError('Runtime session generation changed')
    pid = record.get('pid')
    if not isinstance(pid, int) or pid <= 1: raise ValueError('Invalid runtime process')
    tty, commands = probe_tty_and_foreground(pid, metadata.get('tty'))
    print(json.dumps(dict(session=session, tty=tty, root=str(root), commands='\n'.join(commands),
                         generation=record['generation'])))
    """#

    /// Probe the actual foreground process group, including agents launched by
    /// user aliases/functions which deliberately bypass our startup wrappers.
    static func foregroundAgent(connection: GitSSHConnection, session: String, tty: String) async throws -> SupportedAgent? {
        let arguments = [session, tty].map(Ghostty.Shell.quote).joined(separator: " ")
        let result = try await SSHSessionTransport.run(
            connection: connection, command: pythonPathPrefix + "exec python3 - " + arguments,
            stdin: Data(foregroundProbe.utf8), limit: 65_536, timeout: 10
        )
        guard result.isSuccess else { throw CocoaError(.fileReadUnknown) }
        return LocalAgentProcessDetector.detect(in: result.stdoutString)
    }

    static let foregroundProbe = #"""
    import hashlib, json, os, pathlib, subprocess, sys
    session, tty = sys.argv[1:]
    directory = pathlib.Path.home() / '.local/share/oh-my-ghostty/remote/sessions' / hashlib.sha256(session.encode()).hexdigest()
    metadata = json.loads((directory / 'session.json').read_text())
    if metadata.get('protocol') != 1 or metadata.get('tty') != tty:
        raise ValueError('Remote session mismatch')
    def safe_identity(tokens):
        known = {
            'agy', 'antigravity', 'antigravity-cli', 'jetski', 'jetski-cli',
            'claude', 'claude-code', 'codex', 'openai-codex', 'gemini',
            'opencode', 'pi', 'pi-coding-agent', 'omp', 'oh-my-pi', 'aider',
            'goose', 'amp', 'crush', 'droid', 'kimi', 'kimi-code', 'qwen',
            'qwen-code', 'qoder', 'copilot', 'gh-copilot', 'github-copilot-cli',
            'cline', 'cursor', 'hermes', 'grok', 'reasonix',
        }
        def is_wrapper(name):
            return (
                name in ('env', 'login', 'sh', 'bash', 'zsh', 'fish', 'node', 'bun', 'deno', 'python', 'python3')
                or name.startswith('python3.')
            )
        first = os.path.basename(tokens[0]).lstrip('-').lower()
        if not is_wrapper(first):
            return tokens[:1]
        out = [tokens[0]]
        takes_value = False
        for t in tokens[1:7]:
            if takes_value:
                takes_value = False
                out.append(t)
                continue
            if '=' in t and not t.startswith('-'):
                continue
            if t.startswith('-'):
                out.append(t)
                if t in ('-r', '--require', '--import', '--loader', '--conditions'):
                    takes_value = True
                continue
            base = os.path.basename(t).lower()
            if is_wrapper(base):
                out.append(t)
                continue
            if '/' in t or base in known:
                out.append(t)
            break
        return out
    try:
        result = subprocess.run(['ps', '-t', tty[5:] if tty.startswith('/dev/') else tty, '-o', 'pgid=,tpgid=,args='],
                                capture_output=True, text=True, check=True, timeout=3)
        count = 0
        for line in result.stdout.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and fields[0] == fields[1] and int(fields[0]) > 0:
                # Only executable/runtime identity is needed; never return prompt args.
                tokens = fields[2].split()
                if tokens:
                    print(' '.join(safe_identity(tokens))[:4096])
                    count += 1
                    if count >= 8:
                        break
    except (OSError, subprocess.SubprocessError):
        proc = pathlib.Path('/proc')
        tty_path = tty if tty.startswith('/dev/') else '/dev/' + tty
        if not proc.is_dir():
            raise
        tty_nr = os.stat(tty_path).st_rdev
        count = 0
        for entry in proc.iterdir():
            if not entry.name.isdigit(): continue
            try:
                p_raw = (entry / 'stat').read_text(errors='replace')
                p_fields = p_raw[p_raw.rfind(')') + 2:].split()
                if int(p_fields[4]) == tty_nr and p_fields[2] == p_fields[5] and int(p_fields[2]) > 0:
                    cmdline = (entry / 'cmdline').read_bytes().rstrip(b'\0')
                    tokens = [part.decode('utf-8', 'replace') for part in cmdline.split(b'\0') if part]
                    if tokens:
                        print(' '.join(safe_identity(tokens))[:4096])
                        count += 1
                        if count >= 8:
                            break
            except (OSError, ValueError, IndexError):
                continue
    """#

    static func begin(connection: GitSSHConnection, session: String, request: String, tty: String, root: String? = nil,
                      generation: String? = nil, replacement: String? = nil) async throws {
        let result = try await SSHSessionTransport.run(
            connection: connection, command: command(replacement == nil ? "draft-begin" : "draft-replace",
                session: session, request: request, tty: tty, root: root, generation: generation),
            stdin: replacement.map { Data($0.utf8) },
            limit: 8_192, timeout: 10
        )
        guard result.isSuccess,
              result.stdoutString.split(separator: "\n").contains("OMG_REMOTE_READY_V1") else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    static func receive(connection: GitSSHConnection, session: String, request: String, root: String? = nil) async throws -> String {
        let result = try await SSHSessionTransport.run(
            connection: connection, command: command("draft-read", session: session, request: request, root: root),
            limit: 1_048_576 + 8_192, timeout: 10
        )
        return try decode(result)
    }

    static func decode(_ result: GitExecutionResult) throws -> String {
        let marker = Data("OMG_REMOTE_DRAFT_V1\n".utf8)
        guard result.isSuccess, let range = result.stdout.range(of: marker) else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = result.stdout[range.upperBound...]
        guard data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    static func finish(connection: GitSSHConnection, session: String, request: String, root: String? = nil) async {
        _ = try? await SSHSessionTransport.run(
            connection: connection, command: command("draft-finish", session: session, request: request, root: root),
            limit: 8_192, timeout: 5
        )
    }
}
