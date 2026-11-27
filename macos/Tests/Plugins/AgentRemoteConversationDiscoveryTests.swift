import AppKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import Ghostty

@Suite(.serialized)
struct AgentRemoteConversationDiscoveryTests {
    typealias Seed = AgentHistoryStore.TitleSeed

    private enum AntigravityProto {
        static func varint(_ value: UInt64) -> Data {
            var remaining = value
            var bytes = Data()
            repeat {
                var next = UInt8(remaining & 0x7F)
                remaining >>= 7
                if remaining != 0 { next |= 0x80 }
                bytes.append(next)
            } while remaining != 0
            return bytes
        }

        static func field(_ number: Int, _ bytes: Data) -> Data {
            varint(UInt64((number << 3) | 2)) + varint(UInt64(bytes.count)) + bytes
        }

        static func field(_ number: Int, _ text: String) -> Data {
            field(number, Data(text.utf8))
        }

        static func field(_ number: Int, _ value: UInt64) -> Data {
            varint(UInt64(number << 3)) + varint(value)
        }
    }

    private actor TitleGeneratorStub: AITitleGenerating {
        struct Call: Equatable, Sendable {
            let prompt: String
            let nativeTitle: String?
            let projectName: String?
        }

        private let mapping: [String: String]
        private(set) var calls: [Call] = []

        init(_ mapping: [String: String]) {
            self.mapping = mapping
        }

        func title(forFirstPrompt prompt: String) async -> String? {
            await title(forFirstPrompt: prompt, nativeTitle: nil, projectName: nil)
        }

        func title(
            forFirstPrompt prompt: String,
            nativeTitle: String?,
            projectName: String?
        ) async -> String? {
            calls.append(.init(prompt: prompt, nativeTitle: nativeTitle, projectName: projectName))
            for (needle, generated) in mapping where prompt.contains(needle) || (nativeTitle?.contains(needle) == true) {
                return generated
            }
            return nil
        }
    }

    @MainActor
    private final class RetryRecorder: SessionRuntimeRetrying {
        private(set) var descriptor: SessionRuntimeDescriptor?
        private(set) var socketOverride: URL?
        private(set) var recreateRequest: SessionRuntimeRecreateRequest?
        private(set) var onFailure: (@MainActor @Sendable (String) -> Void)?

        func retry(_ descriptor: SessionRuntimeDescriptor, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
            self.descriptor = descriptor
            self.socketOverride = nil
            self.recreateRequest = nil
            self.onFailure = onFailure
        }

        func recreate(
            _ descriptor: SessionRuntimeDescriptor,
            socketOverride: URL?,
            request: SessionRuntimeRecreateRequest,
            onFailure: @escaping @MainActor @Sendable (String) -> Void
        ) throws {
            self.descriptor = descriptor
            self.socketOverride = socketOverride
            self.recreateRequest = request
            self.onFailure = onFailure
        }
    }

    private final class PTYAgentProcess {
        let primaryFD: Int32
        let replicaFD: Int32
        let ttyPath: String
        let process: Process
        var agentPID: Int32?

