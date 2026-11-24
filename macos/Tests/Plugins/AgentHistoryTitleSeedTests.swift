import Foundation
import SQLite3
import Testing
@testable import Ghostty

/// What a session store calls a conversation, and whether the Agent said so.
struct AgentHistoryTitleSeedTests {
    typealias Seed = AgentHistoryStore.TitleSeed

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("omg-title-seed-\(UUID().uuidString)")
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func json(_ object: [String: Any]) throws -> String {
        try #require(String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private final class Commands: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func append(_ command: String) {
            lock.lock()
            recorded.append(command)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    @Test func claudeTitlesKeepTheirProvenance() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        let conversation = try #require(AgentConversationID(id))
        let file = root.appendingPathComponent("-repo/\(id).jsonl")
        func turn(_ type: String, _ content: String) throws -> String {
            try json(["type": type, "sessionId": id, "cwd": "/repo", "message": ["role": type, "content": content]])
        }
        func name(_ type: String, _ key: String, _ value: String) throws -> String {
            try json(["type": type, key: value, "sessionId": id])
        }
        func seed() async -> AgentHistoryStore.TitleSeed? {
            await AgentHistoryStore.titleSeed(agent: .claude, conversationID: conversation, rootURLs: [.claude: root])
        }
        var lines = [
            try turn("user", "Fix the flaky login test\nIt fails about once in ten runs."),
            try turn("assistant", "Looking at the retries."),
        ]

        // Until the Agent names the conversation there is only its opening prompt.
        try write(lines, to: file)
        #expect(await seed() == Seed(native: nil, firstPrompt: "Fix the flaky login test\nIt fails about once in ten runs."))

        // Claude Code's own title; the last record wins.
        lines += [
            try name("ai-title", "aiTitle", "Login test"),
            try name("ai-title", "aiTitle", "Stabilise the login test"),
        ]
        try write(lines, to: file)
        #expect(await seed()?.native == "Stabilise the login test")

        // The user's /rename wins even when a generated title follows it.
        lines += [
            try name("custom-title", "customTitle", "Login flake"),
            try name("ai-title", "aiTitle", "Generated later"),
        ]
        try write(lines, to: file)
        #expect(await seed()?.native == "Login flake")
        #expect(await seed()?.firstPrompt?.hasPrefix("Fix the flaky login test") == true)

        // Clearing the name gives the generated title back.
        lines.append(try name("custom-title", "customTitle", ""))
        try write(lines, to: file)
        #expect(await seed()?.native == "Generated later")

        // The History list keeps naming the session after its opening prompt.
        let sessions = await AgentHistoryStore.load(
            agents: [.claude], rootURLs: [.claude: root], cacheURL: root.appendingPathComponent("cache.json")
        )
        let session = try #require(sessions.first)
        #expect(session.title == "Fix the flaky login test It fails about once in ten runs.")
        #expect(session.nativeTitle == "Generated later")
    }

