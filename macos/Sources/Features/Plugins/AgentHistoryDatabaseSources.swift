import Foundation
import SQLite3

/// Read-only access to a database another program owns. Nothing here ever
/// writes to, locks for writing, or checkpoints the Agent's own files.
final class AgentHistoryDatabase {
    private var handle: OpaquePointer?

    /// A WAL database whose `-shm` file is absent cannot be opened read-only;
    /// with no pending `-wal` an immutable handle reads the same content.
    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let base = URL(fileURLWithPath: path).absoluteString
        for uri in [base + "?mode=ro", base + "?immutable=1"] {
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
        agent == .opencode || agent == .hermes || agent == .antigravity
    }

    nonisolated static func defaultDatabaseURL(for agent: SupportedAgent) -> URL? {
        let path: String
        switch agent {
        case .opencode: path = "~/.local/share/opencode/opencode.db"
        case .hermes: path = "~/.hermes/state.db"
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
            guard let url = rootURLs[agent] ?? defaultDatabaseURL(for: agent),
                  let database = AgentHistoryDatabase(path: url.path) else { continue }
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

    /// nil when `session` does not belong to a database-backed Agent.
    nonisolated static func databaseMessages(for session: AgentHistorySession) -> [DatabaseMessage]? {
        guard usesDatabaseHistory(session.agent), session.remoteHost == nil else { return nil }
        guard let database = AgentHistoryDatabase(path: session.sourcePath) else { return [] }
        switch session.agent {
        case .opencode: return openCodeMessages(database, session: session.conversationID.rawValue)
        case .hermes: return hermesMessages(database, session: session.conversationID.rawValue)
        case .antigravity: return antigravityMessages(database)
        default: return nil
        }
    }

    // MARK: OpenCode

    nonisolated private static func openCodeSessions(
        _ database: AgentHistoryDatabase, path: String, limit: Int, updatedAfter: Date?
    ) -> [AgentHistorySession] {
        var sessions: [AgentHistorySession] = []
        let cutoff = String(Int((updatedAfter?.timeIntervalSince1970 ?? 0) * 1_000))
        let visit: (AgentHistoryDatabase.Row) -> Bool = { row in
            guard let id = row.text(0).flatMap(AgentConversationID.init), let updated = row.double(3) else { return true }
            let directory = validWorkingDirectory(row.text(2))
            var title = row.text(1)
            // OpenCode names an untitled session after its creation time.
            if title?.hasPrefix("New session - ") != false {
                title = openCodeFirstPrompt(database, session: id.rawValue) ?? title
            }
            sessions.append(.init(
                agent: .opencode, conversationID: id,
                title: normalizedTitle(title, workingDirectory: directory, conversationID: id),
                workingDirectory: directory, updatedAt: Date(timeIntervalSince1970: updated / 1_000),
                sourcePath: path, isActive: false, previewSnippet: nil
            ))
            return sessions.count < limit
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
        _ database: AgentHistoryDatabase, path: String, limit: Int, updatedAfter: Date?
    ) -> [AgentHistorySession] {
        var sessions: [AgentHistorySession] = []
        let cutoff = String(updatedAfter?.timeIntervalSince1970 ?? 0)
        let visit: (AgentHistoryDatabase.Row) -> Bool = { row in
            guard let id = row.text(0).flatMap(AgentConversationID.init), let updated = row.double(3) else { return true }
            let directory = validWorkingDirectory(row.text(2))
            let prompt = hermesMessages(database, session: id.rawValue, limit: 1).first { $0.role == .user }?.text
            let title = row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? prompt
            sessions.append(.init(
                agent: .hermes, conversationID: id,
                title: normalizedTitle(title, workingDirectory: directory, conversationID: id),
                workingDirectory: directory, updatedAt: Date(timeIntervalSince1970: updated),
                sourcePath: path, isActive: false, previewSnippet: nil
            ))
            return sessions.count < limit
        }
        let activity = "COALESCE(last_activity_at, ended_at, started_at)"
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

    // MARK: Antigravity

    /// Step types of an Antigravity trajectory that carry conversation text.
    /// Everything else is injected context, tool activity, or bookkeeping.
    private enum AntigravityStep {
        static let userInput: Int32 = 14
        static let plannerResponse: Int32 = 15
    }

    nonisolated private static func antigravityMessages(_ database: AgentHistoryDatabase) -> [DatabaseMessage] {
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
}
