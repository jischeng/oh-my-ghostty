import Foundation
import Testing
@testable import Ghostty

struct GitACPConnectionTests {
    @Test func handshakeStreamingPermissionDenialAndReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock.py")
        try #"""
        import json, sys
        count = 0
        def send(x):
            print(json.dumps(dict(jsonrpc="2.0", **x)), flush=True)
        for line in sys.stdin:
            r = json.loads(line)
            method = r.get("method")
            if method == "initialize": send(dict(id=r["id"],result={"protocolVersion":1}))
            elif method == "session/new": send(dict(id=r["id"],result={"sessionId":"session-one"}))
            elif method == "session/prompt":
                count += 1
                send(dict(id=900,method="session/request_permission",params={"sessionId":"session-one","options":[]}))
                permission=json.loads(sys.stdin.readline())
                assert permission["result"]["outcome"]["outcome"] == "cancelled"
                send(dict(method="session/update",params={"sessionId":"wrong-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"WRONG"}}}))
                send(dict(method="session/update",params={"sessionId":"session-one","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"SECRET"}}}))
                send(dict(method="session/update",params={"sessionId":"session-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fix: turn " + str(count)}}}))
                send(dict(id=r["id"],result={"stopReason":"end_turn"}))
        """#.write(to: script, atomically: true, encoding: .utf8)
        let client = GitACPConnection()
        try await client.start(executable: "/usr/bin/python3", arguments: [script.path], cwd: root,
                               environment: ProcessInfo.processInfo.environment)
        do {
            _ = try await client.request("initialize", params: [:])
            _ = try await client.request("session/new", params: [:])
            #expect(try await client.prompt(session: "session-one", text: "one") == "fix: turn 1")
            #expect(try await client.prompt(session: "session-one", text: "two") == "fix: turn 2")
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }

    @Test func installedAdaptersDiscoverModelsInIsolatedHomes() async throws {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".pi/acp-live-discovery.enabled")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        for agent in GitCommitAgent.allCases {
            let models = try await GitACPService.shared.models(agent: agent)
            #expect(!models.isEmpty, "\(agent.title) must expose its model catalog")
            print("ACP isolated discovery: \(agent.title), \(models.count) models")
        }
    }

    @Test func nonResponsiveAdapterTimesOut() async throws {
        let client = GitACPConnection()
        try await client.start(executable: "/usr/bin/python3", arguments: ["-c", "import time; time.sleep(30)"],
            cwd: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment)
        await #expect(throws: (any Error).self) {
            try await client.request("initialize", params: [:], timeout: 0.05)
        }
        await client.stop()
    }

    @Test func generateTitleSerializesConcurrentTurnsOnWarmSessionAndStripsThinkBlocks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock_title_acp.py")
        try #"""
        import json, sys, time
        turn = 0
        def send(x):
            print(json.dumps(dict(jsonrpc="2.0", **x)), flush=True)
        for line in sys.stdin:
            r = json.loads(line)
            method = r.get("method")
            if method == "initialize":
                send(dict(id=r["id"], result={"protocolVersion": 1}))
            elif method == "session/new":
                send(dict(id=r["id"], result={
                    "sessionId": "title-session",
                    "models": {"availableModels": [{"modelId": "gpt-5-codex"}]}
                }))
            elif method == "session/set_model":
                send(dict(id=r["id"], result={}))
            elif method == "session/prompt":
                turn += 1
                time.sleep(0.03)
                text = json.dumps(r.get("params", {}))
                if "EMPTY_THINK" in text:
                    reply = "<think>only internal reasoning</think>"
                else:
                    reply = f"<think>pondering</think> \"精简会话 {turn}…\""
                send(dict(method="session/update", params={
                    "sessionId": "title-session",
                    "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}}
                }))
                send(dict(id=r["id"], result={"stopReason": "end_turn"}))
        """#.write(to: script, atomically: true, encoding: .utf8)

        actor SpawnCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let spawns = SpawnCounter()
        let service = GitACPService(
            store: GitACPSessionStore(root: root.appendingPathComponent("Sessions")),
            launcher: { _, cwd, connection in
                await spawns.increment()
                try await connection.start(
                    executable: "/usr/bin/python3",
                    arguments: [script.path],
                    cwd: cwd,
                    environment: ProcessInfo.processInfo.environment
                )
            }
        )
        defer { Task { await service.shutdown() } }

        // Two concurrent title calls on the same (agent, model) serialize cleanly on ONE warm session
        // instead of failing with "This ACP session is busy" or spawning two adapter processes.
        async let first = service.generateTitle(
            agent: .codex, model: "gpt-5-codex", system: "System", user: "<first_prompt>one</first_prompt>"
        )
        async let second = service.generateTitle(
            agent: .codex, model: "gpt-5-codex", system: "System", user: "<first_prompt>two</first_prompt>"
        )
        let titles = try await [first, second].compactMap { $0 }.sorted()
        #expect(titles == ["精简会话 1", "精简会话 2"])
        #expect(await spawns.count == 1)

        await #expect(throws: AIHTTPError.emptyOutput) {
            _ = try await service.generateTitle(
                agent: .codex, model: "gpt-5-codex", system: "System", user: "EMPTY_THINK"
            )
        }
        await service.shutdown()
    }

    @Test func concurrentGitAndTitleCallsExceedingPoolSizeQueueCleanlyAndCancelledKeyWaitersNeverDeadlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-acp-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock_pool_acp.py")
        try #"""
        import json, sys, time
        def send(x):
            print(json.dumps(dict(jsonrpc="2.0", **x)), flush=True)
        for line in sys.stdin:
            r = json.loads(line)
            method = r.get("method")
            if method == "initialize":
                send(dict(id=r["id"], result={"protocolVersion": 1}))
            elif method == "session/new":
                send(dict(id=r["id"], result={
                    "sessionId": "pooled-session",
                    "models": {"availableModels": [
                        {"modelId": "m-1"}, {"modelId": "m-2"}, {"modelId": "m-3"}, {"modelId": "m-4"}
                    ]}
                }))
            elif method == "session/set_model":
                send(dict(id=r["id"], result={}))
            elif method == "session/prompt":
                text = json.dumps(r.get("params", {}))
                time.sleep(0.12 if "SLOW_TURN" in text else 0.04)
                send(dict(method="session/update", params={
                    "sessionId": "pooled-session",
                    "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "OK Title"}}
                }))
                send(dict(id=r["id"], result={"stopReason": "end_turn"}))
        """#.write(to: script, atomically: true, encoding: .utf8)

        let service = GitACPService(
            store: GitACPSessionStore(root: root.appendingPathComponent("Sessions")),
            maxSessions: 2,
            launcher: { _, cwd, connection in
                try await connection.start(
                    executable: "/usr/bin/python3",
                    arguments: [script.path],
                    cwd: cwd,
                    environment: ProcessInfo.processInfo.environment
                )
            }
        )
        defer { Task { await service.shutdown() } }

        // 1. Four simultaneous distinct session keys (2 Git repos + 2 distinct title models) against
        //    `maxSessions == 2` must queue cleanly instead of throwing "This ACP session is busy".
        let repoA = GitRepositoryIdentity(worktreePath: "/repoA", gitDirPath: "/repoA/.git", commonGitDirPath: "/repoA/.git")
        let repoB = GitRepositoryIdentity(worktreePath: "/repoB", gitDirPath: "/repoB/.git", commonGitDirPath: "/repoB/.git")
        async let commitA = service.generate(
            repository: repoA, route: GitCommitAIRoute(agent: .codex, model: "m-1"), style: "", prompt: "diff A"
        )
        async let commitB = service.generate(
            repository: repoB, route: GitCommitAIRoute(agent: .claude, model: "m-2"), style: "", prompt: "diff B"
        )
        async let titleC = service.generateTitle(
            agent: .pi, model: "m-3", system: "System", user: "<first_prompt>three</first_prompt>"
        )
        async let titleD = service.generateTitle(
            agent: .opencode, model: "m-4", system: "System", user: "<first_prompt>four</first_prompt>"
        )
        let results = try await [commitA, commitB, titleC ?? "", titleD ?? ""]
        #expect(results == ["OK Title", "OK Title", "OK Title", "OK Title"])

        // 2. Cancelling a second `generateTitle` while parked in `keyWaiters` must not wedge a 3rd waiter.
        let holder = Task {
            try await service.generateTitle(
                agent: .codex, model: "m-1", system: "System", user: "SLOW_TURN"
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let cancelledWaiter = Task {
            try await service.generateTitle(
                agent: .codex, model: "m-1", system: "System", user: "cancelled"
            )
        }
        let survivingWaiter = Task {
            try await service.generateTitle(
                agent: .codex, model: "m-1", system: "System", user: "survivor"
            )
        }
        try await Task.sleep(for: .milliseconds(15))
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledWaiter.value
        }
        #expect(try await holder.value == "OK Title")
        #expect(try await survivingWaiter.value == "OK Title")
        await service.shutdown()
    }
}
