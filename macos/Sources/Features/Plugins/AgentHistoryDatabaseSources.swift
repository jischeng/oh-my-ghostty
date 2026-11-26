import Foundation
import SQLite3

/// Read-only access to a database another program owns. Nothing here ever
/// writes to, locks for writing, or checkpoints the Agent's own files.
final class AgentHistoryDatabase {
    private var handle: OpaquePointer?

    /// A reader of a write-ahead-log database joins its shared `-shm` index,
    /// and SQLite creates that file and an empty `-wal` beside the database
    /// when they are missing. With nothing in the log there is no writer to
    /// coordinate with, so an immutable handle reads the same content and
    /// leaves the Agent's folder as it found it. A database with a pending
    /// log, or a rollback journal, is opened read-only so its locks apply.
    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let base = URL(fileURLWithPath: path).absoluteString
        let readOnly = base + "?mode=ro"
        let immutable = base + "?immutable=1"
        for uri in Self.hasIdleWriteAheadLog(path) ? [immutable, readOnly] : [readOnly, immutable] {
            var database: OpaquePointer?
            if sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               sqlite3_exec(database, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK {
                sqlite3_busy_timeout(database, 250)
                handle = database
                return
            }
            sqlite3_close(database)
        }
        return nil
    }

    deinit { sqlite3_close(handle) }

    /// Size of the write-ahead log beside a database; 0 when there is none.
    static func writeAheadLogSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Bytes 18 and 19 of the header are 2 for a write-ahead-log database.
    private static func hasIdleWriteAheadLog(_ path: String) -> Bool {
        guard writeAheadLogSize(path) == 0, let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 20), header.count == 20 else { return false }
        return header[header.startIndex + 18] == 2 && header[header.startIndex + 19] == 2
    }

    struct Row {
        fileprivate let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func data(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    /// Runs `sql` and visits each row until `visit` returns false. Returns
    /// false when the statement cannot be prepared, so a caller can retry
    /// with a query for an older schema.
    @discardableResult
    func query(_ sql: String, _ arguments: [String] = [], visit: (Row) -> Bool) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            if !visit(Row(statement: statement)) { break }
        }
        return true
    }
}

/// The fields of one protobuf message, without a schema. Antigravity stores
/// each conversation step as a protobuf blob; only a few string fields matter.
struct AgentHistoryProtobuf {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private(set) var fields: [(number: Int, value: Value)] = []

    init?(_ data: Data) {
        var offset = data.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < data.endIndex, shift < 64 {
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while offset < data.endIndex {
            guard let key = varint(), key >> 3 > 0 else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields.append((number, .varint(value)))
            case 1:
                guard data.endIndex - offset >= 8 else { return nil }
                offset += 8
            case 2:
                guard let length = varint(), length <= UInt64(data.endIndex - offset) else { return nil }
                let end = offset + Int(length)
                fields.append((number, .bytes(data.subdata(in: offset..<end))))
                offset = end
            case 5:
                guard data.endIndex - offset >= 4 else { return nil }
                offset += 4
            default:
                return nil
            }
        }
    }

    func message(_ number: Int) -> AgentHistoryProtobuf? {
        for field in fields where field.number == number {
            if case .bytes(let data) = field.value { return AgentHistoryProtobuf(data) }
        }
        return nil
    }

    func string(_ number: Int) -> String? {
        for field in fields where field.number == number {
            if case .bytes(let data) = field.value, let value = String(data: data, encoding: .utf8) { return value }
        }
        return nil
    }

    func integer(_ number: Int) -> UInt64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }
}

/// Agents that keep conversations in a database instead of JSONL files.
extension AgentHistoryStore {
    /// One conversation turn before the shared length limits are applied.
    struct DatabaseMessage {
        let role: AgentHistoryMessageRole
        let text: String
        let timestamp: Date?
    }

    nonisolated static func usesDatabaseHistory(_ agent: SupportedAgent) -> Bool {
        agent == .opencode || agent == .hermes || agent == .antigravity || agent == .cursor
    }