    @Test func lookupIsBoundedByTheCutoffAndLeavesTheSharedCacheAlone() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        let conversation = try #require(AgentConversationID(id))
        try write([
            try json(["type": "user", "sessionId": id, "cwd": "/repo",
                      "message": ["role": "user", "content": "Fix the build"]]),
            try json(["type": "ai-title", "aiTitle": "Build fix", "sessionId": id]),
        ], to: root.appendingPathComponent("-repo/\(id).jsonl"))

        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: conversation, rootURLs: [.claude: root]
        )?.native == "Build fix")
        // A transcript last written before the cutoff is never parsed.
        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: conversation,
            updatedAfter: Date().addingTimeInterval(3_600), rootURLs: [.claude: root]
        ) == nil)
        let other = try #require(AgentConversationID("another-conversation"))
        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: other, rootURLs: [.claude: root]
        ) == nil)

        let cache = root.appendingPathComponent("cache.json")
        let bounded = await AgentHistoryStore.load(
            agents: [.claude], rootURLs: [.claude: root], cacheURL: cache,
            updatedAfter: Date(timeIntervalSince1970: 0), usesDiskCache: false
        )
        #expect(bounded.map(\.nativeTitle) == ["Build fix"])
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        _ = await AgentHistoryStore.load(agents: [.claude], rootURLs: [.claude: root], cacheURL: cache)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func aStoreTitleRecordIsTheAgentsName() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "01a16769-eed7-7463-8124-2e63b0fdbc04"
        try write([
            #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-10-23T06:19:18.104Z","cwd":"/repo"}"#,
            #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Ship the release"}]}}"#,
            #"{"type":"session_info","title":"Release 1.2.3"}"#,
        ], to: root.appendingPathComponent("--repo--/2026-10-23T06-19-18-104Z_\(id).jsonl"))
        let conversation = try #require(AgentConversationID(id))
        let seed = await AgentHistoryStore.titleSeed(agent: .pi, conversationID: conversation, rootURLs: [.pi: root])
        #expect(seed == Seed(native: "Release 1.2.3", firstPrompt: "Ship the release"))
    }

    @Test func aNameThatRepeatsTheOpeningPromptIsNotAName() throws {
        let id = try #require(AgentConversationID("conversation"))
        func session(native: String?, prompt: String?) -> AgentHistorySession {
            .init(agent: .hermes, conversationID: id, title: "title", workingDirectory: nil,
                  updatedAt: Date(), sourcePath: "/tmp/state.db", isActive: false, previewSnippet: nil,
                  nativeTitle: native, firstPrompt: prompt)
        }
        #expect(AgentHistoryStore.titleSeed(from: session(native: "Fix   the build", prompt: " Fix the\nbuild "))
            == Seed(native: nil, firstPrompt: "Fix the\nbuild"))
        #expect(AgentHistoryStore.titleSeed(from: session(native: "Build fix", prompt: "Fix the build"))
            == Seed(native: "Build fix", firstPrompt: "Fix the build"))
        #expect(AgentHistoryStore.titleSeed(from: session(native: "  ", prompt: "  "))
            == Seed(native: nil, firstPrompt: nil))
        #expect(AgentHistoryStore.titleSeed(from: session(native: "Build fix", prompt: nil))
            == Seed(native: "Build fix", firstPrompt: nil))
    }

    @Test func openCodePlaceholderTitleIsNotTheAgentsName() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("opencode.db")
        func execute(_ sql: String) {
            var handle: OpaquePointer?
            #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        execute("""
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
            time_updated INTEGER, time_archived INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session VALUES ('ses_main', NULL, '/repo', 'New session - 2026-09-21T06:05:40.251Z', 1791103411954, NULL);
        INSERT INTO message VALUES ('m1', 'ses_main', 1, '{"role":"user"}');
        INSERT INTO part VALUES ('p1', 'm1', 'ses_main', 1, '{"type":"text","text":"Explain the planner"}');
        """)
        let conversation = try #require(AgentConversationID("ses_main"))
        func seed(after cutoff: Date = Date(timeIntervalSince1970: 0)) async -> AgentHistoryStore.TitleSeed? {
            await AgentHistoryStore.titleSeed(
                agent: .opencode, conversationID: conversation, updatedAfter: cutoff, rootURLs: [.opencode: database]
            )
        }
        #expect(await seed() == Seed(native: nil, firstPrompt: "Explain the planner"))
        // The cutoff reaches the database query as well.
        #expect(await seed(after: Date(timeIntervalSince1970: 1_800_000_000)) == nil)

        execute("UPDATE session SET title = 'Planner walkthrough' WHERE id = 'ses_main'")
        #expect(await seed()?.native == "Planner walkthrough")
    }

    @Test func aRemoteConversationCostsOneRoundTrip() async throws {
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        let conversation = try #require(AgentConversationID(id))
        let object: [String: Any] = [
            "path": "/home/test/.claude/projects/-home-test-proj/\(id).jsonl", "size": 2_048,
            "modified": Date().timeIntervalSince1970,
            "records": [
                ["type": "user", "sessionId": id, "cwd": "/home/test/proj",
                 "message": ["role": "user", "content": "Deploy the fix"]],
                ["type": "ai-title", "aiTitle": "Deploy fix", "sessionId": id],
            ],
        ]
        let batch = try json(object)
        let commands = Commands()
        let access = AgentHistoryRemoteAccess(alias: "cloud") { command in
            commands.append(command)
            return command.contains("OMG_HISTORY_PY") ? batch : ""
        }
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: conversation, remoteHost: "cloud",
            updatedAfter: cutoff, remoteAccess: access
        )
        #expect(seed == Seed(native: "Deploy fix", firstPrompt: "Deploy the fix"))
        #expect(commands.all.count == 1)
        let command = try #require(commands.all.first)
        // The host filters by modification time and sends Claude Code's title records.
        #expect(command.contains(String(cutoff.timeIntervalSince1970)))
        #expect(command.contains("'ai-title', 'custom-title'"))
    }
}
