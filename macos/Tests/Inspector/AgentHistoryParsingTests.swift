import AppKit
import Foundation
import SQLite3
import Testing
@testable import Ghostty

/// What a transcript keeps, per Agent family: the conversation's own turns
/// and nothing the Agent recorded around them.
struct AgentHistoryParsingTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("omg-history-\(UUID().uuidString)")
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func json(_ object: [String: Any]) throws -> String {
        try #require(String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private func load(_ agent: SupportedAgent, root: URL, cache: URL) async -> [AgentHistorySession] {
        await AgentHistoryStore.load(agents: [agent], rootURLs: [agent: root], cacheURL: cache)
    }

    @Test func claudeTranscriptKeepsOnlyConversationTurns() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0f0e0d0c-1111-4222-8333-444455556666"
        func turn(_ type: String, _ content: Any, _ extra: [String: Any] = [:]) throws -> String {
            try json(["type": type, "sessionId": id, "cwd": "/repo", "message": ["role": type, "content": content]]
                .merging(extra) { _, new in new })
        }
        try write([
            try json(["type": "queue-operation", "operation": "enqueue", "sessionId": id, "content": "Fix the build"]),
            try turn("user", "Fix the build"),
            // The raw API request repeats the prompt behind injected reminders.
            try json(["type": "api-request-blob", "sessionId": id, "message": ["role": "user", "content": [
                ["type": "text", "text": "<system-reminder>CLAUDE.md says reply in Chinese</system-reminder>"],
                ["type": "text", "text": "Fix the build"],
            ]]]),
            try json(["type": "api-request-blob", "sessionId": id,
                      "message": ["role": "system", "content": "You are Claude Code"]]),
            try turn("assistant", [["type": "thinking", "thinking": "private reasoning"]]),
            try turn("assistant", [["type": "text", "text": "The build is fixed."]]),
            try turn("user", "Base directory for this skill: /skills/debugging\n# Debugging", ["isMeta": true]),
            try turn("user", "This session is being continued from a previous conversation.",
                     ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]),
            try turn("assistant", [["type": "text", "text": "API Error: Connection refused"]],
                     ["isApiErrorMessage": true]),
            try turn("assistant", [["type": "text", "text": "Sub-agent finding"]], ["isSidechain": true]),
            try turn("user", [["type": "text", "text": "[Request interrupted by user]"]]),
            try turn("user", [["type": "tool_result", "tool_use_id": "t1", "content": "tool output"]]),
            try turn("user", "[Image: source: /tmp/claude/images/1.png]\nWhat does this show?"),
            try turn("assistant", [["type": "text", "text": "A stack trace."]]),
        ], to: root.appendingPathComponent("-repo/\(id).jsonl"))

        let session = try #require(await load(.claude, root: root, cache: root.appendingPathComponent("cache.json")).first)
        #expect(session.title == "Fix the build")
        let transcript = await AgentHistoryStore.transcript(for: session)
        #expect(transcript.messages.map(\.text) == [
            "Fix the build", "The build is fixed.", "What does this show?", "A stack trace.",
        ])
        #expect(transcript.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(!transcript.wasTruncated)
    }

    @Test func piTranscriptFollowsTheNewestBranch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "01a16769-eed7-7463-8124-2e63b0fdbc04"
        func message(_ entry: String, parent: String?, role: String, _ text: String) -> String {
            let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
            return #"{"type":"message","id":"\#(entry)","parentId":\#(parentJSON),"timestamp":"2026-10-23T06:19:18.104Z","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}}"#
        }
        try write([
            #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-10-23T06:19:18.104Z","cwd":"/repo"}"#,
            #"{"type":"model_change","id":"m1","parentId":null,"provider":"openai"}"#,
            message("u1", parent: "m1", role: "user", "Ship the release"),
            message("a1", parent: "u1", role: "assistant", "Upstream rate limit reached"),
            // The retry starts a sibling branch from the same parent.
            message("u2", parent: "m1", role: "user", "Ship the release"),
            message("a2", parent: "u2", role: "assistant", "Tagging now."),
            // Tool traffic is never decoded, yet it links the branch together.
            message("t1", parent: "a2", role: "toolResult", "git tag output"),
            #"{"type":"custom","customType":"note","data":{"id":"not-the-entry"},"id":"c1","parentId":"t1"}"#,
            message("a3", parent: "c1", role: "assistant", "Released 1.2.3."),
        ], to: root.appendingPathComponent("--repo--/2026-10-23T06-19-18-104Z_\(id).jsonl"))

        let session = try #require(await load(.pi, root: root, cache: root.appendingPathComponent("cache.json")).first)
        let transcript = await AgentHistoryStore.transcript(for: session)
        // The reply continues after its tool call, so both parts are one turn.
        #expect(transcript.messages.map(\.text) == ["Ship the release", "Tagging now.\n\nReleased 1.2.3."])
    }

    @Test func codexHidesUnusedSessionsAndInjectedTurns() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func item(_ role: String, _ text: String) throws -> String {
            try json(["type": "response_item", "payload": [
                "type": "message", "role": role,
                "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]],
            ]])
        }
        let used = "01a1c984-896e-7ea3-b6d6-6d3514eea6fc"
        let unused = "01a1a5e5-81c5-7ac0-9485-c231082388ab"
        try write([
            try json(["type": "session_meta", "payload": ["id": used, "cwd": "/repo"]]),
            try item("developer", "You are Codex"),
            try item("user", "<environment_context>\n<cwd>/repo</cwd>\n</environment_context>"),
            try item("user", "<skill>\n<name>release</name>\n<path>/skills/release/SKILL.md</path>\nbody\n</skill>"),
            try item("user", "Cut a release"),
            try json(["type": "response_item", "payload": [
                "type": "function_call_output", "output": "the user and the assistant are mentioned here",
            ]]),
            try item("user", "<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>"),
            try item("assistant", "Done."),
        ], to: root.appendingPathComponent("2026/11/11/rollout-2026-11-11T15-31-08-\(used).jsonl"))
        try write([
            try json(["type": "session_meta", "payload": ["id": unused, "cwd": "/repo"]]),
            try json(["type": "event_msg", "payload": ["type": "thread_settings_applied"]]),
        ], to: root.appendingPathComponent("2026/11/04/rollout-2026-11-04T17-30-44-\(unused).jsonl"))

        let sessions = await load(.codex, root: root, cache: root.appendingPathComponent("cache.json"))
        #expect(sessions.map(\.conversationID.rawValue) == [used])
        #expect(sessions.first?.title == "Cut a release")
        let transcript = await AgentHistoryStore.transcript(for: try #require(sessions.first))
        #expect(transcript.messages.map(\.text) == ["Cut a release", "Done."])
    }

    @Test func userTextCollapsesSkillBodiesAndAnswersDropLeakedReasoning() {
        let skill = """
        <skill name="omg-release" location="/repo/.agents/skills/omg-release/SKILL.md">
        References are relative to /repo.
        # Release steps
        </skill>

        publish 0.20.3
        """
        #expect(AgentHistoryStore.cleanMeaningfulText(skill) == "/skill:omg-release\npublish 0.20.3")
        #expect(AgentHistoryStore.cleanMeaningfulText("[Request interrupted by user]").isEmpty)
        #expect(AgentHistoryStore.cleanMeaningfulText(
            "/var/folders/2z/T/pi-clipboard-84118618.png\nwhy does it fail?") == "why does it fail?")

        #expect(AgentHistoryStore.removingLeadingReasoning("<thinking>plan</thinking>\n\nThe answer.") == "The answer.")
        #expect(AgentHistoryStore.removingLeadingReasoning("<thinking>only reasoning").isEmpty)
        // A tag the model did not close as a block is the answer's own text.
        #expect(AgentHistoryStore.removingLeadingReasoning("Use <thinking> tags") == "Use <thinking> tags")
    }

    // MARK: Database-backed Agents

    private func makeDatabase(_ url: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func openCodeSessionsAndTranscriptsComeFromItsDatabase() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("opencode.db")
        try makeDatabase(database, """
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
            time_updated INTEGER, time_archived INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session VALUES ('ses_main', NULL, '/repo', 'New session - 2026-09-21T06:05:40.251Z', 1791103411954, NULL);
        INSERT INTO session VALUES ('ses_child', 'ses_main', '/repo', 'Sub-agent', 1791103411955, NULL);
        INSERT INTO session VALUES ('ses_unused', NULL, '/repo', 'Never used', 1791103411956, NULL);
        INSERT INTO message VALUES ('m1', 'ses_main', 1, '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 'ses_main', 2, '{"role":"assistant"}');
        INSERT INTO message VALUES ('m3', 'ses_child', 3, '{"role":"user"}');
        INSERT INTO part VALUES ('p1', 'm1', 'ses_main', 1, '{"type":"text","text":"Called the Read tool","synthetic":true}');
        INSERT INTO part VALUES ('p2', 'm1', 'ses_main', 2, '{"type":"text","text":"Explain the planner"}');
        INSERT INTO part VALUES ('p3', 'm2', 'ses_main', 3, '{"type":"reasoning","text":"hidden"}');
        INSERT INTO part VALUES ('p4', 'm2', 'ses_main', 4, '{"type":"text","text":"It has two stages."}');
        INSERT INTO part VALUES ('p5', 'm2', 'ses_main', 5, '{"type":"tool","tool":"read"}');
        INSERT INTO part VALUES ('p6', 'm2', 'ses_main', 6, '{"type":"text","text":"The second one rewrites joins."}');
        INSERT INTO part VALUES ('p7', 'm3', 'ses_child', 7, '{"type":"text","text":"Sub-agent prompt"}');
        """)

        let sessions = await load(.opencode, root: database, cache: root.appendingPathComponent("cache.json"))
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.conversationID.rawValue == "ses_main")
        #expect(session.title == "Explain the planner")
        #expect(session.workingDirectory == "/repo")
        #expect(session.resumeCommand == "opencode --session ses_main")
        let transcript = await AgentHistoryStore.transcript(for: session)
        #expect(transcript.messages.map(\.text) == [
            "Explain the planner", "It has two stages.\n\nThe second one rewrites joins.",
        ])
        let matches = await AgentHistoryStore.search(sessions: sessions, query: "rewrites joins", index: nil)
        #expect(matches[session.id]?.snippet.contains("rewrites joins") == true)
    }

    @Test func hermesSessionsAndTranscriptsComeFromItsDatabase() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.db")
        try makeDatabase(database, """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, started_at REAL, ended_at REAL,
            last_activity_at REAL, message_count INTEGER, hidden INTEGER);
        CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT,
            timestamp REAL, _compressed_summary INTEGER);
        INSERT INTO sessions VALUES ('local-abc', NULL, '/repo', 1792652536, NULL, 1792652540, 3, 0);
        INSERT INTO sessions VALUES ('local-empty', 'Bot Chat', '/repo', 1792650853, NULL, NULL, 0, 0);
        INSERT INTO messages (session_id, role, content, timestamp, _compressed_summary) VALUES
            ('local-abc', 'user', 'say hi in one word', 1792652536, 0),
            ('local-abc', 'tool', 'tool output', 1792652537, 0),
            ('local-abc', 'assistant', '[{"type":"text","text":"Hi"}]', 1792652538, 0),
            ('local-abc', 'assistant', 'Earlier turns, summarized', 1792652539, 1);
        """)

        let sessions = await load(.hermes, root: database, cache: root.appendingPathComponent("cache.json"))
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.title == "say hi in one word")
        #expect(session.updatedAt.timeIntervalSince1970 == 1_792_652_540)
        let transcript = await AgentHistoryStore.transcript(for: session)
        #expect(transcript.messages.map(\.text) == ["say hi in one word", "Hi"])
        #expect(transcript.messages.first?.timestamp == Date(timeIntervalSince1970: 1_792_652_536))
    }

    /// Minimal protobuf writer for the fields the reader looks at.
    private enum Proto {
        static func varint(_ value: UInt64) -> Data {
            var value = value
            var data = Data()
            repeat {
                let byte = UInt8(value & 0x7F)
                value >>= 7
                data.append(value == 0 ? byte : byte | 0x80)
            } while value != 0
            return data
        }

        static func field(_ number: Int, _ payload: Data) -> Data {
            varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload
        }

        static func field(_ number: Int, _ text: String) -> Data { field(number, Data(text.utf8)) }
        static func field(_ number: Int, _ value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
    }

    @Test func antigravityTranscriptDecodesTrajectorySteps() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("conversations")
        let hex = { (data: Data) in data.map { String(format: "%02x", $0) }.joined() }
        let header = Proto.field(5, Proto.field(1, Proto.field(1, 1_795_144_730)))
        let user = Proto.field(1, 14) + header + Proto.field(19, Proto.field(2, "Close the stale issues"))
        let injected = Proto.field(1, 90) + header + Proto.field(103, Proto.field(1, "<context_bundle>secret</context_bundle>"))
        let toolOnly = Proto.field(1, 15) + header + Proto.field(20, Proto.field(3, "private reasoning") +
            Proto.field(7, Proto.field(2, "run_command")))
        let reply = Proto.field(1, 15) + header + Proto.field(20, Proto.field(3, "more reasoning") +
            Proto.field(1, "Closed #12 and #14."))
        try makeDatabase(conversations.appendingPathComponent("agy-main.db"), """
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, step_payload BLOB);
        INSERT INTO steps VALUES (0, 14, x'\(hex(user))');
        INSERT INTO steps VALUES (1, 90, x'\(hex(injected))');
        INSERT INTO steps VALUES (2, 15, x'\(hex(toolOnly))');
        INSERT INTO steps VALUES (3, 132, x'\(hex(Proto.field(140, "tool result")))');
        INSERT INTO steps VALUES (4, 15, x'\(hex(reply))');
        """)
        try Data().write(to: conversations.appendingPathComponent("agy-worker.db"))
        try makeDatabase(root.appendingPathComponent("conversation_summaries.db"), """
        CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, preview TEXT, workspace_uris TEXT,
            last_modified_time TEXT, nesting_depth INTEGER, parent_conversation_id TEXT);
        INSERT INTO conversation_summaries VALUES
            ('agy-main', 'Issue triage', 'Close the stale issues', '["file:///repo"]', '2026-11-20 09:24:18+00:00', 0, ''),
            ('agy-worker', '', '', '["file:///repo"]', '2026-11-20 09:25:00+00:00', 1, 'agy-main');
        """)

        let sessions = await load(.antigravity, root: conversations, cache: root.appendingPathComponent("cache.json"))
        // The swarm worker is a conversation between Agents, not with the user.
        #expect(sessions.map(\.conversationID.rawValue) == ["agy-main"])
        let transcript = await AgentHistoryStore.transcript(for: try #require(sessions.first))
        #expect(transcript.messages.map(\.text) == ["Close the stale issues", "Closed #12 and #14."])
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages.first?.timestamp == Date(timeIntervalSince1970: 1_795_144_730))
        #expect(!transcript.wasTruncated)
    }

    // MARK: Full-text index

    private func session(_ id: String, updated: TimeInterval = 1_000, path: String = "/tmp/a.jsonl") -> AgentHistorySession {
        .init(agent: .codex, conversationID: AgentConversationID(id)!, title: id, workingDirectory: "/repo",
              updatedAt: Date(timeIntervalSince1970: updated), sourcePath: path, isActive: false, previewSnippet: nil)
    }

    private func transcript(_ session: AgentHistorySession, _ texts: [String]) -> AgentHistoryTranscript {
        .init(sessionID: session.id, messages: texts.enumerated().map {
            .init(id: "\(session.id):\($0.offset)", role: $0.offset.isMultiple(of: 2) ? .user : .assistant,
                  text: $0.element, timestamp: nil)
        }, wasTruncated: false)
    }

    @Test func searchIndexFindsSubstringsAndFollowsChangedSessions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("AgentHistory/search-index.sqlite")
        let index = AgentHistorySearchIndex(url: url)
        let first = session("first")
        let second = session("second")
        let texts = [
            first.id: ["如何重建全文索引", "先删除旧的索引文件，再运行 reindex --full"],
            second.id: ["Rename the session runtime", "Renamed SessionRuntime to DurableRuntime in 14 files."],
        ]
        await index.update(sessions: [first, second]) { [self] in transcript($0, texts[$0.id] ?? []) }

        #expect(index.currentSessionIDs(among: [first, second]) == [first.id, second.id])
        // Chinese has no word breaks; a substring of any length must match.
        #expect(index.search("全文索引")[first.id]?.messageIndex == 0)
        #expect(index.search("索引").keys.sorted() == [first.id])
        #expect(index.search("sessionruntime")[second.id]?.messageIndex == 1)
        #expect(index.search("reindex --full")[first.id]?.snippet.contains("reindex --full") == true)
        #expect(index.search("100%").isEmpty)
        #expect(index.search("no such phrase").isEmpty)

        var attributes = stat()
        #expect(lstat(url.path, &attributes) == 0)
        #expect(attributes.st_mode & 0o777 == 0o600)

        // A session whose file changed is read again; the others are not.
        let changed = session("first", updated: 2_000)
        #expect(index.currentSessionIDs(among: [changed, second]) == [second.id])
        let reads = ReadCounter()
        await index.update(sessions: [changed, second]) { [self] session in
            await reads.note(session.id)
            return transcript(session, ["全新的内容"])
        }
        #expect(await reads.ids == [changed.id])
        #expect(index.search("全文索引").isEmpty)
        #expect(index.search("全新的内容")[changed.id] != nil)

        // A complete listing without a session means it was deleted.
        await index.update(sessions: [second], pruneMissing: true) { [self] in transcript($0, []) }
        #expect(index.search("全新的内容").isEmpty)
        #expect(index.indexedSessionCount() == 1)
        #expect(index.search("DurableRuntime")[second.id] != nil)
    }

    @Test func searchAnswersIndexedSessionsWithoutReadingThem() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = AgentHistorySearchIndex(url: root.appendingPathComponent("search-index.sqlite"))
        // The file does not exist: a match can only come from the index.
        let indexed = session("indexed", path: root.appendingPathComponent("missing.jsonl").path)
        await index.update(sessions: [indexed]) { [self] in transcript($0, ["Where is the flaky test?", "In SocketTests."]) }

        let matches = await AgentHistoryStore.search(sessions: [indexed], query: "sockettests", index: index)
        #expect(matches[indexed.id]?.snippet == "In SocketTests.")
        #expect(matches[indexed.id]?.messageIndex == 1)
        // A title match keeps its own snippet.
        let titled = await AgentHistoryStore.search(sessions: [indexed], query: "indexed", index: index)
        #expect(titled[indexed.id]?.snippet == "indexed codex indexed /repo")
        #expect(titled[indexed.id]?.isInTranscript == false)
        #expect(matches[indexed.id]?.isInTranscript == true)
        #expect(await AgentHistoryStore.search(sessions: [indexed], query: "absent", index: index).isEmpty)
    }

    // MARK: Markdown

    @Test func markdownSplitsProseCodeAndTables() {
        let blocks = AgentHistoryMarkdown.blocks("""
        ## Plan
        Use **bold** and `code` here.

        ```swift
        let x = 1 // **not bold**
        ```
        | 顺序 | Issue |
        |---|---|
        | 1 | #81 |
        a | b is not a table
        """)
        #expect(blocks.count == 4)
        guard case .prose(let heading) = blocks[0], case .code(let code) = blocks[1],
              case .code(let table) = blocks[2], case .prose(let tail) = blocks[3] else {
            Issue.record("unexpected block layout: \(blocks)")
            return
        }
        #expect(heading.string == "Plan\nUse bold and code here.")
        let boldRange = (heading.string as NSString).range(of: "bold")
        let boldFont = heading.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let codeRange = (heading.string as NSString).range(of: "code")
        let codeFont = heading.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        #expect(codeFont?.isFixedPitch == true)
        #expect(code == "let x = 1 // **not bold**")
        // Wide characters count as two columns, so the columns line up.
        #expect(table == "顺序  Issue\n────  ─────\n1     #81")
        #expect(tail.string == "a | b is not a table")

        // Unclosed markers stay as typed, and a truncated fence is still code.
        #expect(AgentHistoryMarkdown.attributedInline("2 * 3 * 4 and a_b_c", font: .systemFont(ofSize: 12)).string
            == "2 * 3 * 4 and a_b_c")
        #expect(AgentHistoryMarkdown.blocks("```\nunterminated") == [.code("unterminated")])
        let link = AgentHistoryMarkdown.attributedInline("see [docs](https://example.com/a)", font: .systemFont(ofSize: 12))
        #expect(link.string == "see docs")
        #expect(link.attribute(.link, at: 4, effectiveRange: nil) as? URL == URL(string: "https://example.com/a"))
    }
}

private actor ReadCounter {
    private(set) var ids: [String] = []
    func note(_ id: String) { ids.append(id) }
}