        init(
            pythonExecutablePath: String,
            executableURL: URL,
            arguments: [String],
            workingDirectory: URL,
            environment: [String: String]
        ) throws {
            var primary: Int32 = -1
            var replica: Int32 = -1
            var nameBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard Darwin.openpty(&primary, &replica, &nameBuffer, nil, nil) == 0 else {
                throw POSIXError(.EIO)
            }
            self.primaryFD = primary
            self.replicaFD = replica
            self.ttyPath = String(cString: nameBuffer)

            let helper = """
            import fcntl, os, signal, sys, termios
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            if os.getpid() == os.getpgrp():
                child = os.fork()
                if child > 0:
                    os.waitpid(child, 0)
                    os._exit(0)
            os.setsid()
            tty_fd = os.open(sys.argv[1], os.O_RDWR)
            fcntl.ioctl(tty_fd, termios.TIOCSCTTY, 0)
            os.tcsetpgrp(tty_fd, os.getpgrp())
            os.dup2(tty_fd, 0)
            os.dup2(tty_fd, 1)
            os.dup2(tty_fd, 2)
            if tty_fd > 2:
                os.close(tty_fd)
            os.chdir(sys.argv[2])
            os.execve(sys.argv[3], [sys.argv[3]] + sys.argv[4:], os.environ)
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonExecutablePath)
            proc.arguments = ["-c", helper, ttyPath, workingDirectory.path, executableURL.path] + arguments
            proc.environment = environment
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            self.process = proc
        }

        func waitForReadyFile(_ url: URL) async throws -> Int {
            for _ in 0..<150 where !FileManager.default.fileExists(atPath: url.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            let raw = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(Int(raw))
            self.agentPID = Int32(pid)
            return pid
        }

        private var stopped = false

        func stop() {
            guard !stopped else { return }
            stopped = true
            if replicaFD >= 0 { Darwin.close(replicaFD) }
            if primaryFD >= 0 { Darwin.close(primaryFD) }
            if let agentPID, agentPID > 1 {
                Darwin.kill(-agentPID, SIGKILL)
                Darwin.kill(agentPID, SIGKILL)
            }
            let pid = process.processIdentifier
            if pid > 1 {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-remote-agy-\(UUID().uuidString)", isDirectory: true)
    }

    private func execSQL(_ url: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func runProbeLocally(
        _ request: AgentRemoteConversationDiscovery.Request,
        python: LocalPythonInterpreter
    ) async throws -> AgentRemoteConversationDiscovery.Result? {
        let encoded = try AgentRemoteConversationDiscovery.encodeWireRequest(request)
        let runner = GitProcessRunner()
        let result = try await runner.run(
            executablePath: python.executablePath,
            arguments: ["-", encoded],
            workingDirectory: "/tmp",
            environment: python.environment,
            stdin: Data(AgentRemoteConversationDiscovery.probeScript.utf8),
            maxOutputBytes: 16_384,
            timeout: 8
        )
        #expect(result.isSuccess)
        return AgentRemoteConversationDiscovery.decodeWireResponse(result.stdout)
    }

    @Test func remoteProbeDisambiguatesMultipleSSHPanesInSameDirectoryBeforeAnyPrompt() async throws {
        let python = try await LocalPythonInterpreter.resolve()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("shared-repo", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let convDir = agyDir.appendingPathComponent("conversations", isDirectory: true)
        let presenceDir = agyDir.appendingPathComponent("presence", isDirectory: true)
        let brainDir = agyDir.appendingPathComponent("brain", isDirectory: true)
        for dir in [home, repo, binDir, convDir, presenceDir, brainDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Create a realistic `agy` stub script that holds `AGY_LOCK_FILE` open and blocks idle on the PTY.
        let agyExecutable = binDir.appendingPathComponent("agy")
        let stubSource = """
        #!/bin/sh
        if [ -n "${AGY_LOCK_FILE:-}" ]; then
            mkdir -p "$(dirname "$AGY_LOCK_FILE")"
            exec 9>>"$AGY_LOCK_FILE"
        fi
        if [ -n "${AGY_READY_FILE:-}" ]; then
            printf '%s' "$$" >"${AGY_READY_FILE}.tmp" && mv -f "${AGY_READY_FILE}.tmp" "$AGY_READY_FILE"
        fi
        IFS= read -r _
        """
        try Data(stubSource.utf8).write(to: agyExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyExecutable.path)

        let convOlder = "11111111-aaaa-4bbb-8ccc-111111111111"
        let convNewer = "22222222-aaaa-4bbb-8ccc-222222222222"
        let convWorker = "33333333-aaaa-4bbb-8ccc-333333333333"
        let fiveDaysAgo = Date().addingTimeInterval(-5 * 86_400)
        for cid in [convOlder, convNewer, convWorker] {
            let dbURL = convDir.appendingPathComponent("\(cid).db")
            try Data().write(to: dbURL)
            try FileManager.default.setAttributes(
                [.creationDate: fiveDaysAgo, .modificationDate: fiveDaysAgo],
                ofItemAtPath: dbURL.path
            )
        }

        let canonicalRepoURI = URL(fileURLWithPath: repo.resolvingSymlinksInPath().path).absoluteString
        try execSQL(agyDir.appendingPathComponent("conversation_summaries.db"), """
        PRAGMA journal_mode = WAL;
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            workspace_uris TEXT,
            last_modified_time TEXT,
            nesting_depth INTEGER,
            parent_conversation_id TEXT
        );
        INSERT INTO conversation_summaries VALUES
            ('\(convOlder)', '修复回测撮合滑点', '检查撮合引擎滑点计算', '["\(canonicalRepoURI)"]', '2026-11-20 08:00:00+00:00', 0, ''),
            ('\(convNewer)', '优化盘口订阅重连', '盘口 WebSocket 断线恢复', '["\(canonicalRepoURI)"]', '2026-11-22 14:30:00+00:00', 0, ''),
            ('\(convWorker)', '', '', '["\(canonicalRepoURI)"]', '2026-11-22 14:35:00+00:00', 1, '\(convNewer)');
        """)

        let ready1 = root.appendingPathComponent("ready1")
        let ready2 = root.appendingPathComponent("ready2")
        var baseEnv = python.environment
        baseEnv["HOME"] = home.path

        // Spawn two interactive `agy` sessions WITHOUT `--resume` in argv (simulating `/resume` picker)
        // in the EXACT SAME working directory on two distinct PTYs.
        var env1 = baseEnv
        env1["AGY_LOCK_FILE"] = presenceDir.appendingPathComponent("\(convOlder).lock").path
        env1["AGY_READY_FILE"] = ready1.path
        let pty1 = try PTYAgentProcess(
            pythonExecutablePath: python.executablePath,
            executableURL: agyExecutable,
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: repo,
            environment: env1
        )
        defer { pty1.stop() }

        var env2 = baseEnv
        // Tab 2 holds a child `/swarm` worker lock; probe must walk `parent_conversation_id` to `convNewer`.
        env2["AGY_LOCK_FILE"] = presenceDir.appendingPathComponent("\(convWorker).lock").path
        env2["AGY_READY_FILE"] = ready2.path
        let pty2 = try PTYAgentProcess(
            pythonExecutablePath: python.executablePath,
            executableURL: agyExecutable,
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: repo,
            environment: env2
        )
        defer { pty2.stop() }

        let pid1 = try await pty1.waitForReadyFile(ready1)
        let pid2 = try await pty2.waitForReadyFile(ready2)

        // Write managed `omgd` session record for Pane 1 so `runtimeRevision` + `runtimePaneID` resolution is exercised.
        let revision = "rev-90-test"
        let pane1ID = UUID()
        let stateDir = home.appendingPathComponent(".omg/run/s-0123456789ab", isDirectory: true)
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        let versionDir = home.appendingPathComponent(".local/share/oh-my-ghostty/session-runtime/versions/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try Data("s-0123456789ab\n".utf8).write(to: versionDir.appendingPathComponent("remote-state-dir"))
        let recordJSON = try JSONSerialization.data(withJSONObject: [
            "id": pane1ID.uuidString.lowercased(),
            "pid": pid1,
            "generation": "gen-1",
        ] as [String: Any])
        let recordURL = sessionsDir.appendingPathComponent("\(pane1ID.uuidString.lowercased()).json")
        try recordJSON.write(to: recordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)

        let sentinel = root.appendingPathComponent("injected-pwned")
        let connection = try GitSSHConnection(destination: "devbox", localWorkingDirectory: "/tmp")

        // Pane 1 resolves via managed `omgd` runtime record -> PTY 1 -> `convOlder` (never colliding with `convNewer`!).
        let result1 = try await runProbeLocally(.init(
            agent: .antigravity,
            connection: connection,
            runtimeRevision: revision,
            runtimePaneID: pane1ID,
            remoteTTY: nil,
            remoteWorkingDirectory: "/srv/ignored; touch \(sentinel.path)",
            launchedAfter: Date(),
            excludedConversationIDs: [],
            homeDirectoryOverride: home.path
        ), python: python)
        let expectedRepoPath = (repo.resolvingSymlinksInPath().path as NSString).standardizingPath
        #expect(result1?.agent == .antigravity)
        #expect(result1?.conversationID?.rawValue == convOlder)
        #expect((result1?.workingDirectory as NSString?)?.standardizingPath == expectedRepoPath)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))

        // Pane 2 resolves via `remoteTTY` (and `agent == nil` speculative foreground check) -> PTY 2 -> root `convNewer`.
        let result2 = try await runProbeLocally(.init(
            agent: nil,
            connection: connection,
            runtimeRevision: nil,
            runtimePaneID: nil,
            remoteTTY: pty2.ttyPath,
            remoteWorkingDirectory: nil,
            launchedAfter: Date(),
            excludedConversationIDs: [],
            homeDirectoryOverride: home.path
        ), python: python)
        #expect(result2?.agent == .antigravity)
        #expect(result2?.conversationID?.rawValue == convNewer)
        #expect((result2?.workingDirectory as NSString?)?.standardizingPath == expectedRepoPath)

        // Local `.local` discovery also disambiguates both resumed `agy` sessions via live `presence/*.lock` FDs.
        let local1 = AgentConversationStore.discover(
            agent: .antigravity,
            workingDirectory: repo.path,
            launchedAfter: Date(),
            excluding: [],
            rootURL: convDir,
            processGroupID: pid1
        )
        let local2 = AgentConversationStore.discover(
            agent: .antigravity,
            workingDirectory: repo.path,
            launchedAfter: Date(),
            excluding: [],
            rootURL: convDir,
            processGroupID: pid2
        )
        #expect(local1?.rawValue == convOlder)
        #expect(local2?.rawValue == convNewer)

        pty1.stop()
        pty2.stop()

        // Explicit CLI resume flag (`agy -r <id>`) without a `presence` lock also resolves accurately.
        let readyFlag = root.appendingPathComponent("ready-flag")
        var envFlag = baseEnv
        envFlag["AGY_READY_FILE"] = readyFlag.path
        let ptyFlag = try PTYAgentProcess(
            pythonExecutablePath: python.executablePath,
            executableURL: agyExecutable,
            arguments: ["-r", convOlder],
            workingDirectory: repo,
            environment: envFlag
        )
        defer { ptyFlag.stop() }
        _ = try await ptyFlag.waitForReadyFile(readyFlag)
        let flagResult = try await runProbeLocally(.init(
            agent: .antigravity,
            connection: connection,
            runtimeRevision: nil,
            runtimePaneID: nil,
            remoteTTY: ptyFlag.ttyPath,
            remoteWorkingDirectory: repo.path,
            launchedAfter: Date(),
            excludedConversationIDs: [],
            homeDirectoryOverride: home.path
        ), python: python)
        #expect(flagResult?.conversationID?.rawValue == convOlder)
    }

    @Test func remoteAntigravityTitleSeedExtractsDistinctNativeAndTurnOneProtobufPrompt() async throws {
        let home = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: home) }

        let agyRoot = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let convDir = agyRoot.appendingPathComponent("conversations", isDirectory: true)
        let brainDir = agyRoot.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)

        let hex = { (data: Data) in data.map { String(format: "%02x", $0) }.joined() }
        let wrappedPrompt = """
        <terminal_viewport cols="112">实时终端宽度预算</terminal_viewport>
        SSH 恢复 agy 后支持未发消息前自动重命名
        同时支持工作区批量重命名
        """
        let cleanedPrompt = "SSH 恢复 agy 后支持未发消息前自动重命名\n同时支持工作区批量重命名"
        let stepHeader = AntigravityProto.field(5, AntigravityProto.field(1, AntigravityProto.field(1, 1_795_700_000)))
        let userStep = AntigravityProto.field(1, 14) + stepHeader + AntigravityProto.field(19, AntigravityProto.field(2, wrappedPrompt))

        // 1. Turn-1 conversation where `title == preview` (with injected `<terminal_viewport>`) in WAL mode.
        try execSQL(convDir.appendingPathComponent("agy-turn1.db"), """
        PRAGMA journal_mode = WAL;
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, step_payload BLOB);
        INSERT INTO steps VALUES (0, 14, x'\(hex(userStep))');
        """)
        // 2. Distinctly titled old conversation + child swarm worker conversation.
        try Data().write(to: convDir.appendingPathComponent("agy-titled.db"))
        try Data().write(to: convDir.appendingPathComponent("agy-worker.db"))
        // 3. Unindexed trajectory not yet written into `conversation_summaries.db`.
        try execSQL(convDir.appendingPathComponent("agy-unindexed.db"), """
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, step_payload BLOB);
        INSERT INTO steps VALUES (0, 14, x'\(hex(userStep))');
        """)
        // 4. Brain-transcript-only fallback conversation.
        let brainLogs = brainDir.appendingPathComponent("agy-brain-only/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: brainLogs, withIntermediateDirectories: true)
        try Data(#"{"role":"user","content":"排查线上 Redis 连接池耗尽告警"}"#.utf8)
            .write(to: brainLogs.appendingPathComponent("transcript.jsonl"))

        try execSQL(agyRoot.appendingPathComponent("conversation_summaries.db"), """
        PRAGMA journal_mode = WAL;
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            workspace_uris TEXT,
            last_modified_time TEXT,
            nesting_depth INTEGER,
            parent_conversation_id TEXT
        );
        INSERT INTO conversation_summaries VALUES
            ('agy-turn1', '<terminal_viewport cols="112">实时终端宽度预算</terminal_viewport>', '<terminal_viewport cols="112">实时终端宽度预算</terminal_viewport>', '["file:///srv/omg"]', '2026-11-26 10:00:00.123456+00:00', 0, ''),
            ('agy-titled', 'SSH 会话自动重命名', '旧预览摘要', '["file:///srv/omg"]', '2026-10-01 09:00:00+00:00', 0, ''),
            ('agy-worker', '', '', '["file:///srv/omg"]', '2026-10-01 09:05:00+00:00', 1, 'agy-titled');
        """)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let homeLiteral = try #require(String(data: encoder.encode(home.path), encoding: .utf8))
        let access = AgentHistoryRemoteAccess(alias: "devbox") { command in
            let script = command.replacingOccurrences(of: "os.path.expanduser('~')", with: homeLiteral)
            let result = try await GitProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                workingDirectory: home.path,
                maxOutputBytes: 256_000,
                timeout: 10
            )
            guard result.isSuccess, let output = String(data: result.stdout, encoding: .utf8) else {
                throw AgentHistoryRemoteError.unavailable
            }
            return output
        }

        // Turn-1 conversation extracts full protobuf step 14 prompt and NEVER leaks `<terminal_viewport>` as `.native`.
        let turn1Seed = await AgentHistoryStore.titleSeed(
            agent: .antigravity,
            conversationID: try #require(AgentConversationID("agy-turn1")),
            remoteHost: "devbox",
            remoteAccess: access
        )
        #expect(turn1Seed == Seed(native: nil, firstPrompt: cleanedPrompt))

        // Distinctly titled conversation and its child worker both resolve to the root native title + preview.
        for rawID in ["agy-titled", "agy-worker"] {
            let seed = await AgentHistoryStore.titleSeed(
                agent: .antigravity,
                conversationID: try #require(AgentConversationID(rawID)),
                remoteHost: "devbox",
                remoteAccess: access
            )
            #expect(seed == Seed(native: "SSH 会话自动重命名", firstPrompt: "旧预览摘要"))
        }

        // Unindexed `conversations/<id>.db` and `brain/<id>` transcript fallback both yield `firstPrompt`.
        let unindexedSeed = await AgentHistoryStore.titleSeed(
            agent: .antigravity,
            conversationID: try #require(AgentConversationID("agy-unindexed")),
            remoteHost: "devbox",
            remoteAccess: access
        )
        #expect(unindexedSeed == Seed(native: nil, firstPrompt: cleanedPrompt))

        let brainSeed = await AgentHistoryStore.titleSeed(
            agent: .antigravity,
            conversationID: try #require(AgentConversationID("agy-brain-only")),
            remoteHost: "devbox",
            remoteAccess: access
        )
        #expect(brainSeed == Seed(native: nil, firstPrompt: "排查线上 Redis 连接池耗尽告警"))
    }

    @MainActor
    @Test func endToEndRemoteSSHAgyDiscoveryEnablesSingleAndBatchWorkspaceAutoRename() async throws {
        let settings = OhMyGhosttySettings.shared
        let savedHooks = settings.agentStatusHooksEnabled
        let savedMode = settings.agentSessionTitleMode
        settings.agentStatusHooksEnabled = true
        settings.agentSessionTitleMode = .off
        defer {
            settings.agentStatusHooksEnabled = savedHooks
            settings.agentSessionTitleMode = savedMode
        }

        let home = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let agyRoot = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let convDir = agyRoot.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let conv1 = try #require(AgentConversationID("agy-ssh-tab-1"))
        let conv2 = try #require(AgentConversationID("agy-ssh-tab-2"))
        let conv3 = try #require(AgentConversationID("agy-ssh-tab-3"))
        try Data().write(to: convDir.appendingPathComponent("\(conv1.rawValue).db"))
        try Data().write(to: convDir.appendingPathComponent("\(conv2.rawValue).db"))
        try Data().write(to: convDir.appendingPathComponent("\(conv3.rawValue).db"))
        try execSQL(agyRoot.appendingPathComponent("conversation_summaries.db"), """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            workspace_uris TEXT,
            last_modified_time TEXT,
            nesting_depth INTEGER,
            parent_conversation_id TEXT
        );
        INSERT INTO conversation_summaries VALUES
            ('\(conv1.rawValue)', '', '排查 Kubernetes 节点重启后 Pod 挂载超时', '["file:///srv/trading"]', '2026-11-25 10:00:00+00:00', 0, ''),
            ('\(conv2.rawValue)', '', '修复远端 SSH 会话重连后滚动历史丢失', '["file:///srv/trading"]', '2026-11-25 11:00:00+00:00', 0, ''),
            ('\(conv3.rawValue)', '风控订单流熔断治理', '风控网关订单流限流优化', '["file:///srv/trading"]', '2026-11-25 12:00:00+00:00', 0, '');
        """)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let homeLiteral = try #require(String(data: encoder.encode(home.path), encoding: .utf8))
        let remoteAccess = AgentHistoryRemoteAccess(alias: "devbox") { command in
            let script = command.replacingOccurrences(of: "os.path.expanduser('~')", with: homeLiteral)
            let result = try await GitProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                workingDirectory: home.path,
                maxOutputBytes: 256_000,
                timeout: 10
            )
            guard result.isSuccess, let text = String(data: result.stdout, encoding: .utf8) else {
                throw AgentHistoryRemoteError.unavailable
            }
            return text
        }

        let titleStore = AgentConversationTitleStore()
        let generator = TitleGeneratorStub([
            "Pod 挂载超时": "K8s 挂载超时排查",
            "滚动历史丢失": "SSH 历史恢复修复",
            "熔断治理": "风控熔断治理",
        ])
        let coordinator = AgentConversationTitleCoordinator(
            store: titleStore,
            generator: generator,
            loadSeed: { target in
                await AgentHistoryStore.titleSeed(
                    agent: target.agent,
                    conversationID: target.conversationID,
                    remoteHost: target.remoteHost,
                    remoteAccess: remoteAccess
                )
            },
            mode: { OhMyGhosttySettings.shared.agentSessionTitleMode },
            sleep: { _ in }
        )

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let inlineTab = try fixture.tab()
        let backendTab = try fixture.tab()
        let plainSSHTab = try fixture.tab()
        let manualTab = try fixture.tab()
        for tab in [inlineTab, backendTab, plainSSHTab, manualTab] {
            tab.startAgentConversationTitleTracking(coordinator: coordinator)
        }

        let inlineSurface = try #require(inlineTab.surfaceTree.first)
        let backendSurface = try #require(backendTab.surfaceTree.first)
        let plainSSHSurface = try #require(plainSSHTab.surfaceTree.first)
        let remoteConnection = try GitSSHConnection(destination: "devbox", options: ["-p", "2222"], localWorkingDirectory: "/tmp")
        let remoteRuntime = SessionRuntimeDescriptor(
            connection: remoteConnection,
            revision: "rev-remote",
            policy: .init(),
            initialWorkingDirectory: nil
        )
        let inlinePaneUUID = UUID()

        let backendSurfaceID = backendSurface.id
        let discoverer: AgentRemoteConversationDiscovery.Discoverer = { request in
            #expect(request.connection.destination == "devbox")
            #expect(request.connection.options == ["-p", "2222"])
            if request.runtimePaneID == inlinePaneUUID {
                return .init(agent: .antigravity, conversationID: conv1, workingDirectory: "/srv/trading")
            }
            if request.runtimePaneID == backendSurfaceID {
                return .init(agent: .antigravity, conversationID: conv2, workingDirectory: "/srv/trading")
            }
            if request.remoteTTY == "/dev/pts/9" {
                return .init(agent: .antigravity, conversationID: conv3, workingDirectory: "/srv/trading")
            }
            return nil
        }
        inlineTab.remoteConversationDiscoverer = discoverer
        backendTab.remoteConversationDiscoverer = discoverer
        plainSSHTab.remoteConversationDiscoverer = discoverer

        // 1. Tab 1: `omg +ssh` inline session WITHOUT initial `workingDirectory` (starts `.sshConnecting`)
        // running idle `agy` before any prompt is sent.
        let inlineSession = SessionRuntimeInlineSession(
            descriptor: remoteRuntime,
            pane: inlinePaneUUID,
            connectionID: "omg-ssh-inline-90a",
            socket: URL(fileURLWithPath: "/tmp/unused-inline-90a.sock"),
            helperPID: ProcessInfo.processInfo.processIdentifier,
            bootID: try #require(SessionRuntimeInlineSession.currentBootID),
            workingDirectory: nil
        )
        inlineSurface.runtimeInlineSession = inlineSession
        inlineSurface.contextSignal = inlineSession.restorationSignal
        inlineSurface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=idle:app=antigravity"
        )

        // 2. Tab 2: Direct `SessionBackend` SSH session WITHOUT initial `pwd` (starts `.sshConnecting`)
        // replaying idle `agy` via `omg-agent-sync` before any prompt.
        backendSurface.runtimeDescriptor = remoteRuntime
        #expect(backendSurface.pwd == nil)
        backendSurface.contextSignal = .init(
            action: .start,
            id: "omg-runtime-state",
            metadata: #"{"state":"ready"}"#
        )
        backendSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin;mode=restore")
        backendSurface.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=idle:app=agy")
        backendSurface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")

        // 3. Tab 3: Plain shell-integrated `/usr/bin/ssh` session (with `remoteTTY` and no initial local OSC 7 pwd).
        plainSSHSurface.pendingSSHLaunchReplay = .init(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: true,
            terminfo: true,
            cache: true,
            args: ["-p", "2222", "devbox"],
            localWorkingDirectory: nil
        )
        plainSSHSurface.contextSignal = .init(
            action: .start,
            id: "omg-ssh-plain-90c",
            metadata: "type=remote;targethost=devbox;cwd=/srv/trading;tty=/dev/pts/9"
        )
        plainSSHSurface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=idle:app=antigravity"
        )

        // 4. Tab 4: Pinned manual titleOverride tab (skipped by batch workspace auto-rename).
        manualTab.titleOverride = "手动固定标题"

        try await waitForAppKit {
            inlineTab.canAutoRenameTab && backendTab.canAutoRenameTab && plainSSHTab.canAutoRenameTab
        }
        #expect(backendSurface.pwd == "/srv/trading")
        #expect(inlineSurface.runtimeInlineSession?.workingDirectory == "/srv/trading")
        #expect(inlineTab.agentResumeDescriptor(for: inlineSurface)?.conversationID == conv1)
        #expect(backendTab.agentResumeDescriptor(for: backendSurface)?.conversationID == conv2)
        #expect(plainSSHTab.agentResumeDescriptor(for: plainSSHSurface)?.conversationID == conv3)
        #expect(AgentHistoryRemoteAccess.liveConnection(for: "devbox")?.options == ["-p", "2222"])

        let strings = ChromeStrings.current
        let inlineMenu = NativeTabContextMenu.make(for: inlineTab, host: inlineTab, style: .inbox)
        let autoRenameItem = try #require(inlineMenu.items.first { $0.title == strings.autoRenameTab })
        #expect(autoRenameItem.isEnabled)

        // Single-tab Auto-Rename on Tab 1 fetches remote Antigravity conversation and renames the tab!
        inlineTab.autoRenameTab(force: true)
        await coordinator.waitUntilIdle()
        let inlinePresentation = try #require(
            TerminalTabPresentationResolver.resolve(inlineTab, index: 0, selected: true, activities: nil, style: .inbox)
        )
        #expect(inlinePresentation.title == "K8s 挂载超时排查")

        // Workspace batch Auto-Rename renames Tabs 1, 2, and 3 from their distinct remote `agy` conversations,
        // while preserving Tab 4's manual override!
        TerminalController.autoRenameWorkspaceTabs([inlineTab, backendTab, plainSSHTab, manualTab])
        await coordinator.waitUntilIdle()
        let backendPresentation = try #require(
            TerminalTabPresentationResolver.resolve(backendTab, index: 1, selected: false, activities: nil, style: .inbox)
        )
        let plainPresentation = try #require(
            TerminalTabPresentationResolver.resolve(plainSSHTab, index: 2, selected: false, activities: nil, style: .inbox)
        )
        #expect(backendPresentation.title == "SSH 历史恢复修复")
        #expect(plainPresentation.title == "风控熔断治理")
        #expect(manualTab.titleOverride == "手动固定标题")

        let calls = await generator.calls
        #expect(calls.contains { $0.prompt.contains("Pod 挂载超时") && $0.projectName == "trading" })
        #expect(calls.contains { $0.prompt.contains("滚动历史丢失") && $0.projectName == "trading" })
    }

    @MainActor
    @Test func inPaneRecreatePreservesBoundRemoteAgyConversationAndLiveHookWinsOverDiscovery() async throws {
        let settings = OhMyGhosttySettings.shared
        let savedHooks = settings.agentStatusHooksEnabled
        settings.agentStatusHooksEnabled = true
        defer { settings.agentStatusHooksEnabled = savedHooks }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)

        let remoteConnection = try GitSSHConnection(destination: "prod-gpu", localWorkingDirectory: "/tmp")
        let remoteRuntime = SessionRuntimeDescriptor(
            connection: remoteConnection,
            revision: "rev-89",
            policy: .init(),
            initialWorkingDirectory: "/srv/ml"
        )
        surface.runtimeDescriptor = remoteRuntime
        surface.pwd = "/srv/ml"
        surface.contextSignal = .init(action: .start, id: "omg-runtime-state", metadata: #"{"state":"ready"}"#)

        let discoveredConv = try #require(AgentConversationID("agy-pre-reboot-89"))
        let liveHookConv = try #require(AgentConversationID("agy-live-hook-90"))
        actor ProbeModeBox {
            var mode = "agy"
            func set(_ next: String) { mode = next }
        }
        let probeMode = ProbeModeBox()
        controller.remoteConversationDiscoverer = { _ in
            let current = await probeMode.mode
            if current == "slow-stale" {
                try? await Task.sleep(for: .milliseconds(350))
                return .init(agent: .antigravity, conversationID: AgentConversationID("agy-stale"), workingDirectory: "/srv/ml")
            }
            if current == "shell-only" {
                return nil
            }
            return .init(agent: .antigravity, conversationID: discoveredConv, workingDirectory: "/srv/ml")
        }

        // 1. Pre-reboot: remote discovery binds `discoveredConv` on idle `agy` before any prompt is sent.
        surface.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=idle:app=antigravity")
        try await waitForAppKit { controller.canAutoRenameTab }
        #expect(controller.agentResumeDescriptor(for: surface)?.conversationID == discoveredConv)

        // 2. Host reboots -> `.sessionGone` -> `#89` `recreateRuntimeSession` sends `resume` with `discoveredConv`
        // AND preserves `discoveredConv` across initial empty + `omg-program-status` runtime hydration!
        surface.contextSignal = .init(
            action: .start,
            id: "omg-runtime-state",
            metadata: #"{"state":"session_gone","message":"unknown session"}"#
        )
        #expect(!controller.canAutoRenameTab)

        let retryer = RetryRecorder()
        controller.recreateRuntimeSession(for: surface, using: retryer)
        #expect(retryer.recreateRequest?.resume?.agent == "antigravity")
        #expect(retryer.recreateRequest?.resume?.conversationID == discoveredConv.rawValue)
        #expect(retryer.recreateRequest?.resume?.cwd == "/srv/ml")

        // Recreated session attaches: initial empty `omg-agent-sync`, then `.ready`, then idle `omg-program-status`.
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin;mode=restore")
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        #expect(controller.agentResumeDescriptor(for: surface)?.conversationID == discoveredConv)

        surface.contextSignal = .init(action: .start, id: "omg-runtime-state", metadata: #"{"state":"ready"}"#)
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin;mode=live")
        surface.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=idle:app=antigravity")
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        #expect(controller.agentResumeDescriptor(for: surface)?.conversationID == discoveredConv)
        #expect(controller.canAutoRenameTab)

        // 3. Container-rebuild recreate fallback: when remote store was wiped and recreate lands in a plain shell,
        // verification clears the stale pre-reboot conversation ID so `canAutoRenameTab` returns to `false`.
        await probeMode.set("shell-only")
        surface.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=clear:app=antigravity")
        controller.adoptAgentResumeDescriptor(
            .init(
                agent: .antigravity,
                conversationID: discoveredConv,
                scope: .remote,
                workingDirectory: "/srv/ml",
                sshReplay: controller.paneSessionContext(for: surface).flatMap {
                    if case .sshReady(let ssh, _) = $0.state { return ssh.replay }
                    return nil
                }
            ),
            for: surface
        )
        surface.contextSignal = .init(
            action: .start,
            id: "omg-runtime-state",
            metadata: #"{"state":"session_gone","message":"container rebuilt"}"#
        )
        controller.recreateRuntimeSession(for: surface, using: retryer)
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        surface.contextSignal = .init(action: .start, id: "omg-runtime-state", metadata: #"{"state":"ready"}"#)
        try await waitForAppKit { controller.agentResumeDescriptor(for: surface) == nil }
        #expect(!controller.canAutoRenameTab)

        // 4. Hook vs discovery race: a live `PreInvocation` hook signal arriving while discovery is in flight
        // ALWAYS wins and is NEVER clobbered when the stale discovery task finishes.
        await probeMode.set("slow-stale")
        surface.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=idle:app=antigravity")
        surface.contextSignal = .init(
            action: .start,
            id: "omg-agent-antigravity-777",
            metadata: "type=app;omg_agent=antigravity;omg_scope=remote;omg_liveness=pgid;omg_state=working;omg_event=prompt;omg_conversation=\(liveHookConv.rawValue)"
        )
        try await Task.sleep(for: .milliseconds(900))
        #expect(controller.agentResumeDescriptor(for: surface)?.conversationID == liveHookConv)
        #expect(controller.canAutoRenameTab)
    }

    @Test func remoteProbePrefersGroupLeaderOverForegroundChildAndMarksAuthoritativeSource() async throws {
        let python = try await LocalPythonInterpreter.resolve()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let convDir = agyDir.appendingPathComponent("conversations", isDirectory: true)
        let presenceDir = agyDir.appendingPathComponent("presence", isDirectory: true)
        for dir in [home, repo, binDir, convDir, presenceDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let convLeader = "aaaaaaaa-1111-4222-8333-aaaaaaaaaaaa"
        let convContinue = "bbbbbbbb-1111-4222-8333-bbbbbbbbbbbb"
        for cid in [convLeader, convContinue] {
            try Data().write(to: convDir.appendingPathComponent("\(cid).db"))
        }
        let canonicalRepoURI = URL(fileURLWithPath: repo.resolvingSymlinksInPath().path).absoluteString
        try execSQL(agyDir.appendingPathComponent("conversation_summaries.db"), """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT,
            preview TEXT,
            workspace_uris TEXT,
            last_modified_time TEXT,
            nesting_depth INTEGER,
            parent_conversation_id TEXT
        );
        INSERT INTO conversation_summaries VALUES
            ('\(convLeader)', '主会话', '主会话摘要', '["\(canonicalRepoURI)"]', '2026-11-20 08:00:00+00:00', 0, ''),
            ('\(convContinue)', '最新会话', '继续会话摘要', '["\(canonicalRepoURI)"]', '2026-11-26 09:00:00+00:00', 0, '');
        """)

        // `agy` TUI leader (`pid == pgid`) holds `presence/<convLeader>.lock` and spawns a newer foreground
        // child `agy mcp` (`pid != pgid`, closing FD 9 so the child holds NO lock).
        let agyExecutable = binDir.appendingPathComponent("agy")
        let stubSource = """
        #!/bin/sh
        if [ "${1:-}" = "mcp" ]; then
            exec 9>&- 2>/dev/null || true
            if [ -n "${AGY_CHILD_READY:-}" ]; then
                printf '%s' "$$" >"${AGY_CHILD_READY}.tmp" && mv -f "${AGY_CHILD_READY}.tmp" "$AGY_CHILD_READY"
            fi
            IFS= read -r _
            exit 0
        fi
        if [ -n "${AGY_LOCK_FILE:-}" ]; then
            mkdir -p "$(dirname "$AGY_LOCK_FILE")"
            exec 9>>"$AGY_LOCK_FILE"
        fi
        if [ -n "${AGY_SPAWN_MCP:-}" ]; then
            "$0" mcp &
        fi
        if [ -n "${AGY_READY_FILE:-}" ]; then
            printf '%s' "$$" >"${AGY_READY_FILE}.tmp" && mv -f "${AGY_READY_FILE}.tmp" "$AGY_READY_FILE"
        fi
        IFS= read -r _
        """
        try Data(stubSource.utf8).write(to: agyExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyExecutable.path)

        let readyLeader = root.appendingPathComponent("leader.ready")
        let readyChild = root.appendingPathComponent("child.ready")
        var envLeader = python.environment
        envLeader["HOME"] = home.path
        envLeader["AGY_LOCK_FILE"] = presenceDir.appendingPathComponent("\(convLeader).lock").path
        envLeader["AGY_READY_FILE"] = readyLeader.path
        envLeader["AGY_CHILD_READY"] = readyChild.path
        envLeader["AGY_SPAWN_MCP"] = "1"

        let ptyLeader = try PTYAgentProcess(
            pythonExecutablePath: python.executablePath,
            executableURL: agyExecutable,
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: repo,
            environment: envLeader
        )
        defer { ptyLeader.stop() }
        _ = try await ptyLeader.waitForReadyFile(readyLeader)
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: readyChild.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: readyChild.path))

        let connection = try GitSSHConnection(destination: "devbox", localWorkingDirectory: "/tmp")
        let leaderResult = try await runProbeLocally(.init(
            agent: .antigravity,
            connection: connection,
            runtimeRevision: nil,
            runtimePaneID: nil,
            remoteTTY: ptyLeader.ttyPath,
            remoteWorkingDirectory: nil,
            launchedAfter: Date(),
            excludedConversationIDs: [],
            homeDirectoryOverride: home.path
        ), python: python)
        #expect(leaderResult?.conversationID?.rawValue == convLeader)
        #expect(leaderResult?.isAuthoritative == true)
        ptyLeader.stop()

        // `-c` workspace summary fallback resolves `convContinue` with `isAuthoritative == false`.
        let readyContinue = root.appendingPathComponent("continue.ready")
        var envContinue = python.environment
        envContinue["HOME"] = home.path
        envContinue["AGY_READY_FILE"] = readyContinue.path
        let ptyContinue = try PTYAgentProcess(
            pythonExecutablePath: python.executablePath,
            executableURL: agyExecutable,
            arguments: ["-c"],
            workingDirectory: repo,
            environment: envContinue
        )
        defer { ptyContinue.stop() }
        _ = try await ptyContinue.waitForReadyFile(readyContinue)

        let continueResult = try await runProbeLocally(.init(
            agent: .antigravity,
            connection: connection,
            runtimeRevision: nil,
            runtimePaneID: nil,
            remoteTTY: ptyContinue.ttyPath,
            remoteWorkingDirectory: repo.path,
            launchedAfter: Date(),
            excludedConversationIDs: [],
            homeDirectoryOverride: home.path
        ), python: python)
        #expect(continueResult?.conversationID?.rawValue == convContinue)
        #expect(continueResult?.isAuthoritative == false)
    }

    @MainActor
    @Test func enterGuardsShellPanesSupportsResumeConversationSwitchFastSSHRaceAndDetachedWorkspaces() async throws {
        let settings = OhMyGhosttySettings.shared
        let savedHooks = settings.agentStatusHooksEnabled
        settings.agentStatusHooksEnabled = true
        defer { settings.agentStatusHooksEnabled = savedHooks }

        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let shellTab = try fixture.tab()
        let resumeSwitchTab = try fixture.tab()
        let fastRaceTab = try fixture.tab()
        let detachedTab = try fixture.tab()

        let shellSurface = try #require(shellTab.surfaceTree.first)
        let switchSurface = try #require(resumeSwitchTab.surfaceTree.first)
        let fastRaceSurface = try #require(fastRaceTab.surfaceTree.first)
        let detachedSurface = try #require(detachedTab.surfaceTree.first)

        // 1. Ordinary SSH shell (`zsh`/`vim` with no active agent): pressing Enter triggers ZERO SSH probes.
        let shellConnection = try GitSSHConnection(destination: "shell-box", localWorkingDirectory: "/tmp")
        shellSurface.runtimeDescriptor = .init(
            connection: shellConnection,
            revision: "rev-shell",
            policy: .init(),
            initialWorkingDirectory: "/home/dev"
        )
        shellSurface.pwd = "/home/dev"
        shellSurface.contextSignal = .init(action: .start, id: "omg-runtime-state", metadata: #"{"state":"ready"}"#)

        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        let shellProbeCounter = Counter()
        shellTab.remoteConversationDiscoverer = { _ in
            await shellProbeCounter.increment()
            return nil
        }
        // Clear any initial `.sshReady` speculative task so we measure `Enter` exclusively.
        shellTab.cancelRemoteConversationDiscovery(for: shellSurface.id)
        shellTab.noteRemoteAgentDiscoveryAfterUserSubmit(on: shellSurface)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await shellProbeCounter.count == 0)
        #expect(shellTab.remoteConversationDiscoveryTasks[shellSurface.id] == nil)

        // 2. `/resume` conversation switch inside an already-bound `agy` session before sending any prompt:
        //    - Non-authoritative timestamp fallback NEVER overwrites `convA`.
        //    - Authoritative `presence/<convB>.lock` result updates `convA` -> `convB` and clears `restoredTitle`.
        //    - An active `.working` typed hook turn blocks `Enter` refresh from clobbering the hook's conversation.
        let convA = try #require(AgentConversationID("agy-switch-conv-a"))
        let convB = try #require(AgentConversationID("agy-switch-conv-b"))
        let convGuess = try #require(AgentConversationID("agy-non-authoritative"))
        let convWorkingHook = try #require(AgentConversationID("agy-working-hook"))

        let switchConn = try GitSSHConnection(destination: "switch-box", localWorkingDirectory: "/tmp")
        switchSurface.runtimeDescriptor = .init(
            connection: switchConn,
            revision: "rev-switch",
            policy: .init(),
            initialWorkingDirectory: "/srv/app"
        )
        switchSurface.pwd = "/srv/app"
        switchSurface.contextSignal = .init(action: .start, id: "omg-runtime-state", metadata: #"{"state":"ready"}"#)
        switchSurface.contextSignal = .init(action: .start, id: "omg-program-status", metadata: "state=idle:app=antigravity")
        resumeSwitchTab.adoptAgentResumeDescriptor(
            .init(
                agent: .antigravity,
                conversationID: convA,
                scope: .remote,
                workingDirectory: "/srv/app"
            ),
            for: switchSurface,
            title: "旧恢复标题"
        )
        #expect(resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.conversationID == convA)
        #expect(resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.restoredTitle == "旧恢复标题")

        actor SwitchProbeState {
            var authoritative = false
            var nextID: AgentConversationID?
            func configure(id: AgentConversationID?, authoritative: Bool) {
                self.nextID = id
                self.authoritative = authoritative
            }
        }
        let switchState = SwitchProbeState()
        await switchState.configure(id: convGuess, authoritative: false)
        resumeSwitchTab.remoteConversationDiscoverer = { _ in
            let id = await switchState.nextID
            let auth = await switchState.authoritative
            return .init(agent: .antigravity, conversationID: id, workingDirectory: "/srv/app", isAuthoritative: auth)
        }

        resumeSwitchTab.noteRemoteAgentDiscoveryAfterUserSubmit(on: switchSurface)
        try await Task.sleep(for: .milliseconds(800))
        #expect(resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.conversationID == convA)
        #expect(resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.restoredTitle == "旧恢复标题")

        await switchState.configure(id: convB, authoritative: true)
        resumeSwitchTab.noteRemoteAgentDiscoveryAfterUserSubmit(on: switchSurface)
        try await waitForAppKit {
            resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.conversationID == convB
        }
        #expect(resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.restoredTitle == nil)

        // Active `.working` hook turn prevents `Enter` from scheduling an overriding probe.
        switchSurface.contextSignal = .init(
            action: .start,
            id: "omg-agent-antigravity-888",
            metadata: "type=app;omg_agent=antigravity;omg_scope=remote;omg_liveness=pgid;omg_state=working;omg_event=prompt;omg_conversation=\(convWorkingHook.rawValue)"
        )
        await switchState.configure(id: convA, authoritative: true)
        resumeSwitchTab.noteRemoteAgentDiscoveryAfterUserSubmit(on: switchSurface)
        try await Task.sleep(for: .milliseconds(800))
        #expect(resumeSwitchTab.agentResumeDescriptor(for: switchSurface)?.conversationID == convWorkingHook)

        // 3. Plain `/usr/bin/ssh` fast-launch race (`ssh -t host 'agy -r <id>'` emitting OSC 7501 BEFORE
        //    the 1s foreground poll transitions `context` from `.local` -> `.sshConnecting`).
        let fastConv = try #require(AgentConversationID("agy-fast-plain-ssh"))
        fastRaceTab.remoteConversationDiscoverer = { request in
            #expect(request.connection.destination == "fast-host")
            #expect(request.connection.options == ["-p", "2202"])
            return .init(agent: .antigravity, conversationID: fastConv, workingDirectory: "/srv/fast", isAuthoritative: true)
        }
        // OSC 7501 arrives while `context.state == .local`.
        fastRaceSurface.contextSignal = .init(
            action: .start,
            id: "omg-program-status",
            metadata: "state=idle:app=antigravity"
        )
        #expect(fastRaceTab.agentProgramStatuses[fastRaceSurface.id]?.isRemote == false)
        #expect(!fastRaceTab.canAutoRenameTab)

        // 1s foreground poll observes `/usr/bin/ssh -p 2202 fast-host` -> `.sshConnecting`.
        let fastReplay = SSHReplayDescriptor(
            version: 1,
            ssh: "/usr/bin/ssh",
            forwardEnv: false,
            terminfo: false,
            cache: false,
            args: ["-p", "2202", "fast-host"],
            localWorkingDirectory: "/tmp"
        )
        fastRaceTab.applyObservedForegroundProcess(
            agent: nil,
            ssh: .interactive(alias: "fast-host", transferTarget: "fast-host"),
            processGroupID: Int(ProcessInfo.processInfo.processIdentifier),
            surfaceID: fastRaceSurface.id,
            sshReplay: fastReplay
        )
        #expect(fastRaceTab.agentProgramStatuses[fastRaceSurface.id]?.isRemote == true)
        try await waitForAppKit { fastRaceTab.canAutoRenameTab }
        #expect(fastRaceTab.agentResumeDescriptor(for: fastRaceSurface)?.conversationID == fastConv)

        // 4. Detached workspace controller (window ordered out / not in `TerminalController.all`):
        //    `AgentHistoryRemoteAccess.liveConnection` resolves exact SSH options from live workspace controllers.
        let detachedConn = try GitSSHConnection(
            destination: "detached-gpu",
            options: ["-p", "2299", "-J", "bastion"],
            localWorkingDirectory: "/tmp"
        )
        detachedSurface.runtimeDescriptor = .init(
            connection: detachedConn,
            revision: "rev-detached",
            policy: .init(),
            initialWorkingDirectory: "/srv/detached"
        )
        detachedSurface.pwd = "/srv/detached"
        detachedSurface.contextSignal = .init(action: .start, id: "omg-runtime-state", metadata: #"{"state":"ready"}"#)
        let resolvedDetached = AgentHistoryRemoteAccess.liveConnection(
            for: "detached-gpu",
            controllersOverride: [detachedTab]
        )
        #expect(resolvedDetached?.options == ["-p", "2299", "-J", "bastion"])
    }
}
