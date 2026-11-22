import Foundation
import OSLog
import SQLite3

/// Where a query was found in a session.
struct AgentHistorySearchMatch: Equatable, Sendable {
    /// Text around the first occurrence, for the result row.
    var snippet: String
    /// Position of the first matching message in the session's transcript.
    var messageIndex: Int?
    /// False when only the title, ID or folder matched. Opening such a
    /// result shows the conversation from its start.
    var isInTranscript = true
    /// How many turns hold the query, as far as the search counted them.
    var matchCount = 1
    /// How strongly the session answers the query; larger sorts first.
    var relevance: Double = 0

    /// A title that holds the query outranks any number of mentions; the ID
    /// or folder is a deliberate lookup but says less about the content.
    static let titleRelevance: Double = 100
    static let metadataRelevance: Double = 40

    /// Mentions count logarithmically, so a long session cannot bury a
    /// short one that is about the query, and recent work breaks ties.
    static func relevance(matchCount: Int, updatedAt: Date, now: Date = Date()) -> Double {
        let mentions = 10 * log2(1 + Double(min(max(matchCount, 0), 63)))
        let ageInDays = max(0, now.timeIntervalSince(updatedAt)) / 86_400
        return mentions + 10 * exp(-ageInDays / 30)
    }
}

/// A full-text index over the cleaned user and assistant turns of local
/// sessions, so a search reads one database instead of every transcript.
///
/// The trigram tokenizer matches substrings, which is what works for Chinese
/// and for identifiers. Three characters or more are answered from the
/// index; a shorter query scans the stored text, still far cheaper than
/// decoding session files. Positions are not stored (`detail = none`): a
/// substring match needs none, and the index is about a third smaller.
final class AgentHistorySearchIndex: @unchecked Sendable {
    static let shared = AgentHistorySearchIndex(url: defaultURL())

