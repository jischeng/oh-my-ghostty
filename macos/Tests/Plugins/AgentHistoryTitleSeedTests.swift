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

    /// Marks a transcript as last written long before any lookup window.
    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path
        )
    }

    private func makeDatabase(_ url: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func codexItem(_ role: String, _ text: String) throws -> String {
        try json(["type": "response_item", "payload": [
            "type": "message", "role": role,
            "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]],
        ]])
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
        #expect(await seed()?.isUserRenamed == true)
        #expect(await seed()?.firstPrompt?.hasPrefix("Fix the flaky login test") == true)

        // Clearing the name gives the generated title back.
        lines.append(try name("custom-title", "customTitle", ""))
        try write(lines, to: file)
        #expect(await seed()?.native == "Generated later")
        #expect(await seed()?.isUserRenamed == false)

        // The History list keeps naming the session after its opening prompt.
        let sessions = await AgentHistoryStore.load(
            agents: [.claude], rootURLs: [.claude: root], cacheURL: root.appendingPathComponent("cache.json")
        )
        let session = try #require(sessions.first)
        #expect(session.title == "Fix the flaky login test It fails about once in ten runs.")
        #expect(session.nativeTitle == "Generated later")
    }

    /// The first build looked only at transcripts written in the last quarter
    /// of an hour, so a restored tab never found its conversation.
    @Test func aConversationIsFoundByItsNameWhateverItsAge() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        let conversation = try #require(AgentConversationID(id))
        let file = root.appendingPathComponent("-repo/\(id).jsonl")
        try write([
            try json(["type": "user", "sessionId": id, "cwd": "/repo",
                      "message": ["role": "user", "content": "Fix the build"]]),
            try json(["type": "ai-title", "aiTitle": "Build fix", "sessionId": id]),
        ], to: file)
        // Another conversation in use right now must not stand in for it.
        try write([
            try json(["type": "user", "sessionId": "another-conversation", "cwd": "/repo",
                      "message": ["role": "user", "content": "Something else"]]),
        ], to: root.appendingPathComponent("-repo/another-conversation.jsonl"))
        try age(file, days: 25)

        // The default window, as the app asks.
        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: conversation, rootURLs: [.claude: root]
        ) == Seed(native: "Build fix", firstPrompt: "Fix the build"))
        // The window does not apply to a transcript named after the conversation.
        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: conversation,
            updatedAfter: Date().addingTimeInterval(3_600), rootURLs: [.claude: root]
        )?.native == "Build fix")
        let match = AgentHistoryStore.conversationSession(
            agent: .claude, conversationID: conversation, rootURLs: [.claude: root], recentAfter: Date()
        )
        #expect(match.lookup == .named)
        #expect(match.session?.sourcePath.hasSuffix("\(id).jsonl") == true)

        // A conversation without a transcript has no seed, and says why.
        let other = try #require(AgentConversationID("no-such-conversation"))
        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: other, rootURLs: [.claude: root]
        ) == nil)
        #expect(AgentHistoryStore.conversationSession(
            agent: .claude, conversationID: other, rootURLs: [.claude: root],
            recentAfter: Date().addingTimeInterval(-900)
        ).lookup == .missing)
        // An Agent whose sessions this build cannot read is told apart from that.
        #expect(AgentHistoryStore.conversationSession(
            agent: .amp, conversationID: conversation, recentAfter: Date()
        ).lookup == .unsupported)
    }

    @Test func anOldCodexRolloutIsFoundAndNamedFromTheThreadIndex() async throws {
        let home = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("sessions")
        let id = "01a1c984-896e-7ea3-b6d6-6d3514eea6fc"
        let conversation = try #require(AgentConversationID(id))
        let rollout = root.appendingPathComponent("2026/07/29/rollout-2026-07-29T10-51-39-\(id).jsonl")
        try write([
            try json(["type": "session_meta", "payload": ["id": id, "cwd": "/repo"]]),
            try codexItem("developer", "You are Codex"),
            try codexItem("user", "Cut a release"),
            try codexItem("assistant", "Done."),
        ], to: rollout)
        try age(rollout, days: 118)
        // A rollout written a moment ago that is not named after the
        // conversation is not read once one that is exists.
        try write([
            try json(["type": "session_meta", "payload": ["id": id, "cwd": "/repo"]]),
            try codexItem("user", "A stray copy"),
        ], to: root.appendingPathComponent("2026/11/24/rollout-stray.jsonl"))
        func seed() async -> Seed? {
            await AgentHistoryStore.titleSeed(agent: .codex, conversationID: conversation, rootURLs: [.codex: root])
        }

        // Codex does not name a conversation inside its rollout.
        #expect(await seed() == Seed(native: nil, firstPrompt: "Cut a release"))

        // It keeps thread names in an index beside the sessions; the last line wins.
        let index = home.appendingPathComponent("session_index.jsonl")
        try write([
            try json(["id": id, "thread_name": "Release", "updated_at": "2026-07-29T10:52:00Z"]),
            try json(["id": "01a1a5e5-81c5-7ac0-9485-c231082388ab", "thread_name": "Another thread",
                      "updated_at": "2026-07-30T10:52:00Z"]),
            try json(["id": id, "thread_name": "Release 1.2.3", "updated_at": "2026-07-31T10:52:00Z"]),
        ], to: index)
        #expect(await seed() == Seed(native: "Release 1.2.3", firstPrompt: "Cut a release"))
        #expect(AgentHistoryStore.codexThreadName(conversationID: conversation, index: index) == "Release 1.2.3")
        let unnamed = try #require(AgentConversationID("01a1a5e5-0000-7ac0-9485-c231082388ab"))
        #expect(AgentHistoryStore.codexThreadName(conversationID: unnamed, index: index) == nil)

        // A thread named after its opening prompt has not been named.
        try write([try json(["id": id, "thread_name": "Cut a release", "updated_at": "x"])], to: index)
        #expect(await seed() == Seed(native: nil, firstPrompt: "Cut a release"))
    }

    @Test func aTranscriptNotNamedAfterItsConversationIsFoundWhileInUse() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "01a1c984-896e-7ea3-b6d6-6d3514eea6fc"
        let conversation = try #require(AgentConversationID(id))
        let rollout = root.appendingPathComponent("2026/11/24/rollout-unnamed.jsonl")
        try write([
            try json(["type": "session_meta", "payload": ["id": id, "cwd": "/repo"]]),
            try codexItem("user", "Cut a release"),
        ], to: rollout)
        func match(after cutoff: Date) -> AgentHistoryStore.ConversationMatch {
            AgentHistoryStore.conversationSession(
                agent: .codex, conversationID: conversation, rootURLs: [.codex: root], recentAfter: cutoff
            )
        }
        // No file name to go by: the recently written transcripts are read.
        let recent = match(after: Date().addingTimeInterval(-900))
        #expect(recent.lookup == .recent)
        #expect(recent.session?.firstPrompt == "Cut a release")
        // Outside the window nothing is parsed, so an idle store costs a listing.
        try age(rollout, days: 2)
        #expect(match(after: Date().addingTimeInterval(-900)).session == nil)
        #expect(match(after: Date().addingTimeInterval(-900)).lookup == .missing)
    }

    @Test func lookupLeavesTheSharedCacheAlone() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        let conversation = try #require(AgentConversationID(id))
        try write([
            try json(["type": "user", "sessionId": id, "cwd": "/repo",
                      "message": ["role": "user", "content": "Fix the build"]]),
            try json(["type": "ai-title", "aiTitle": "Build fix", "sessionId": id]),
        ], to: root.appendingPathComponent("-repo/\(id).jsonl"))

        let cache = root.appendingPathComponent("cache.json")
        #expect(await AgentHistoryStore.titleSeed(
            agent: .claude, conversationID: conversation, rootURLs: [.claude: root]
        )?.native == "Build fix")
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
        // A session is asked for by its key, so its age does not matter: this
        // one was last updated before the cutoff, and before the default one.
        #expect(await seed(after: Date(timeIntervalSince1970: 1_800_000_000))
            == Seed(native: nil, firstPrompt: "Explain the planner"))
        #expect(await AgentHistoryStore.titleSeed(
            agent: .opencode, conversationID: conversation, rootURLs: [.opencode: database]
        )?.firstPrompt == "Explain the planner")

        execute("UPDATE session SET title = 'Planner walkthrough' WHERE id = 'ses_main'")
        #expect(await seed()?.native == "Planner walkthrough")

        // The pane shows this session, so archiving it does not hide its name.
        execute("UPDATE session SET time_archived = 1791103500000 WHERE id = 'ses_main'")
        #expect(await seed()?.native == "Planner walkthrough")
        let other = try #require(AgentConversationID("ses_other"))
        #expect(await AgentHistoryStore.titleSeed(
            agent: .opencode, conversationID: other, rootURLs: [.opencode: database]
        ) == nil)
    }

    @Test func anOldHermesSessionIsFoundByItsKey() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.db")
        // Last active in 2026-10: weeks before any lookup window.
        try makeDatabase(database, """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, started_at REAL, ended_at REAL,
            last_activity_at REAL, message_count INTEGER, hidden INTEGER);
        CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT,
            timestamp REAL, _compressed_summary INTEGER);
        INSERT INTO sessions VALUES ('local-abc', NULL, '/repo', 1792652536, NULL, 1792652540, 2, 0);
        INSERT INTO sessions VALUES ('local-named', 'Greeting', '/repo', 1792650853, NULL, 1792650860, 1, 0);
        INSERT INTO messages (session_id, role, content, timestamp, _compressed_summary) VALUES
            ('local-abc', 'user', 'say hi in one word', 1792652536, 0),
            ('local-abc', 'assistant', 'Hi', 1792652538, 0),
            ('local-named', 'user', 'say hello', 1792650853, 0);
        """)
        func seed(_ id: String) async throws -> Seed? {
            let conversation = try #require(AgentConversationID(id))
            return await AgentHistoryStore.titleSeed(
                agent: .hermes, conversationID: conversation, rootURLs: [.hermes: database]
            )
        }
        #expect(try await seed("local-abc") == Seed(native: nil, firstPrompt: "say hi in one word"))
        #expect(try await seed("local-named") == Seed(native: "Greeting", firstPrompt: "say hello"))
        #expect(try await seed("local-missing") == nil)
    }

    @Test func anOldAntigravityConversationIsFoundByItsKey() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try Data().write(to: conversations.appendingPathComponent("agy-main.db"))
        try Data().write(to: conversations.appendingPathComponent("agy-other.db"))
        try makeDatabase(root.appendingPathComponent("conversation_summaries.db"), """
        CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, preview TEXT, workspace_uris TEXT,
            last_modified_time TEXT, nesting_depth INTEGER, parent_conversation_id TEXT);
        INSERT INTO conversation_summaries VALUES
            ('agy-main', 'Issue triage', 'Close the stale issues', '["file:///repo"]', '2026-09-20 09:24:18+00:00', 0, ''),
            ('agy-other', 'Newer work', 'Do something else', '["file:///repo"]', '2026-11-20 09:25:00+00:00', 0, '');
        """)
        let conversation = try #require(AgentConversationID("agy-main"))
        #expect(await AgentHistoryStore.titleSeed(
            agent: .antigravity, conversationID: conversation, rootURLs: [.antigravity: conversations]
        ) == Seed(native: "Issue triage", firstPrompt: "Close the stale issues"))
        let missing = try #require(AgentConversationID("agy-missing"))
        #expect(await AgentHistoryStore.titleSeed(
            agent: .antigravity, conversationID: missing, rootURLs: [.antigravity: conversations]
        ) == nil)
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
        // The host is told which conversation to look for, falls back to the
        // modification time, and sends Claude Code's title records.
        #expect(command.contains("\(String(cutoff.timeIntervalSince1970)) '\(id)' <<'OMG_HISTORY_PY'"))
        #expect(command.contains("conversation = sys.argv[4]"))
        #expect(command.contains("'ai-title', 'custom-title'"))
    }

    /// Runs the host's script here, against a home folder made for the test.
    @Test func theHostReadsATranscriptNamedAfterTheConversationAndNoOther() async throws {
        let home = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "01a1c984-896e-7ea3-b6d6-6d3514eea6fc"
        let conversation = try #require(AgentConversationID(id))
        let sessions = home.appendingPathComponent(".codex/sessions")
        let rollout = sessions.appendingPathComponent("2026/07/29/rollout-2026-07-29T10-51-39-\(id).jsonl")
        try write([
            try json(["type": "session_meta", "payload": ["id": id, "cwd": "/repo"]]),
            try codexItem("user", "Cut a release"),
        ], to: rollout)
        try age(rollout, days: 118)
        let other = "01a1a5e5-81c5-7ac0-9485-c231082388ab"
        let busy = sessions.appendingPathComponent("2026/11/24/rollout-2026-11-24T09-00-00-\(other).jsonl")
        try write([
            try json(["type": "session_meta", "payload": ["id": other, "cwd": "/repo"]]),
            try codexItem("user", "Something else"),
        ], to: busy)
        try write([
            try json(["id": id, "thread_name": "Release", "updated_at": "2026-07-29T10:52:00Z"]),
            try json(["id": id, "thread_name": "Release 1.2.3", "updated_at": "2026-07-31T10:52:00Z"]),
        ], to: home.appendingPathComponent(".codex/session_index.jsonl"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let homeLiteral = try #require(String(data: encoder.encode(home.path), encoding: .utf8))
        let access = AgentHistoryRemoteAccess(alias: "fixture") { command in
            let script = command.replacingOccurrences(of: "os.path.expanduser('~')", with: homeLiteral)
            let result = try await GitProcessRunner().run(
                executablePath: "/bin/sh", arguments: ["-c", script],
                workingDirectory: home.path, maxOutputBytes: 100_000, timeout: 10
            )
            guard result.isSuccess, let text = String(data: result.stdout, encoding: .utf8) else {
                throw AgentHistoryRemoteError.unavailable
            }
            return text
        }
        func names(_ conversationID: AgentConversationID?) async throws -> [String] {
            try await access.discoverSessions(
                relativeRoots: [".codex/sessions"], maximumSessions: 64,
                updatedAfter: Date().addingTimeInterval(-900), conversationID: conversationID
            ).map { URL(fileURLWithPath: $0.file.path).lastPathComponent }
        }
        // Months old, and the only file read; the one in use is left alone.
        #expect(try await names(conversation) == [rollout.lastPathComponent])
        // No file is named after this one: the recently written ones are read.
        let unnamed = try #require(AgentConversationID("01a1a5e5-0000-7ac0-9485-c231082388ab"))
        #expect(try await names(unnamed) == [busy.lastPathComponent])
        // Without a conversation the cutoff applies as before.
        #expect(try await names(nil) == [busy.lastPathComponent])

        // The thread's name comes back in the same round trip.
        #expect(await AgentHistoryStore.titleSeed(
            agent: .codex, conversationID: conversation, remoteHost: "fixture", remoteAccess: access
        ) == Seed(native: "Release 1.2.3", firstPrompt: "Cut a release"))
    }

    @Test func anOldRemoteConversationIsKeptAndAnUnreachableHostHasNone() async throws {
        let id = "01a1c984-896e-7ea3-b6d6-6d3514eea6fc"
        let conversation = try #require(AgentConversationID(id))
        // What the host returns for a rollout named after the conversation:
        // last written long before the cutoff, with the thread's name appended.
        let object: [String: Any] = [
            "path": "/home/test/.codex/sessions/2026/07/29/rollout-2026-07-29T10-51-39-\(id).jsonl",
            "size": 4_096, "modified": 1_600_000_000.0,
            "records": [
                ["type": "session_meta", "payload": ["id": id, "cwd": "/home/test/proj"]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Cut a release"]],
                ]],
                ["type": "title", "title": "Release 1.2.3"],
            ],
        ]
        let batch = try json(object)
        let access = AgentHistoryRemoteAccess(alias: "cloud") { _ in batch }
        #expect(await AgentHistoryStore.titleSeed(
            agent: .codex, conversationID: conversation, remoteHost: "cloud", remoteAccess: access
        ) == Seed(native: "Release 1.2.3", firstPrompt: "Cut a release"))
        // The History list still applies its cutoff to what a host sends back.
        #expect(await AgentHistoryStore.loadRemote(
            access: access, agents: [.codex], updatedAfter: Date(timeIntervalSince1970: 1_700_000_000)
        ).isEmpty)

        let unreachable = AgentHistoryRemoteAccess(alias: "cloud") { _ in throw AgentHistoryRemoteError.unavailable }
        #expect(await AgentHistoryStore.titleSeed(
            agent: .codex, conversationID: conversation, remoteHost: "cloud", remoteAccess: unreachable
        ) == nil)
        // An Agent with no session files on a host costs no round trip.
        let never = AgentHistoryRemoteAccess(alias: "cloud") { _ in
            Issue.record("no command is sent for an Agent without a remote store")
            return ""
        }
        #expect(await AgentHistoryStore.titleSeed(
            agent: .opencode, conversationID: conversation, remoteHost: "cloud", remoteAccess: never
        ) == nil)
    }

    @Test func resumedTranscriptDiscoveryExcludesConversationsClaimedByAnotherLivePane() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = Date()
        let claimedID = try #require(AgentConversationID("019f-claimed"))
        let resumedID = try #require(AgentConversationID("019f-resumed"))

        let claimedURL = root.appendingPathComponent("2026/11/20/rollout-claimed.jsonl")
        let resumedURL = root.appendingPathComponent("2026/11/20/rollout-resumed.jsonl")
        try write([try json(["type": "session_meta", "payload": ["id": claimedID.rawValue, "cwd": "/tmp/repo"]])],
                  to: claimedURL)
        try write([try json(["type": "session_meta", "payload": ["id": resumedID.rawValue, "cwd": "/tmp/repo"]])],
                  to: resumedURL)
        let yesterday = launch.addingTimeInterval(-86_400)
        try FileManager.default.setAttributes(
            [.creationDate: yesterday, .modificationDate: launch.addingTimeInterval(2)],
            ofItemAtPath: claimedURL.path
        )
        try FileManager.default.setAttributes(
            [.creationDate: yesterday, .modificationDate: launch.addingTimeInterval(1)],
            ofItemAtPath: resumedURL.path
        )

        // Without exclusion, two resumed transcripts modified within 2s are ambiguous.
        #expect(AgentConversationStore.discover(
            agent: .codex, workingDirectory: "/tmp/repo", launchedAfter: launch, rootURL: root
        ) == nil)

        // Excluding the sibling pane's claimed ID isolates the newly resumed session.
        #expect(AgentConversationStore.discover(
            agent: .codex, workingDirectory: "/tmp/repo", launchedAfter: launch,
            excluding: [claimedID], rootURL: root
        ) == resumedID)

        // If only the sibling pane's claimed transcript was touched, nothing is stolen.
        try FileManager.default.setAttributes(
            [.creationDate: yesterday, .modificationDate: yesterday],
            ofItemAtPath: resumedURL.path
        )
        #expect(AgentConversationStore.discover(
            agent: .codex, workingDirectory: "/tmp/repo", launchedAfter: launch,
            excluding: [claimedID], rootURL: root
        ) == nil)
    }
}
