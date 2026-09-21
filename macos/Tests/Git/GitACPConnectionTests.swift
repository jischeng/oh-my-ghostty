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
}