    private static let schemaVersion: Int32 = 2
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "agent-history-index"
    )
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let url: URL
    private let queue = DispatchQueue(label: "com.jischeng.omg.agent-history-index", qos: .utility)
    private var handle: OpaquePointer?
    private var didOpen = false
    private let updateLock = NSLock()
    private var updateTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    deinit {
        updateTask?.cancel()
        sqlite3_close(handle)
    }

    static func defaultURL() -> URL {
        OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("AgentHistory", isDirectory: true)
            .appendingPathComponent("search-index.sqlite")
    }

    // MARK: Reading

    /// IDs of `sessions` whose indexed text matches the files on disk. Only
    /// these can be answered from the index; the rest still need a scan.
    func currentSessionIDs(among sessions: [AgentHistorySession]) -> Set<String> {
        queue.sync {
            let indexed = indexedSessions()
            return Set(sessions.lazy.filter { Self.isCurrent($0, in: indexed) }.map(\.id))
        }
    }

    /// The best match of `query` in each indexed session.
    func search(_ query: String, maximumSessions: Int = 5_000) -> [String: AgentHistorySearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }
        return queue.sync {
            guard open() else { return [:] }
            // Rows come back in insertion order, so the first row of a
            // session is its earliest matching message.
            let sql = "SELECT session, position, body FROM messages WHERE body LIKE ?1 ESCAPE '\\'"
            let argument = "%" + needle.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, argument, -1, Self.transient)
            var matches: [String: AgentHistorySearchMatch] = [:]
            while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
                guard let session = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
                if matches[session] != nil {
                    matches[session]?.matchCount += 1
                    continue
                }
                guard matches.count < maximumSessions,
                      let body = sqlite3_column_text(statement, 2).map({ String(cString: $0) }) else { continue }
                let range = body.range(of: needle, options: .caseInsensitive)
                matches[session] = .init(
                    snippet: range.map { AgentHistoryStore.searchSnippet(body, around: $0) } ?? String(body.prefix(200)),
                    messageIndex: Int(sqlite3_column_int64(statement, 1))
                )
            }
            return matches
        }
    }

    /// Number of sessions with indexed text.
    func indexedSessionCount() -> Int {
        queue.sync { indexedSessions().count }
    }

    // MARK: Writing

    /// Brings the index in line with `sessions` in the background, newest
    /// first, replacing any update already running. Only sessions whose file
    /// changed are read again.
    /// - Parameter pruneMissing: `sessions` is the complete history, so an
    ///   indexed session that is absent from it no longer exists.
    func scheduleUpdate(
        sessions: [AgentHistorySession],
        pruneMissing: Bool,
        transcript: @escaping @Sendable (AgentHistorySession) async -> AgentHistoryTranscript = {
            await AgentHistoryStore.transcript(for: $0)
        }
    ) {
        let task = Task<Void, Never>.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await update(sessions: sessions, pruneMissing: pruneMissing, transcript: transcript)
        }
        updateLock.lock()
        let previous = updateTask
        updateTask = task
        updateLock.unlock()
        previous?.cancel()
    }

    func cancelUpdate() {
        updateLock.lock()
        let task = updateTask
        updateTask = nil
        updateLock.unlock()
        task?.cancel()
    }

    func update(
        sessions: [AgentHistorySession],
        pruneMissing: Bool = false,
        transcript: @Sendable (AgentHistorySession) async -> AgentHistoryTranscript = {
            await AgentHistoryStore.transcript(for: $0)
        }
    ) async {
        let local = sessions.filter { $0.remoteHost == nil }
        let (stale, missing) = queue.sync { () -> ([AgentHistorySession], [String]) in
            let indexed = indexedSessions()
            let known = Set(local.map(\.id))
            return (
                local.filter { !Self.isCurrent($0, in: indexed) },
                pruneMissing ? indexed.keys.filter { !known.contains($0) } : []
            )
        }
        if !missing.isEmpty {
            queue.sync { missing.forEach(removeSession) }
        }
        for session in stale {
            guard !Task.isCancelled else { return }
            let content = await transcript(session)
            guard !Task.isCancelled else { return }
            queue.sync { store(session, messages: content.messages) }
            // Leave the machine to whatever the user is doing.
            await Task.yield()
        }
    }

    /// Drops everything, for tests and for a schema change.
    func removeAll() {
        queue.sync {
            guard open() else { return }
            exec("DELETE FROM messages; DELETE FROM sessions;")
        }
    }

    // MARK: Storage (queue-confined)

    private struct IndexedSession {
        let updated: Double
        let source: String
        let firstRow: Int64
        let lastRow: Int64
    }

    private static func isCurrent(_ session: AgentHistorySession, in indexed: [String: IndexedSession]) -> Bool {
        guard let entry = indexed[session.id] else { return false }
        return entry.source == session.sourcePath &&
            abs(entry.updated - session.updatedAt.timeIntervalSince1970) < 0.001
    }

    private func open() -> Bool {
        if didOpen { return handle != nil }
        didOpen = true
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Self.logger.error("cannot create index directory: \(error.localizedDescription, privacy: .public)")
            return false
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return false
        }
        handle = database
        // Transcripts are private; so are the index and its journal files.
        chmod(url.path, 0o600)
        sqlite3_busy_timeout(database, 500)
        exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        var version: Int32 = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        if version != Self.schemaVersion {
            exec("DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS sessions;")
        }
        let created = exec("""
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY, updated REAL NOT NULL, source TEXT NOT NULL,
            first_row INTEGER NOT NULL, last_row INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
            body, session UNINDEXED, position UNINDEXED, tokenize = 'trigram', detail = 'none'
        );
        PRAGMA user_version = \(Self.schemaVersion);
        """)
        if !created {
            Self.logger.error("cannot create the Agent History index")
            sqlite3_close(database)
            handle = nil
        }
        for suffix in ["-wal", "-shm"] { chmod(url.path + suffix, 0o600) }
        return handle != nil
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    private func indexedSessions() -> [String: IndexedSession] {
        guard open() else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle, "SELECT id, updated, source, first_row, last_row FROM sessions", -1, &statement, nil
        ) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var sessions: [String: IndexedSession] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let source = sqlite3_column_text(statement, 2).map({ String(cString: $0) }) else { continue }
            sessions[id] = .init(
                updated: sqlite3_column_double(statement, 1), source: source,
                firstRow: sqlite3_column_int64(statement, 3), lastRow: sqlite3_column_int64(statement, 4)
            )
        }
        return sessions
    }

    private func removeSession(_ id: String) {
        guard open(), let entry = indexedSession(id) else { return }
        if entry.firstRow <= entry.lastRow {
            exec("DELETE FROM messages WHERE rowid BETWEEN \(entry.firstRow) AND \(entry.lastRow)")
        }
        run("DELETE FROM sessions WHERE id = ?1", [id])
    }

    private func indexedSession(_ id: String) -> IndexedSession? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle, "SELECT updated, source, first_row, last_row FROM sessions WHERE id = ?1", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let source = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else { return nil }
        return .init(
            updated: sqlite3_column_double(statement, 0), source: source,
            firstRow: sqlite3_column_int64(statement, 2), lastRow: sqlite3_column_int64(statement, 3)
        )
    }

    /// Replaces a session's rows in one transaction. A session's messages
    /// occupy a contiguous row range, so removing them never scans the table.
    private func store(_ session: AgentHistorySession, messages: [AgentHistoryMessage]) {
        guard open(), exec("BEGIN IMMEDIATE") else { return }
        removeSession(session.id)
        var next: Int64 = 1
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT COALESCE(MAX(last_row), 0) + 1 FROM sessions", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            next = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(statement)
        let first = next
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle, "INSERT INTO messages(rowid, body, session, position) VALUES(?1, ?2, ?3, ?4)", -1, &insert, nil
        ) == SQLITE_OK else {
            exec("ROLLBACK")
            return
        }
        for (position, message) in messages.enumerated() {
            sqlite3_bind_int64(insert, 1, next)
            sqlite3_bind_text(insert, 2, message.text, -1, Self.transient)
            sqlite3_bind_text(insert, 3, session.id, -1, Self.transient)
            sqlite3_bind_int64(insert, 4, Int64(position))
            guard sqlite3_step(insert) == SQLITE_DONE else {
                sqlite3_finalize(insert)
                exec("ROLLBACK")
                return
            }
            sqlite3_reset(insert)
            next += 1
        }
        sqlite3_finalize(insert)
        // An empty range (first > last) records a session with nothing to index.
        var record: OpaquePointer?
        if sqlite3_prepare_v2(
            handle, "INSERT OR REPLACE INTO sessions(id, updated, source, first_row, last_row) VALUES(?1, ?2, ?3, ?4, ?5)",
            -1, &record, nil
        ) == SQLITE_OK {
            sqlite3_bind_text(record, 1, session.id, -1, Self.transient)
            sqlite3_bind_double(record, 2, session.updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(record, 3, session.sourcePath, -1, Self.transient)
            sqlite3_bind_int64(record, 4, first)
            sqlite3_bind_int64(record, 5, next - 1)
            sqlite3_step(record)
        }
        sqlite3_finalize(record)
        exec("COMMIT")
    }

    private func run(_ sql: String, _ arguments: [String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, Self.transient)
        }
        sqlite3_step(statement)
    }
}