    /// The database of an Agent that keeps one, or for Cursor the folder of
    /// its per-chat databases.
    nonisolated static func defaultDatabaseURL(for agent: SupportedAgent) -> URL? {
        let path: String
        switch agent {
        case .opencode: path = "~/.local/share/opencode/opencode.db"
        case .hermes: path = "~/.hermes/state.db"
        case .cursor: path = "~/.cursor/chats"
        default: return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Sessions of the database-backed Agents, newest first.
    nonisolated static func databaseSessions(
        agents: [SupportedAgent],
        rootURLs: [SupportedAgent: URL],
        maximumSessions: Int,
        updatedAfter: Date?
    ) -> [AgentHistorySession] {
        var sessions: [AgentHistorySession] = []
        for agent in agents where !Task.isCancelled {
            guard let url = rootURLs[agent] ?? defaultDatabaseURL(for: agent) else { continue }
            if agent == .cursor {
                sessions += cursorSessions(root: url, limit: maximumSessions, updatedAfter: updatedAfter)
                continue
            }
            guard let database = AgentHistoryDatabase(path: url.path) else { continue }
            switch agent {
            case .opencode:
                sessions += openCodeSessions(database, path: url.path, limit: maximumSessions, updatedAfter: updatedAfter)
            case .hermes:
                sessions += hermesSessions(database, path: url.path, limit: maximumSessions, updatedAfter: updatedAfter)
            default:
                break
            }
        }
        return sessions
    }

    /// One conversation of a database-backed Agent, asked for by its key, so
    /// it is found whatever its age and without listing the others.
    nonisolated static func databaseSession(
        agent: SupportedAgent, conversationID: AgentConversationID, rootURL: URL?
    ) -> AgentHistorySession? {
        guard let url = rootURL ?? defaultDatabaseURL(for: agent) else { return nil }
        let sessions: [AgentHistorySession]
        if agent == .cursor {
            sessions = cursorSessions(root: url, limit: 1, updatedAfter: nil, conversationID: conversationID)
        } else if let database = AgentHistoryDatabase(path: url.path) {
            switch agent {
            case .opencode:
                sessions = openCodeSessions(
                    database, path: url.path, limit: 1, updatedAfter: nil, conversationID: conversationID
                )
            case .hermes:
                sessions = hermesSessions(
                    database, path: url.path, limit: 1, updatedAfter: nil, conversationID: conversationID
                )
            default:
                sessions = []
            }
        } else {
            sessions = []
        }
        return sessions.first { $0.conversationID == conversationID }
    }

    /// nil when `session` does not belong to a database-backed Agent.
    nonisolated static func databaseMessages(for session: AgentHistorySession) -> [DatabaseMessage]? {
        guard usesDatabaseHistory(session.agent), session.remoteHost == nil else { return nil }
        guard let database = AgentHistoryDatabase(path: session.sourcePath) else { return [] }
        switch session.agent {
        case .opencode: return openCodeMessages(database, session: session.conversationID.rawValue)
        case .hermes: return hermesMessages(database, session: session.conversationID.rawValue)
        case .antigravity: return antigravityMessages(database)
        case .cursor: return cursorMessages(database)
        default: return nil
        }
    }

    // MARK: OpenCode

    nonisolated private static func openCodeSessions(
        _ database: AgentHistoryDatabase, path: String, limit: Int, updatedAfter: Date?,
        conversationID: AgentConversationID? = nil
    ) -> [AgentHistorySession] {
        var sessions: [AgentHistorySession] = []
        let cutoff = String(Int((updatedAfter?.timeIntervalSince1970 ?? 0) * 1_000))
        let visit: (AgentHistoryDatabase.Row) -> Bool = { row in
            guard let id = row.text(0).flatMap(AgentConversationID.init), let updated = row.double(3) else { return true }
            let directory = validWorkingDirectory(row.text(2))
            var title = row.text(1)
            // OpenCode names an untitled session after its creation time.
            let isPlaceholder = title?.hasPrefix("New session - ") != false
            var prompt: String?
            if isPlaceholder {
                prompt = openCodeFirstPrompt(database, session: id.rawValue)
                title = prompt ?? title
            }
            sessions.append(.init(
                agent: .opencode, conversationID: id,
                title: normalizedTitle(title, workingDirectory: directory, conversationID: id),
                workingDirectory: directory, updatedAt: Date(timeIntervalSince1970: updated / 1_000),
                sourcePath: path, isActive: false, previewSnippet: nil,
                nativeTitle: isPlaceholder ? nil : title,
                firstPrompt: prompt.map { String($0.prefix(maximumFirstPromptCharacters)) }
            ))
            return sessions.count < limit
        }
        if let conversationID {
            // The pane is showing this session, archived or not, old or new.
            database.query(
                "SELECT id, title, directory, time_updated FROM session WHERE id = ?1",
                [conversationID.rawValue], visit: visit
            )
            return sessions
        }
        // Sub-agent and archived sessions are not conversations to resume.
        let filtered = """
        SELECT id, title, directory, time_updated FROM session
        WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= CAST(?1 AS INTEGER)
          AND EXISTS (SELECT 1 FROM message WHERE message.session_id = session.id)
        ORDER BY time_updated DESC
        """
        if !database.query(filtered, [cutoff], visit: visit) {
            database.query(
                "SELECT id, title, directory, time_updated FROM session WHERE time_updated >= CAST(?1 AS INTEGER) ORDER BY time_updated DESC",
                [cutoff], visit: visit
            )
        }
        return sessions
    }

    /// Text parts of a session in order. Tool output is stored as parts too
    /// and can be megabytes each; `sizeFilter` skips those from the row
    /// header alone, before SQLite reads their content.
    nonisolated private static func openCodeTextParts(sizeFilter: Bool) -> String {
        """
        SELECT m.id, json_extract(m.data, '$.role'), m.time_created, json_extract(p.data, '$.text')
        FROM message m JOIN part p ON p.message_id = m.id
        WHERE m.session_id = ?1 \(sizeFilter ? "AND octet_length(p.data) < 262144" : "")
          AND json_extract(p.data, '$.type') = 'text'
          AND json_extract(p.data, '$.synthetic') IS NOT 1 AND json_extract(p.data, '$.ignored') IS NOT 1
          AND json_extract(m.data, '$.summary') IS NOT 1
        ORDER BY m.time_created, m.id, p.id
        """
    }

    /// `octet_length` needs SQLite 3.43; an older library reads every part.
    nonisolated private static func openCodeParts(
        _ database: AgentHistoryDatabase, session: String, visit: (AgentHistoryDatabase.Row) -> Bool
    ) {
        if !database.query(openCodeTextParts(sizeFilter: true), [session], visit: visit) {
            database.query(openCodeTextParts(sizeFilter: false), [session], visit: visit)
        }
    }

    nonisolated private static func openCodeFirstPrompt(_ database: AgentHistoryDatabase, session: String) -> String? {
        var prompt: String?
        openCodeParts(database, session: session) { row in
            guard row.text(1) == "user", let text = row.text(3) else { return true }
            let cleaned = cleanMeaningfulText(text)
            guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return true }
            prompt = cleaned
            return false
        }
        return prompt
    }

    nonisolated private static func openCodeMessages(
        _ database: AgentHistoryDatabase, session: String
    ) -> [DatabaseMessage] {
        var messages: [DatabaseMessage] = []
        var currentID: String?
        openCodeParts(database, session: session) { row in
            guard let id = row.text(0), let text = row.text(3),
                  let role = row.text(1).flatMap(AgentHistoryMessageRole.init(rawValue:)) else { return true }
            let created = row.double(2).map { Date(timeIntervalSince1970: $0 / 1_000) }
            // One message is split into parts; a tool call sits between them.
            if id == currentID, let last = messages.last {
                messages[messages.count - 1] = .init(role: last.role, text: last.text + "\n\n" + text, timestamp: last.timestamp)
            } else {
                messages.append(.init(role: role, text: text, timestamp: created))
                currentID = id
            }
            return true
        }
        return messages
    }

    // MARK: Hermes

    nonisolated private static func hermesSessions(
        _ database: AgentHistoryDatabase, path: String, limit: Int, updatedAfter: Date?,
        conversationID: AgentConversationID? = nil
    ) -> [AgentHistorySession] {
        var sessions: [AgentHistorySession] = []
        let cutoff = String(updatedAfter?.timeIntervalSince1970 ?? 0)
        let visit: (AgentHistoryDatabase.Row) -> Bool = { row in
            guard let id = row.text(0).flatMap(AgentConversationID.init), let updated = row.double(3) else { return true }
            let directory = validWorkingDirectory(row.text(2))
            let prompt = hermesMessages(database, session: id.rawValue, limit: 1).first { $0.role == .user }?.text
            let name = row.text(1).flatMap { $0.isEmpty ? nil : $0 }
            let title = name ?? prompt
            sessions.append(.init(
                agent: .hermes, conversationID: id,
                title: normalizedTitle(title, workingDirectory: directory, conversationID: id),
                workingDirectory: directory, updatedAt: Date(timeIntervalSince1970: updated),
                sourcePath: path, isActive: false, previewSnippet: nil,
                nativeTitle: name,
                firstPrompt: prompt.map { String($0.prefix(maximumFirstPromptCharacters)) }
            ))
            return sessions.count < limit
        }
        let activity = "COALESCE(last_activity_at, ended_at, started_at)"
        if let conversationID {
            // The pane is showing this session, whenever it was last active.
            let key = [conversationID.rawValue]
            if !database.query("SELECT id, title, cwd, \(activity) FROM sessions WHERE id = ?1", key, visit: visit) {
                database.query(
                    "SELECT id, title, cwd, COALESCE(ended_at, started_at) FROM sessions WHERE id = ?1",
                    key, visit: visit
                )
            }
            return sessions
        }
        let filtered = """
        SELECT id, title, cwd, \(activity) FROM sessions
        WHERE message_count > 0 AND COALESCE(hidden, 0) = 0 AND \(activity) >= CAST(?1 AS REAL) ORDER BY 4 DESC
        """
        if !database.query(filtered, [cutoff], visit: visit) {
            database.query(
                "SELECT id, title, cwd, COALESCE(ended_at, started_at) FROM sessions WHERE COALESCE(ended_at, started_at) >= CAST(?1 AS REAL) ORDER BY 4 DESC",
                [cutoff], visit: visit
            )
        }
        return sessions
    }

    nonisolated private static func hermesMessages(
        _ database: AgentHistoryDatabase, session: String, limit: Int? = nil
    ) -> [DatabaseMessage] {
        var messages: [DatabaseMessage] = []
        let visit: (AgentHistoryDatabase.Row) -> Bool = { row in
            guard let role = row.text(0).flatMap(AgentHistoryMessageRole.init(rawValue:)),
                  let content = row.text(1) else { return true }
            messages.append(.init(
                role: role, text: hermesText(content),
                timestamp: row.double(2).map { Date(timeIntervalSince1970: $0) }
            ))
            return limit.map { messages.count < $0 } ?? true
        }
        let turns = "role IN ('user', 'assistant') AND content IS NOT NULL AND content != ''"
        let filtered = """
        SELECT role, content, timestamp FROM messages
        WHERE session_id = ?1 AND \(turns) AND COALESCE(_compressed_summary, 0) = 0 ORDER BY id
        """
        if !database.query(filtered, [session], visit: visit) {
            database.query(
                "SELECT role, content, timestamp FROM messages WHERE session_id = ?1 AND \(turns) ORDER BY id",
                [session], visit: visit
            )
        }
        return messages
    }

    /// Multimodal turns are stored as a JSON array of typed parts.
    nonisolated private static func hermesText(_ content: String) -> String {
        guard content.hasPrefix("["), let data = content.data(using: .utf8),
              let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return content }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? content : text
    }

    // MARK: Cursor

    /// Cursor's CLI keeps one database per chat at
    /// `chats/<workspace>/<chat>/store.db`: a `meta` row describing the chat
    /// and content-addressed `blobs`. The root blob lists the chat's messages
    /// in order; each message is a JSON blob with a role and its parts.
    private struct CursorChat {
        let identifier: String
        let name: String?
        let workingDirectory: String?
        let messages: [DatabaseMessage]
    }

    nonisolated private static func cursorSessions(
        root: URL, limit: Int, updatedAfter: Date?, conversationID: AgentConversationID? = nil
    ) -> [AgentHistorySession] {
        let manager = FileManager.default
        var stores: [(url: URL, updated: Date)] = []
        for workspace in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] {
            let folder = root.appendingPathComponent(workspace)
            for chat in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                // A chat's folder is named after it, so one chat is one folder.
                if let conversationID, chat != conversationID.rawValue { continue }
                let store = folder.appendingPathComponent(chat).appendingPathComponent("store.db")
                // Recent writes sit in the write-ahead log until a checkpoint.
                // An empty log holds none; a reader can have created it.
                let files = AgentHistoryDatabase.writeAheadLogSize(store.path) > 0
                    ? [store.path, store.path + "-wal"] : [store.path]
                let updated = files.compactMap {
                    (try? manager.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
                }.max()
                guard let updated, updatedAfter.map({ updated >= $0 }) ?? true else { continue }
                stores.append((store, updated))
            }
        }
        var sessions: [AgentHistorySession] = []
        for store in stores.sorted(by: { $0.updated > $1.updated }) where !Task.isCancelled {
            guard sessions.count < limit,
                  let database = AgentHistoryDatabase(path: store.url.path),
                  let chat = cursorChat(database, maximumMessages: 1),
                  // The chat folder is the ID `cursor-agent --resume` takes.
                  chat.identifier == store.url.deletingLastPathComponent().lastPathComponent,
                  let id = AgentConversationID(chat.identifier),
                  let prompt = chat.messages.first?.text else { continue }
            let directory = validWorkingDirectory(chat.workingDirectory)
            // Cursor names a chat itself once it has something to go on.
            let name = chat.name.flatMap { $0.isEmpty || $0 == "New Agent" ? nil : $0 }
            let title = name ?? prompt
            sessions.append(.init(
                agent: .cursor, conversationID: id,
                title: normalizedTitle(title, workingDirectory: directory, conversationID: id),
                workingDirectory: directory, updatedAt: store.updated,
                sourcePath: store.url.path, isActive: false, previewSnippet: String(prompt.prefix(1_000)),
                nativeTitle: name,
                firstPrompt: String(prompt.prefix(maximumFirstPromptCharacters))
            ))
        }
        return sessions
    }

    nonisolated private static func cursorMessages(_ database: AgentHistoryDatabase) -> [DatabaseMessage] {
        cursorChat(database, maximumMessages: nil)?.messages ?? []
    }

    /// Reads a chat's description and its turns, stopping after
    /// `maximumMessages` when only the opening prompt is wanted.
    nonisolated private static func cursorChat(
        _ database: AgentHistoryDatabase, maximumMessages: Int?
    ) -> CursorChat? {
        var encoded: String?
        database.query("SELECT value FROM meta WHERE key = '0'") { row in
            encoded = row.text(0)
            return false
        }
        // The description is JSON, stored as hexadecimal text.
        guard let encoded, let description = Data(hexadecimal: encoded),
              let meta = try? JSONSerialization.jsonObject(with: description) as? [String: Any],
              let identifier = meta["agentId"] as? String,
              let rootID = meta["latestRootBlobId"] as? String,
              let root = cursorBlob(database, id: rootID).flatMap(AgentHistoryProtobuf.init) else { return nil }
        var workingDirectory: String?
        var messages: [DatabaseMessage] = []
        for field in root.fields {
            guard case .bytes(let value) = field.value else { continue }
            if field.number == 9, let uri = String(data: value, encoding: .utf8), uri.hasPrefix("file://") {
                workingDirectory = URL(string: uri)?.path
            }
            guard field.number == 1, maximumMessages.map({ messages.count < $0 }) ?? true,
                  let blob = cursorBlob(database, id: value.map { String(format: "%02x", $0) }.joined()),
                  let message = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
                  let role = (message["role"] as? String).flatMap(AgentHistoryMessageRole.init(rawValue:)),
                  let text = cursorText(message["content"], role: role), !text.isEmpty else { continue }
            // A prompt sent again before any reply is one request, retried.
            if role == .user, messages.last?.role == .user, messages.last?.text == text { continue }
            messages.append(.init(role: role, text: text, timestamp: nil))
        }
        return .init(
            identifier: identifier, name: meta["name"] as? String,
            workingDirectory: workingDirectory, messages: messages
        )
    }

    nonisolated private static func cursorBlob(_ database: AgentHistoryDatabase, id: String) -> Data? {
        var data: Data?
        database.query("SELECT data FROM blobs WHERE id = ?1", [id]) { row in
            data = row.data(0)
            return false
        }
        return data
    }

    /// The readable text of a message. Cursor sends the user's prompt inside
    /// `<user_query>`; a user message without one is context it attached
    /// (environment, rules, reminders). Reasoning and tool calls are parts of
    /// an assistant message that are not its reply.
    nonisolated private static func cursorText(_ content: Any?, role: AgentHistoryMessageRole) -> String? {
        let texts: [String]
        if let content = content as? String {
            texts = [content]
        } else if let parts = content as? [[String: Any]] {
            texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        } else {
            return nil
        }
        guard role == .user else { return texts.joined(separator: "\n\n") }
        var queries: [String] = []
        for text in texts {
            var rest = Substring(text)
            while let open = rest.range(of: "<user_query>"),
                  let close = rest[open.upperBound...].range(of: "</user_query>") {
                queries.append(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
                rest = rest[close.upperBound...]
            }
        }
        return queries.joined(separator: "\n\n")
    }

    // MARK: Antigravity

    /// Step types of an Antigravity trajectory that carry conversation text.
    /// Everything else is injected context, tool activity, or bookkeeping.
    private enum AntigravityStep {
        static let userInput: Int32 = 14
        static let plannerResponse: Int32 = 15
    }

    nonisolated static func antigravityMessages(_ database: AgentHistoryDatabase) -> [DatabaseMessage] {
        var messages: [DatabaseMessage] = []
        let sql = """
        SELECT step_type, step_payload FROM steps
        WHERE step_type IN (\(AntigravityStep.userInput), \(AntigravityStep.plannerResponse)) ORDER BY idx
        """
        database.query(sql) { row in
            guard let type = row.double(0).map(Int32.init), let payload = row.data(1),
                  let step = AgentHistoryProtobuf(payload) else { return true }
            let seconds = step.message(5)?.message(1)?.integer(1)
            let timestamp = seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            if type == AntigravityStep.userInput, let text = step.message(19)?.string(2) {
                messages.append(.init(role: .user, text: text, timestamp: timestamp))
            } else if type == AntigravityStep.plannerResponse, let response = step.message(20),
                      let text = response.string(1) ?? response.string(8) {
                // A planner step that only calls tools has no visible reply.
                messages.append(.init(role: .assistant, text: text, timestamp: timestamp))
            }
            return true
        }
        return messages
    }

    nonisolated static func antigravityFirstPrompt(_ database: AgentHistoryDatabase) -> String? {
        var prompt: String?
        let sql = """
        SELECT step_payload FROM steps WHERE step_type = \(AntigravityStep.userInput) ORDER BY idx
        """
        database.query(sql) { row in
            guard let payload = row.data(0),
                  let step = AgentHistoryProtobuf(payload),
                  let raw = step.message(19)?.string(2) else { return true }
            let cleaned = cleanMeaningfulText(raw)
            guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return true }
            prompt = cleaned
            return false
        }
        return prompt
    }
}

private extension Data {
    /// Bytes written as hexadecimal digits, or nil when the text is not that.
    init?(hexadecimal text: String) {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 48...57: digit - 48
            case 97...102: digit - 87
            case 65...70: digit - 55
            default: nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.init(bytes)
    }
}
