import Foundation
import SQLite3

struct AgentHistorySession: Identifiable, Equatable, Codable, Sendable {
    let agent: SupportedAgent
    let conversationID: AgentConversationID
    let title: String
    let workingDirectory: String?
    let updatedAt: Date
    let sourcePath: String
    /// Non-nil when the session lives on a remote host; the value is the SSH
    /// alias used to reach it.
    var remoteHost: String?
    var isActive: Bool
    var previewSnippet: String?
    /// The Agent's own name for the conversation, when it recorded one.
    /// `title` falls back to the opening prompt, the folder and the ID, so it
    /// cannot tell a name from a stand-in.
    var nativeTitle: String?
    /// The cleaned opening prompt, bounded, when the scan read one.
    var firstPrompt: String?
    /// True when `nativeTitle` came from an explicit user rename in the CLI (e.g. Claude `/rename`).
    var nativeTitleIsUserRenamed: Bool?

    var id: String { "\(agent.rawValue):\(conversationID.rawValue)" }

    /// Use the host's verified CLI syntax, without inventing launch flags that
    /// were not recorded with this session.
    var resumeCommand: String? {
        let arguments = agent == .pi ? ["--session", "{id}"] : agent.definition.resume.resumeArguments
        guard arguments.contains(where: { $0.contains("{id}") }) else { return nil }
        let argv = [agent.definition.command] + arguments.map {
            $0.replacingOccurrences(of: "{id}", with: conversationID.rawValue)
        }
        return argv.map { value in
            value.range(of: "^[A-Za-z0-9_./:@+-]+$", options: .regularExpression) != nil
                ? value : Ghostty.Shell.quote(value)
        }.joined(separator: " ")
    }

    /// The manifest's native fork arguments for this conversation; nil when
    /// the Agent declares none. Fork never falls back to a plain resume.
    var forkArguments: [String]? {
        guard let arguments = agent.definition.resume.forkArguments,
              arguments.contains(where: { $0.contains("{id}") }) else { return nil }
        return arguments.map { $0.replacingOccurrences(of: "{id}", with: conversationID.rawValue) }
    }

    var supportsFork: Bool { forkArguments != nil }
}

/// Where a forked conversation opens, relative to the Inspector's tab.
enum AgentHistoryForkPlacement: String, CaseIterable, Equatable, Sendable {
    case newTab
    case splitRight
    case splitDown
}

enum AgentHistoryMessageRole: String, Equatable, Sendable {
    case user
    case assistant
}

struct AgentHistoryMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: AgentHistoryMessageRole
    let text: String
    let timestamp: Date?
}

struct AgentHistoryTranscript: Equatable, Sendable {
    let sessionID: String
    let messages: [AgentHistoryMessage]
    let wasTruncated: Bool
}

enum AgentHistoryStore {
    static let maximumSessions = 10_000

    private static let maximumFiles = 200_000
    private static let maximumHeaderCandidates = 20_000
    private static let maximumHeaderBytes = 2 * 1_024 * 1_024
    /// Raw bytes read from one local transcript. Tool output dominates a
    /// session file and is skipped before JSON decoding, so the budget is on
    /// input, while the limits below bound what a transcript keeps.
    static let maximumTranscriptBytes = 768 * 1_024 * 1_024
    private static let maximumRemoteTranscriptBytes = 8 * 1_024 * 1_024
    private static let maximumRecordBytes = 4 * 1_024 * 1_024
    static let maximumTranscriptMessages = 4_000
    private static let maximumTranscriptCharacters = 4_000_000
    private static let maximumMessageCharacters = 48_000

    private enum Format {
        case jsonl
    }

    private struct Source {
        let agent: SupportedAgent
        let root: URL
        let format: Format
        let entryPattern: String?
        let idKeyPath: String?
        let cwdKeyPath: String?
    }

    private struct Candidate {
        let source: Source
        let url: URL
        let filenameID: AgentConversationID?
        let updatedAt: Date
    }

    private struct RemoteSource {
        let agent: SupportedAgent
        let rootPath: String
        let entryPattern: String?
        let idKeyPath: String?
        let cwdKeyPath: String?
    }

    private struct RemoteCandidate {
        let source: RemoteSource
        let file: AgentHistoryRemoteFile
        let filenameID: AgentConversationID?
    }

    static func load(
        agents: [SupportedAgent] = SupportedAgent.allCases,
        rootURLs: [SupportedAgent: URL] = [:],
        maximumSessions: Int = AgentHistoryStore.maximumSessions,
        cacheURL: URL? = nil,
        updatedAfter: Date? = nil,
        usesDiskCache: Bool = true
    ) async -> [AgentHistorySession] {
        let diskTask = Task.detached(priority: .utility) {
            scan(
                agents: agents,
                rootURLs: rootURLs,
                maximumSessions: maximumSessions,
                cacheURL: cacheURL,
                updatedAfter: updatedAfter,
                usesDiskCache: usesDiskCache
            )
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func loadCached(
        maximumSessions: Int = AgentHistoryStore.maximumSessions,
        cacheURL: URL? = nil
    ) async -> [AgentHistorySession] {
        let resolvedURL = cacheURL ?? defaultCacheURL()
        let diskTask = Task.detached(priority: .utility) { () -> [AgentHistorySession] in
            guard maximumSessions > 0,
                  let data = try? Data(contentsOf: resolvedURL),
                  let cache = try? JSONDecoder().decode(DiskCache.self, from: data),
                  cache.version == DiskCache.currentVersion else { return [] }
            var sessionsByID: [String: AgentHistorySession] = [:]
            for entry in cache.entries.values {
                guard !Task.isCancelled else { return [] }
                let session = entry.session
                guard FileManager.default.fileExists(atPath: session.sourcePath) else { continue }
                if let existing = sessionsByID[session.id],
                   existing.updatedAt >= session.updatedAt {
                    continue
                }
                sessionsByID[session.id] = session
            }
            return Array(sessionsByID.values.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }.prefix(maximumSessions))
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func loadRemote(
        access: AgentHistoryRemoteAccess,
        agents: [SupportedAgent] = SupportedAgent.allCases,
        maximumSessions: Int = AgentHistoryStore.maximumSessions,
        updatedAfter: Date? = nil
    ) async -> [AgentHistorySession] {
        let diskTask = Task.detached(priority: .utility) {
            await scanRemote(
                access: access,
                agents: agents,
                maximumSessions: maximumSessions,
                updatedAfter: updatedAfter
            )
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func session(
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        remoteHost: String? = nil,
        maximumSessions: Int = AgentHistoryStore.maximumSessions
    ) async -> AgentHistorySession? {
        if let remoteHost {
            let access = AgentHistoryRemoteAccess(alias: remoteHost)
            return await loadRemote(
                access: access,
                agents: [agent],
                maximumSessions: maximumSessions
            ).first(where: { $0.conversationID == conversationID })
        }
        return await load(
            agents: [agent],
            maximumSessions: maximumSessions
        ).first(where: { $0.conversationID == conversationID })
    }

    // MARK: Conversation titles

    /// What a session store calls a conversation, with where the name came from.
    struct TitleSeed: Equatable, Sendable {
        /// The Agent's own name for the conversation.
        var native: String?
        /// The cleaned opening prompt, bounded.
        var firstPrompt: String?
        /// True when `native` came from an explicit user rename in the Agent CLI.
        var isUserRenamed = false
    }

    /// A transcript that is not named after its conversation is looked for
    /// among the ones written this recently.
    static let titleSeedWindow: TimeInterval = 15 * 60
    nonisolated static let maximumFirstPromptCharacters = 1_000
    nonisolated private static let maximumRemoteTitleSeedSessions = 64
    /// Transcripts one lookup parses. A conversation has one file, or a live
    /// one and an archive; the recent window of a busy store holds a few more.
    nonisolated private static let maximumConversationCandidates = 64

    /// How a lookup of one conversation ended. Logged, so that a missing tab
    /// title can be traced to its cause.
    enum ConversationLookup: String, Sendable {
        /// A transcript named after the conversation was read.
        case named
        /// No file is named after it; it was among the recently written ones.
        case recent
        /// The Agent's database holds it.
        case database
        /// The SSH host returned it.
        case remote
        /// The Agent keeps no session store this build reads there.
        case unsupported
        /// The SSH host could not be asked.
        case unreachable
        /// The store holds no readable transcript of it.
        case missing
    }

    struct ConversationMatch: Sendable {
        let session: AgentHistorySession?
        let lookup: ConversationLookup
    }

    /// The name a session store holds for one conversation, or nil while it
    /// has no transcript there.
    ///
    /// A conversation is found whatever its age: a restored tab shows one that
    /// was last written days ago. Most Agents name the transcript after the
    /// conversation, so only files whose path holds the ID are parsed, and a
    /// database is asked for that one row. `updatedAfter` bounds the fallback
    /// for a store whose file names do not carry the ID. A remote conversation
    /// costs one SSH round trip with the same rules applied on the host.
    /// Unlike `session(agent:conversationID:remoteHost:)` this never parses a
    /// whole history, and it leaves the shared session cache alone.
    static func titleSeed(
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        remoteHost: String? = nil,
        updatedAfter: Date = Date().addingTimeInterval(-AgentHistoryStore.titleSeedWindow),
        rootURLs: [SupportedAgent: URL] = [:],
        remoteAccess: AgentHistoryRemoteAccess? = nil
    ) async -> TitleSeed? {
        let lookupTask: Task<ConversationMatch, Never>
        if let remoteHost {
            let access = remoteAccess ?? AgentHistoryRemoteAccess(alias: remoteHost)
            lookupTask = Task.detached(priority: .utility) {
                await remoteConversationSession(
                    access: access, agent: agent, conversationID: conversationID, recentAfter: updatedAfter
                )
            }
        } else {
            lookupTask = Task.detached(priority: .utility) {
                conversationSession(
                    agent: agent, conversationID: conversationID, rootURLs: rootURLs, recentAfter: updatedAfter
                )
            }
        }
        let match = await withTaskCancellationHandler(
            operation: { await lookupTask.value },
            onCancel: { lookupTask.cancel() }
        )
        let seed = match.session.map { titleSeed(from: $0) }
        // Never the name or the prompt themselves: only whether there is one.
        let place = remoteHost == nil ? "local" : "remote"
        AgentConversationTitleLog.info(
            "seed \(agent.rawValue) \(AgentConversationTitleLog.tag(conversationID)) \(place): " +
                "lookup=\(match.lookup.rawValue) native=\(seed?.native != nil) prompt=\(seed?.firstPrompt != nil)"
        )
        return seed
    }

    /// One local conversation, read from the files named after it or from the
    /// Agent's database, without walking the rest of its history.
    nonisolated static func conversationSession(
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        rootURLs: [SupportedAgent: URL] = [:],
        recentAfter: Date
    ) -> ConversationMatch {
        if agent == .antigravity {
            let stored = antigravitySessions(rootURL: rootURLs[agent], conversationID: conversationID)
                .first { $0.conversationID == conversationID }
            return .init(session: stored, lookup: stored == nil ? .missing : .database)
        }
        if usesDatabaseHistory(agent) {
            let stored = databaseSession(agent: agent, conversationID: conversationID, rootURL: rootURLs[agent])
            return .init(session: stored, lookup: stored == nil ? .missing : .database)
        }
        let stores = sources(for: agent, rootURL: rootURLs[agent])
        guard !stores.isEmpty else { return .init(session: nil, lookup: .unsupported) }

        let needle = conversationID.rawValue
        // Rank 2: the file is named after the conversation. Rank 1: a folder
        // above it is, as for a store that keeps each conversation in its own.
        var named: [(rank: Int, candidate: Candidate)] = []
        var recent: [Candidate] = []
        var inspectedFiles = 0
        let keys: [URLResourceKey] = [
            .contentModificationDateKey, .creationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        sourceLoop: for source in stores {
            guard let enumerator = FileManager.default.enumerator(
                at: source.root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            let rootPath = source.root.path
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { break sourceLoop }
                inspectedFiles += 1
                guard inspectedFiles <= maximumFiles else { break sourceLoop }
                guard isTranscript(url) else { continue }
                let path = url.path
                let rank: Int
                if url.lastPathComponent.contains(needle) {
                    rank = 2
                } else if path.hasPrefix(rootPath), path.dropFirst(rootPath.count).contains(needle) {
                    rank = 1
                } else {
                    rank = 0
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
                // Without a name to go by, only a file in use can be the one.
                guard rank > 0 || modified >= recentAfter else { continue }
                let filenameID = source.entryPattern.flatMap { pattern in
                    id(from: relativePath(of: url, under: source.root), pattern: pattern)
                        .flatMap(AgentConversationID.init)
                }
                let candidate = Candidate(source: source, url: url, filenameID: filenameID, updatedAt: modified)
                if rank > 0 {
                    named.append((rank, candidate))
                } else {
                    recent.append(candidate)
                }
            }
        }

        let lookup: ConversationLookup = named.isEmpty ? .recent : .named
        let ordered: [Candidate]
        if named.isEmpty {
            ordered = recent.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            named.sort { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                return lhs.candidate.updatedAt > rhs.candidate.updatedAt
            }
            ordered = named.map { $0.candidate }
        }
        for candidate in ordered.prefix(maximumConversationCandidates) {
            guard !Task.isCancelled else { break }
            guard var found = session(from: candidate), found.conversationID == conversationID else { continue }
            if agent == .codex, found.nativeTitle == nil {
                found.nativeTitle = codexThreadName(
                    conversationID: conversationID,
                    index: candidate.source.root.deletingLastPathComponent()
                        .appendingPathComponent("session_index.jsonl")
                )
            }
            return .init(session: found, lookup: lookup)
        }
        return .init(session: nil, lookup: .missing)
    }

    /// Codex keeps the names of its threads outside their rollouts, in
    /// `session_index.jsonl` beside the sessions folder: one line for each
    /// naming, so the last line of a conversation is its current name.
    nonisolated static func codexThreadName(conversationID: AgentConversationID, index: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: index) else { return nil }
        defer { try? handle.close() }
        // The index holds an ID, a name and a date for each thread.
        guard let data = try? handle.read(upToCount: 16 * 1_024 * 1_024) else { return nil }
        let needle = Data(conversationID.rawValue.utf8)
        var name: String?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: needle) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  entry["id"] as? String == conversationID.rawValue,
                  let value = entry["thread_name"] as? String else { continue }
            name = collapsedTitle(value)
        }
        return name
    }

    /// One conversation on an SSH host, in a single round trip.
    nonisolated private static func remoteConversationSession(
        access: AgentHistoryRemoteAccess,
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        recentAfter: Date
    ) async -> ConversationMatch {
        let roots = relativeRoots(for: agent)
        guard !roots.isEmpty else { return .init(session: nil, lookup: .unsupported) }
        let chunks: [AgentHistoryRemoteChunk]
        do {
            chunks = try await access.discoverSessions(
                relativeRoots: roots,
                maximumSessions: maximumRemoteTitleSeedSessions,
                updatedAfter: recentAfter,
                conversationID: conversationID
            )
        } catch {
            return .init(session: nil, lookup: .unreachable)
        }
        // The host applied the cutoff, and not to a file named after the conversation.
        let stored = remoteSessions(
            from: chunks, access: access, agents: [agent],
            maximumSessions: maximumRemoteTitleSeedSessions, updatedAfter: nil
        ).first { $0.conversationID == conversationID }
        return .init(session: stored, lookup: stored == nil ? .missing : .remote)
    }

    nonisolated static func titleSeed(from session: AgentHistorySession) -> TitleSeed {
        let prompt = session.firstPrompt.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var native = collapsedTitle(session.nativeTitle)
        // A store that names a conversation after its opening prompt has not named it,
        // unless the user explicitly ran `/rename` in the CLI.
        if native != nil, session.nativeTitleIsUserRenamed != true, native == collapsedTitle(prompt) {
            native = nil
        }
        return .init(
            native: native,
            firstPrompt: prompt,
            isUserRenamed: native != nil && session.nativeTitleIsUserRenamed == true
        )
    }

    /// The name an Agent gave a conversation: a title record of its store, or
    /// for Claude Code the user's `/rename` (`custom-title`), else the title it
    /// generated itself (`ai-title`). Of each kind the last record wins.
    nonisolated private static func nativeTitle(
        in records: [[String: Any]], agent: SupportedAgent, explicitTitle: String?
    ) -> (title: String?, isUserRenamed: Bool) {
        guard RecordFamily(agent) == .claude else {
            return (collapsedTitle(explicitTitle), false)
        }
        var custom: String?
        var generated: String?
        for record in records {
            switch record["type"] as? String {
            case "custom-title":
                // Clearing the name is a rename too.
                custom = collapsedTitle(record["customTitle"] as? String)
            case "ai-title":
                generated = collapsedTitle(record["aiTitle"] as? String) ?? generated
            default:
                break
            }
        }
        if let custom {
            return (custom, true)
        }
        return (generated ?? collapsedTitle(explicitTitle), false)
    }

    /// One line of at most 140 characters, as `normalizedTitle` keeps of a
    /// title; nil when there is no text.
    nonisolated private static func collapsedTitle(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let collapsed = rawValue.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(140))
    }

    static func transcript(
        for session: AgentHistorySession,
        remoteAccess: AgentHistoryRemoteAccess? = nil
    ) async -> AgentHistoryTranscript {
        // A remote Antigravity trajectory is not fetched; its summary stands in.
        if session.agent == .antigravity, session.remoteHost != nil {
            return previewTranscript(for: session)
        }
        if usesDatabaseHistory(session.agent), session.remoteHost == nil {
            let databaseTask = Task.detached(priority: .utility) { databaseTranscript(for: session) }
            return await withTaskCancellationHandler(
                operation: { await databaseTask.value },
                onCancel: { databaseTask.cancel() }
            )
        }
        if let alias = session.remoteHost {
            let access = remoteAccess ?? AgentHistoryRemoteAccess(alias: alias)
            guard let prefix = try? await access.readTranscript(
                path: session.sourcePath,
                maximumBytes: maximumRemoteTranscriptBytes
            ) else {
                return .init(
                    sessionID: session.id,
                    messages: [],
                    wasTruncated: false
                )
            }
            return parseTranscript(
                data: prefix.data,
                session: session,
                sourceWasTruncated: prefix.wasTruncated
            )
        }
        let diskTask = Task.detached(priority: .utility) {
            parseTranscript(for: session)
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    /// The Agent's own summary, shown when its conversation cannot be read.
    nonisolated private static func previewTranscript(for session: AgentHistorySession) -> AgentHistoryTranscript {
        .init(sessionID: session.id, messages: session.previewSnippet.map {
            [.init(id: session.id + ":preview", role: .user, text: $0, timestamp: nil)]
        } ?? [], wasTruncated: true)
    }

    nonisolated static func databaseTranscript(for session: AgentHistorySession) -> AgentHistoryTranscript {
        var builder = TranscriptBuilder(session: session)
        for message in databaseMessages(for: session) ?? [] {
            let text = message.role == .user
                ? cleanMeaningfulText(message.text, keepingUserPastes: true)
                : removingLeadingReasoning(message.text)
            guard !text.isEmpty, text != "[Image/Attachment]" else { continue }
            if !builder.append(.init(role: message.role, text: text, timestamp: message.timestamp, turnID: nil)) { break }
        }
        if builder.messages.isEmpty, session.agent == .antigravity { return previewTranscript(for: session) }
        return .init(sessionID: session.id, messages: builder.messages, wasTruncated: builder.wasTruncated)
    }

    /// Searches metadata and complete user/assistant transcript text off the
    /// main actor. Values locate the match for result rows and highlighting.
    static func search(
        sessions: [AgentHistorySession],
        query: String,
        index: AgentHistorySearchIndex? = .shared,
        remoteAccess: @escaping @Sendable (String) -> AgentHistoryRemoteAccess = { .init(alias: $0) }
    ) async -> [String: AgentHistorySearchMatch] {
        var latest: [String: AgentHistorySearchMatch] = [:]
        for await matches in searchUpdates(
            sessions: sessions, query: query, index: index, remoteAccess: remoteAccess
        ) {
            latest = matches
        }
        return latest
    }

    /// Emits title and path matches at once, then everything the full-text
    /// index knows, then scans only the sessions the index does not cover yet.
    /// Results therefore stay complete while the index is still being built.
    /// Sessions on an SSH host are searched last, in one command per host.
    static func searchUpdates(
        sessions: [AgentHistorySession],
        query: String,
        index: AgentHistorySearchIndex? = .shared,
        remoteAccess: @escaping @Sendable (String) -> AgentHistoryRemoteAccess = { .init(alias: $0) }
    ) -> AsyncStream<[String: AgentHistorySearchMatch]> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield([:])
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var matches: [String: AgentHistorySearchMatch] = [:]

                // Phase 1: title and small metadata only, so the first result
                // batch renders immediately.
                for session in sessions {
                    guard !Task.isCancelled else { break }
                    let metadata = [
                        session.title,
                        session.agent.rawValue,
                        session.conversationID.rawValue,
                        session.workingDirectory ?? "",
                    ].joined(separator: "\n")
                    guard let range = metadata.range(of: needle, options: .caseInsensitive) else { continue }
                    let inTitle = session.title.range(of: needle, options: .caseInsensitive) != nil
                    matches[session.id] = .init(
                        snippet: searchSnippet(metadata, around: range), isInTranscript: false, matchCount: 0,
                        relevance: (inTitle ? AgentHistorySearchMatch.titleRelevance
                            : AgentHistorySearchMatch.metadataRelevance)
                            + AgentHistorySearchMatch.relevance(matchCount: 0, updatedAt: session.updatedAt)
                    )
                }
                continuation.yield(matches)

                // Phase 2: the full-text index answers every session whose
                // indexed text is current.
                var indexed = Set<String>()
                if let index, !Task.isCancelled {
                    indexed = index.currentSessionIDs(among: sessions)
                    let found = indexed.isEmpty ? [:] : index.search(needle)
                    for session in sessions where indexed.contains(session.id) {
                        guard let hit = found[session.id] else { continue }
                        matches[session.id] = transcriptMatch(hit, of: session, over: matches[session.id])
                    }
                    continuation.yield(matches)
                }

                // Phase 3: cached bounded previews for sessions the index does
                // not cover, which includes every remote session.
                for session in sessions where matches[session.id] == nil && !indexed.contains(session.id) {
                    guard !Task.isCancelled else { break }
                    guard let preview = session.previewSnippet,
                          let range = preview.range(of: needle, options: .caseInsensitive) else { continue }
                    matches[session.id] = .init(
                        snippet: searchSnippet(preview, around: range),
                        relevance: AgentHistorySearchMatch.relevance(matchCount: 1, updatedAt: session.updatedAt)
                    )
                }
                continuation.yield(matches)

                // Phase 4: read the local sessions that are left.
                var lastYield = Date()
                for session in sessions {
                    guard !Task.isCancelled else { break }
                    guard session.remoteHost == nil, matches[session.id] == nil,
                          !indexed.contains(session.id) else { continue }
                    if let snippet = unindexedMatch(in: session, query: needle) {
                        matches[session.id] = .init(
                            snippet: snippet,
                            relevance: AgentHistorySearchMatch.relevance(matchCount: 1, updatedAt: session.updatedAt)
                        )
                    }
                    // Each update redraws the list; batch them.
                    if Date().timeIntervalSince(lastYield) > 0.25 {
                        continuation.yield(matches)
                        lastYield = Date()
                    }
                }
                continuation.yield(matches)

                // Phase 5: the transcripts of each SSH host, newest first.
                // A single character matches nearly every session, which is
                // work for the host and no help to the reader.
                if needle.count >= 2 {
                    let remote = sessions.filter {
                        $0.remoteHost != nil && !usesDatabaseHistory($0.agent)
                            && matches[$0.id]?.isInTranscript != true
                    }
                    for (host, hostSessions) in Dictionary(grouping: remote, by: { $0.remoteHost ?? "" }) {
                        guard !Task.isCancelled else { break }
                        let found = await remoteMatches(
                            in: hostSessions, query: needle, access: remoteAccess(host)
                        )
                        for session in hostSessions {
                            guard let hit = found[session.id] else { continue }
                            matches[session.id] = transcriptMatch(hit, of: session, over: matches[session.id])
                        }
                        continuation.yield(matches)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A match in the conversation, scored, on top of a title or ID match
    /// the session may already have. The earlier match keeps its snippet and
    /// its rank; the conversation adds how often it names the query.
    nonisolated private static func transcriptMatch(
        _ hit: AgentHistorySearchMatch, of session: AgentHistorySession, over metadata: AgentHistorySearchMatch?
    ) -> AgentHistorySearchMatch {
        var match = hit
        match.relevance = AgentHistorySearchMatch.relevance(matchCount: hit.matchCount, updatedAt: session.updatedAt)
        if let metadata {
            match.snippet = metadata.snippet
            match.relevance += metadata.relevance
                - AgentHistorySearchMatch.relevance(matchCount: 0, updatedAt: session.updatedAt)
        }
        return match
    }

    /// Matches of `query` in the transcripts of one SSH host's sessions.
    ///
    /// The host returns the records that name the query. Each is cleaned
    /// here exactly as a transcript is, so text the Agent injected around a
    /// prompt never counts as a match.
    nonisolated private static func remoteMatches(
        in sessions: [AgentHistorySession], query: String, access: AgentHistoryRemoteAccess
    ) async -> [String: AgentHistorySearchMatch] {
        let newest = Array(sessions.prefix(AgentHistoryRemoteAccess.maximumSearchFiles))
        guard let hits = try? await access.searchTranscripts(
            paths: newest.map(\.sourcePath), query: query
        ) else { return [:] }
        let sessionsByPath = Dictionary(newest.map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
        var matches: [String: AgentHistorySearchMatch] = [:]
        for hit in hits {
            guard let session = sessionsByPath[hit.path] else { continue }
            for line in hit.lines {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = parsedMessage(from: record, agent: session.agent, keepingUserPastes: true),
                      let range = message.text.range(of: query, options: .caseInsensitive) else { continue }
                matches[session.id] = .init(snippet: searchSnippet(message.text, around: range), matchCount: hit.count)
                break
            }
        }
        return matches
    }

    /// Finds `query` in a session the index has not read yet.
    nonisolated private static func unindexedMatch(in session: AgentHistorySession, query: String) -> String? {
        guard usesDatabaseHistory(session.agent) else {
            return firstTranscriptMatch(
                at: URL(fileURLWithPath: session.sourcePath), query: query, agent: session.agent
            )
        }
        for message in databaseTranscript(for: session).messages {
            if let range = message.text.range(of: query, options: .caseInsensitive) {
                return searchSnippet(message.text, around: range)
            }
        }
        return nil
    }

    private struct DiskCache: Codable {
        static let currentVersion = 9
        var version: Int = currentVersion
        struct Entry: Codable {
            let session: AgentHistorySession
            let mtime: TimeInterval
        }
        var entries: [String: Entry] = [:]
    }

    nonisolated private static func defaultCacheURL() -> URL {
        OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("AgentHistory", isDirectory: true)
            .appendingPathComponent("session-cache.json")
    }

    nonisolated private static func scan(
        agents: [SupportedAgent],
        rootURLs: [SupportedAgent: URL],
        maximumSessions: Int,
        cacheURL: URL? = nil,
        updatedAfter: Date? = nil,
        usesDiskCache: Bool = true
    ) -> [AgentHistorySession] {
        guard maximumSessions > 0 else { return [] }
        let resolvedCacheURL = cacheURL ?? defaultCacheURL()
        var diskCache: DiskCache = {
            // A lookup bounded by `updatedAfter` parses a handful of files.
            // Decoding and rewriting every cached session would dwarf it.
            if usesDiskCache,
               let data = try? Data(contentsOf: resolvedCacheURL),
               let decoded = try? JSONDecoder().decode(DiskCache.self, from: data),
               decoded.version == DiskCache.currentVersion {
                return decoded
            }
            return DiskCache()
        }()

        var candidates: [Candidate] = []
        var candidatePaths: Set<String> = []
        var inspectedFiles = 0

        for agent in agents where !Task.isCancelled {
            for source in sources(for: agent, rootURL: rootURLs[agent]) {
                guard !Task.isCancelled else { break }
                guard let enumerator = FileManager.default.enumerator(
                    at: source.root,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .creationDateKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let url as URL in enumerator {
                    guard !Task.isCancelled else { break }
                    inspectedFiles += 1
                    guard inspectedFiles <= maximumFiles else { break }
                    guard isTranscript(url),
                          let values = try? url.resourceValues(forKeys: [
                              .contentModificationDateKey,
                              .creationDateKey,
                              .isRegularFileKey,
                              .isSymbolicLinkKey,
                          ]),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true else { continue }
                    candidatePaths.insert(url.path)
                    let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
                    if let updatedAfter, modified < updatedAfter { continue }

                    let filenameID: AgentConversationID?
                    if let pattern = source.entryPattern {
                        let relativePath = relativePath(of: url, under: source.root)
                        // Stores such as omp write each conversation into its own
                        // directory, so a file name alone may not carry the ID.
                        // Fall back to validated header metadata instead of
                        // discarding the transcript entirely.
                        filenameID = id(from: relativePath, pattern: pattern)
                            .flatMap(AgentConversationID.init)
                    } else {
                        filenameID = nil
                    }
                    candidates.append(.init(
                        source: source,
                        url: url,
                        filenameID: filenameID,
                        updatedAt: values.contentModificationDate ??
                            values.creationDate ?? .distantPast
                    ))
                }
                if inspectedFiles > maximumFiles { break }
            }
        }

        candidates.sort { $0.updatedAt > $1.updatedAt }
        var sessionsByID: [String: AgentHistorySession] = [:]
        let originalCacheCount = diskCache.entries.count
        diskCache.entries = diskCache.entries.filter { path, entry in
            !agents.contains(entry.session.agent) || candidatePaths.contains(path)
        }
        var cacheUpdated = diskCache.entries.count != originalCacheCount

        // Parsing a compressed rollout needs an external decompressor, which
        // costs several milliseconds each. Fold cache hits serially, then parse
        // the remainder concurrently so thousands of archives stay responsive.
        let candidateLimit = min(candidates.count, maximumHeaderCandidates)
        var cachedSessions = [AgentHistorySession?](repeating: nil, count: candidateLimit)
        var parsedSessions = [AgentHistorySession?](repeating: nil, count: candidateLimit)
        var needsParse: [Int] = []
        needsParse.reserveCapacity(candidateLimit)
        for index in 0..<candidateLimit {
            let candidate = candidates[index]
            if let cached = diskCache.entries[candidate.url.path],
               abs(cached.mtime - candidate.updatedAt.timeIntervalSince1970) < 0.001 {
                cachedSessions[index] = cached.session
            } else {
                needsParse.append(index)
            }
        }
        if !needsParse.isEmpty {
            let lock = NSLock()
            var next = 0
            var cancelled = false
            // A bounded pool of decompression/JSON workers, each taking the
            // next file as it finishes one, so a slow archive holds up only
            // its own worker. GCD workers have no Swift task; the calling
            // thread is one of the workers and relays the task's cancellation.
            let workers = min(needsParse.count, max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)))
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while true {
                    lock.lock()
                    if Task.isCancelled { cancelled = true }
                    guard !cancelled, next < needsParse.count else {
                        lock.unlock()
                        return
                    }
                    let index = needsParse[next]
                    next += 1
                    lock.unlock()
                    let session = session(from: candidates[index])
                    lock.lock()
                    parsedSessions[index] = session
                    lock.unlock()
                }
            }
        }

        for index in 0..<candidateLimit {
            guard !Task.isCancelled, sessionsByID.count < maximumSessions else { break }
            let candidate = candidates[index]
            let session: AgentHistorySession?
            if let cached = cachedSessions[index] {
                session = cached
            } else {
                session = parsedSessions[index]
                if let session {
                    diskCache.entries[candidate.url.path] = .init(
                        session: session,
                        mtime: candidate.updatedAt.timeIntervalSince1970
                    )
                    cacheUpdated = true
                }
            }
            guard let session else { continue }
            if let existing = sessionsByID[session.id], existing.updatedAt >= session.updatedAt {
                continue
            }
            sessionsByID[session.id] = session
        }

        // A lookup that skipped the shared cache leaves it as it was.
        if usesDiskCache, cacheUpdated && !Task.isCancelled {
            if let data = try? JSONEncoder().encode(diskCache) {
                try? OMGPrivateFileWriter.writeAtomically(data, to: resolvedCacheURL)
            }
        } else if usesDiskCache {
            OMGPrivateFileWriter.tightenPermissionsIfPresent(at: resolvedCacheURL)
        }

        if agents.contains(.antigravity) {
            for session in antigravitySessions(rootURL: rootURLs[.antigravity]) {
                sessionsByID[session.id] = session
            }
        }
        for session in databaseSessions(
            agents: agents, rootURLs: rootURLs, maximumSessions: maximumSessions, updatedAfter: updatedAfter
        ) {
            sessionsByID[session.id] = session
        }
        return Array(sessionsByID.values.filter { session in updatedAfter.map { session.updatedAt >= $0 } ?? true }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }.prefix(maximumSessions))
    }

    /// - Parameter conversationID: Reads that one conversation, whatever its age.
    nonisolated private static func antigravitySessions(
        rootURL: URL?, conversationID: AgentConversationID? = nil
    ) -> [AgentHistorySession] {
        let root = rootURL ?? URL(fileURLWithPath:
            ("~/.gemini/antigravity-cli/conversations" as NSString).expandingTildeInPath)
        let index = root.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db")
        // Antigravity keeps its index in WAL mode. A read-only handle cannot
        // prepare statements against it (SQLITE_CANTOPEN), so read a private
        // copy with a read-write handle and never touch the Agent's own files.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-agy-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("summary.db")
        guard (try? FileManager.default.copyItem(at: index, to: copy)) != nil else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let columns = "SELECT conversation_id, title, preview, workspace_uris, strftime('%s', last_modified_time) FROM conversation_summaries"
        let order = " ORDER BY last_modified_time DESC LIMIT 10000"
        // A swarm's workers talk to each other, not to the user: they have a
        // parent, or no prompt to title or preview them by.
        let only = conversationID == nil ? "" : " AND conversation_id = ?1"
        let conversations = columns + " WHERE nesting_depth = 0 AND (title != '' OR preview != '')" + only + order
        let fallback = columns + (conversationID == nil ? "" : " WHERE conversation_id = ?1") + order
        guard sqlite3_prepare_v2(database, conversations, -1, &statement, nil) == SQLITE_OK ||
            sqlite3_prepare_v2(database, fallback, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let conversationID {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, conversationID.rawValue, -1, transient)
        }
        func value(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var sessions: [AgentHistorySession] = []
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            guard let id = AgentConversationID(value(0)), let seconds = Double(value(4)) else { continue }
            let path = root.appendingPathComponent(id.rawValue + ".db").path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let uris = value(3).data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let cwd = uris.compactMap(URL.init(string:)).first(where: \.isFileURL)?.path
            let modified = seconds > 0 ? Date(timeIntervalSince1970: seconds) :
                ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? Date())
            let preview = value(2)
            let name = value(1)
            let title = name.isEmpty ? preview : name
            sessions.append(.init(agent: .antigravity, conversationID: id,
                title: normalizedTitle(title, workingDirectory: cwd, conversationID: id),
                workingDirectory: cwd, updatedAt: modified,
                sourcePath: path, isActive: false, previewSnippet: preview.isEmpty ? nil : preview,
                nativeTitle: name.isEmpty ? nil : name,
                firstPrompt: preview.isEmpty ? nil : String(preview.prefix(maximumFirstPromptCharacters))))
        }
        return sessions
    }

    nonisolated private static func sources(
        for agent: SupportedAgent,
        rootURL: URL?
    ) -> [Source] {
        let resume = agent.definition.resume
        guard !resume.resumeArguments.isEmpty else { return [] }

        if let discovery = resume.discover, discovery.format == .jsonl {
            let roots = rootURL.map { [$0] } ?? ([discovery.root] + (discovery.additionalRoots ?? []))
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            return roots.map { root in
                .init(
                    agent: agent,
                    root: root,
                    format: .jsonl,
                    entryPattern: nil,
                    idKeyPath: discovery.idKeyPath,
                    cwdKeyPath: discovery.cwdKeyPath
                )
            }
        }

        guard let store = resume.store,
              store.entryPattern.lowercased().contains(".jsonl") else {
            return []
        }
        let root = rootURL ?? URL(fileURLWithPath:
            (store.root as NSString).expandingTildeInPath
        )
        return [.init(
            agent: agent,
            root: root,
            format: .jsonl,
            entryPattern: store.entryPattern,
            idKeyPath: nil,
            cwdKeyPath: nil
        )]
    }

    nonisolated private static func session(
        from candidate: Candidate
    ) -> AgentHistorySession? {
        let header = headerSnapshot(at: candidate.url, maximumBytes: maximumHeaderBytes)
        let records = header.records
        guard !records.isEmpty else { return nil }

        let metadataID: AgentConversationID? = if let keyPath =
            candidate.source.idKeyPath {
            records.lazy.compactMap {
                stringValue(at: keyPath, in: $0).flatMap(AgentConversationID.init)
            }.first
        } else {
            records.lazy.compactMap { record in
                if let value = record["sessionId"] as? String {
                    return AgentConversationID(value)
                }
                guard record["type"] as? String == "session",
                      let value = record["id"] as? String else { return nil }
                return AgentConversationID(value)
            }.first
        }
        if let filenameID = candidate.filenameID,
           let metadataID,
           filenameID != metadataID {
            return nil
        }
        guard let conversationID = metadataID ?? candidate.filenameID else {
            return nil
        }

        let configuredCwd = candidate.source.cwdKeyPath.flatMap { keyPath in
            records.lazy.compactMap { stringValue(at: keyPath, in: $0) }.first
        }
        let workingDirectory = validWorkingDirectory(
            configuredCwd ?? records.lazy.compactMap { record in
                stringValue(at: "cwd", in: record) ??
                    stringValue(at: "payload.cwd", in: record)
            }.first
        )
        let explicitTitle = records.reduce(nil as String?) { current, record in
            guard let type = record["type"] as? String,
                  ["title", "title_change", "session", "session_info"].contains(type),
                  let title = record["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return current
            }
            return title
        }
        let agent = candidate.source.agent
        // Cleaning a turn is the expensive step of a scan, and a first prompt
        // can be hundreds of kilobytes. Plain loops clean each record once;
        // a lazy chain re-evaluates its closure on every traversal.
        var userTitle: String?
        for record in records where role(of: record, agent: agent) == .user {
            guard let cleaned = text(of: record, role: .user),
                  !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { continue }
            // A title shows 140 characters; do not collapse a whole paste.
            userTitle = String(cleaned.prefix(2_000))
            break
        }
        let title = normalizedTitle(
            explicitTitle ?? userTitle,
            workingDirectory: workingDirectory,
            conversationID: conversationID
        )

        var previewLines: [String] = []
        for record in conversationRecords(records, agent: agent, isComplete: header.isComplete) {
            guard let role = role(of: record, agent: agent), let cleaned = text(of: record, role: role),
                  !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { continue }
            previewLines.append(String(cleaned.prefix(1_000)))
            if previewLines.count == 10 { break }
        }
        let previewSnippet = previewLines.joined(separator: "\n")

        // An Agent that was opened and closed without a turn leaves a file
        // with nothing to read or resume.
        if header.isComplete, RecordFamily(agent) != .generic,
           explicitTitle == nil, userTitle == nil, previewSnippet.isEmpty {
            return nil
        }

        let resolvedNative = nativeTitle(in: records, agent: agent, explicitTitle: explicitTitle)
        return .init(
            agent: candidate.source.agent,
            conversationID: conversationID,
            title: title,
            workingDirectory: workingDirectory,
            updatedAt: candidate.updatedAt,
            sourcePath: candidate.url.path,
            isActive: false,
            previewSnippet: previewSnippet.isEmpty ? nil : previewSnippet,
            nativeTitle: resolvedNative.title,
            firstPrompt: userTitle.map { String($0.prefix(maximumFirstPromptCharacters)) },
            nativeTitleIsUserRenamed: resolvedNative.isUserRenamed ? true : nil
        )
    }

    nonisolated private static func parseTranscript(
        data: Data,
        session: AgentHistorySession,
        sourceWasTruncated: Bool = false
    ) -> AgentHistoryTranscript {
        var offset = 0
        return parseTranscript(session: session, sourceWasTruncated: sourceWasTruncated) {
            guard offset < data.count else { return nil }
            let end = min(offset + 256 * 1_024, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    nonisolated private static func parseTranscript(for session: AgentHistorySession) -> AgentHistoryTranscript {
        let url = URL(fileURLWithPath: session.sourcePath)
        guard let reader = TranscriptByteReader(url: url) else {
            return .init(sessionID: session.id, messages: [], wasTruncated: false)
        }
        defer { reader.close() }
        return parseTranscript(session: session) { reader.read(upToCount: 256 * 1_024) }
    }

    nonisolated static func parseTranscript(
        session: AgentHistorySession,
        sourceWasTruncated: Bool = false,
        readChunk: () -> Data?
    ) -> AgentHistoryTranscript {
        let agent = session.agent
        var filter = ConversationRecordFilter(agent: agent)
        var builder = TranscriptBuilder(session: session)
        var branches = ConversationBranches(agent: agent)
        func take(_ record: [String: Any]) -> Bool {
            guard let message = parsedMessage(from: record, agent: agent, keepingUserPastes: true) else { return true }
            guard branches.isTracking else { return builder.append(message) }
            branches.hold(message, entry: record["id"] as? String)
            return true
        }
        let scan = scanJSONLines(
            maximumBytes: maximumTranscriptBytes,
            readChunk: readChunk,
            oversized: { branches.note(line: $0) },
            visit: { line in
                guard let record = conversationRecord(line, agent: agent, branches: &branches) else { return true }
                return filter.consume(record).allSatisfy(take)
            }
        )
        if let pending = filter.finish(isComplete: scan.reachedEnd && !sourceWasTruncated) {
            _ = take(pending)
        }
        for message in branches.activeMessages() where !builder.append(message) { break }
        return .init(sessionID: session.id, messages: builder.messages,
                     wasTruncated: scan.wasTruncated || sourceWasTruncated || builder.wasTruncated || filter.wasTruncated)
    }

    /// One conversation turn taken from a stored record.
    struct ParsedMessage {
        let role: AgentHistoryMessageRole
        let text: String
        let timestamp: Date?
        /// Codex writes one answer as several records of the same turn.
        let turnID: String?
    }

    nonisolated private static func parsedMessage(
        from record: [String: Any], agent: SupportedAgent, keepingUserPastes: Bool
    ) -> ParsedMessage? {
        guard let role = role(of: record, agent: agent),
              let cleaned = text(of: record, role: role, keepingUserPastes: keepingUserPastes),
              !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return nil }
        let payload = record["payload"] as? [String: Any]
        let metadata = payload?["internal_chat_message_metadata_passthrough"] as? [String: Any]
        return .init(role: role, text: cleaned, timestamp: timestamp(of: record),
                     turnID: agent == .codex ? metadata?["turn_id"] as? String : nil)
    }

    private struct TranscriptBuilder {
        let session: AgentHistorySession
        var messages: [AgentHistoryMessage] = []
        var characterCount = 0
        var lastTurnID: String?
        var wasTruncated = false

        mutating func append(_ parsed: ParsedMessage) -> Bool {
            let role = parsed.role
            // An Agent narrates between tool calls, so one reply arrives as
            // several records. A transcript reads as turns: they join until
            // the user speaks again, or until a reply is as long as one row
            // may be. Codex marks its turns, so only a turn's own parts join.
            let sameTurn = session.agent != .codex || parsed.turnID == lastTurnID
            var merge = role == .assistant && messages.last?.role == .assistant && sameTurn
            if merge, session.agent != .codex, let last = messages.last,
               last.text.count + parsed.text.count + 2 > AgentHistoryStore.maximumMessageCharacters {
                merge = false
            }
            let previous = merge ? messages.last : nil
            let separator = previous == nil ? "" : "\n\n"
            let existing = previous?.text ?? ""
            let remaining = min(AgentHistoryStore.maximumMessageCharacters - existing.count,
                                AgentHistoryStore.maximumTranscriptCharacters - characterCount)
            guard merge || messages.count < AgentHistoryStore.maximumTranscriptMessages,
                  remaining > separator.count else {
                wasTruncated = true
                return false
            }
            let value = String(parsed.text.prefix(remaining - separator.count))
            if value.count < parsed.text.count { wasTruncated = true }
            let message = AgentHistoryMessage(
                id: previous?.id ?? "\(session.id):\(messages.count)", role: role,
                text: existing + separator + value,
                timestamp: previous?.timestamp ?? parsed.timestamp
            )
            if merge { messages[messages.count - 1] = message } else { messages.append(message) }
            characterCount += separator.count + value.count
            lastTurnID = parsed.turnID
            return true
        }
    }

    nonisolated private static func scanRemote(
        access: AgentHistoryRemoteAccess,
        agents: [SupportedAgent],
        maximumSessions: Int,
        updatedAfter: Date? = nil
    ) async -> [AgentHistorySession] {
        guard maximumSessions > 0, !Task.isCancelled else { return [] }

        var roots: [String] = []
        for agent in agents {
            for rel in relativeRoots(for: agent) where !roots.contains(rel) {
                roots.append(rel)
            }
        }
        guard !roots.isEmpty else { return [] }

        guard let chunks = try? await access.discoverSessions(
            relativeRoots: roots,
            maximumSessions: maximumSessions,
            updatedAfter: updatedAfter
        ) else { return [] }
        return remoteSessions(
            from: chunks, access: access, agents: agents,
            maximumSessions: maximumSessions, updatedAfter: updatedAfter
        )
    }

    /// Sessions described by what a host sent back, newest first.
    nonisolated private static func remoteSessions(
        from chunks: [AgentHistoryRemoteChunk],
        access: AgentHistoryRemoteAccess,
        agents: [SupportedAgent],
        maximumSessions: Int,
        updatedAfter: Date?
    ) -> [AgentHistorySession] {
        var sessionsByID: [String: AgentHistorySession] = [:]
        for chunk in chunks.sorted(by: { $0.file.modifiedAt > $1.file.modifiedAt }) {
            guard !Task.isCancelled, sessionsByID.count < maximumSessions else { break }
            if let updatedAfter, chunk.file.modifiedAt < updatedAfter { continue }
            let records = headerRecords(from: chunk.headerData)
            guard !records.isEmpty else { continue }

            guard let matchedAgent = agents.first(where: { agent in
                relativeRoots(for: agent).contains { rel in
                    chunk.file.path.contains("/" + rel + "/") || chunk.file.path.contains("/" + rel)
                }
            }) else { continue }

            let pattern = matchedAgent.definition.resume.store?.entryPattern
            let idKeyPath = matchedAgent.definition.resume.discover?.idKeyPath
            let cwdKeyPath = matchedAgent.definition.resume.discover?.cwdKeyPath

            let filenameID: AgentConversationID?
            if let pattern {
                let filename = URL(fileURLWithPath: chunk.file.path).lastPathComponent
                filenameID = id(from: filename, pattern: pattern).flatMap(AgentConversationID.init)
            } else {
                filenameID = conversationIDFromRemoteFilename(chunk.file.path)
            }

            let metadataID: AgentConversationID? = if let idKeyPath {
                records.lazy.compactMap {
                    stringValue(at: idKeyPath, in: $0).flatMap(AgentConversationID.init)
                }.first
            } else {
                records.lazy.compactMap { record in
                    if let value = record["sessionId"] as? String {
                        return AgentConversationID(value)
                    }
                    guard record["type"] as? String == "session",
                          let value = record["id"] as? String else { return nil }
                    return AgentConversationID(value)
                }.first
            }
            // Remote stores have legitimate variants such as `session.jsonl`
            // and `__advisor.jsonl` whose filename does not encode the real
            // conversation ID. Validated metadata is authoritative remotely;
            // filename parsing is only a fallback for truncated Codex headers.
            guard let conversationID = metadataID ?? filenameID else {
                continue
            }

            let configuredCwd = cwdKeyPath.flatMap { keyPath in
                records.lazy.compactMap { stringValue(at: keyPath, in: $0) }.first
            }
            let workingDirectory = validWorkingDirectory(
                configuredCwd ?? records.lazy.compactMap { record in
                    stringValue(at: "cwd", in: record) ??
                        stringValue(at: "payload.cwd", in: record)
                }.first
            )
            let explicitTitle = records.reduce(nil as String?) { current, record in
                guard let type = record["type"] as? String,
                      ["title", "title_change", "session", "session_info"].contains(type),
                      let title = record["title"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return current
                }
                return title
            }
            let userTitle = records.lazy.compactMap { record -> String? in
                guard role(of: record, agent: matchedAgent) == .user else { return nil }
                return text(of: record, role: .user)
            }.compactMap { cleaned -> String? in
                guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return nil }
                return cleaned
            }.first
            let title = normalizedTitle(
                explicitTitle ?? userTitle,
                workingDirectory: workingDirectory,
                conversationID: conversationID
            )
            let previewSnippet = conversationRecords(records, agent: matchedAgent, isComplete: false).lazy.compactMap { record -> String? in
                guard let role = role(of: record, agent: matchedAgent),
                      let cleaned = text(of: record, role: role) else { return nil }
                return cleaned.isEmpty || cleaned == "[Image/Attachment]"
                    ? nil
                    : String(cleaned.prefix(1_000))
            }.prefix(10).joined(separator: "\n")

            let resolvedNative = nativeTitle(in: records, agent: matchedAgent, explicitTitle: explicitTitle)
            let session = AgentHistorySession(
                agent: matchedAgent,
                conversationID: conversationID,
                title: title,
                workingDirectory: workingDirectory,
                updatedAt: chunk.file.modifiedAt,
                sourcePath: chunk.file.path,
                remoteHost: access.alias,
                isActive: false,
                previewSnippet: previewSnippet.isEmpty ? nil : previewSnippet,
                nativeTitle: resolvedNative.title,
                firstPrompt: userTitle.map { String($0.prefix(maximumFirstPromptCharacters)) },
                nativeTitleIsUserRenamed: resolvedNative.isUserRenamed ? true : nil
            )
            if let existing = sessionsByID[session.id],
               existing.updatedAt >= session.updatedAt {
                continue
            }
            sessionsByID[session.id] = session
        }

        return sessionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    nonisolated private static func conversationIDFromRemoteFilename(
        _ path: String
    ) -> AgentConversationID? {
        let name = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        guard name.count >= 36 else { return nil }
        return AgentConversationID(String(name.suffix(36)))
    }

    nonisolated private static func relativeRoots(for agent: SupportedAgent) -> [String] {
        let resume = agent.definition.resume
        guard !resume.resumeArguments.isEmpty else { return [] }
        var values: [String] = []
        for rawPath in [resume.discover?.root ?? resume.store?.root] + (resume.discover?.additionalRoots ?? []) {
            guard let rawPath, let relative = relativePath(rawPath), !values.contains(relative) else { continue }
            values.append(relative)
        }
        return values
    }

    nonisolated private static func relativePath(_ rawPath: String) -> String? {
        if rawPath.hasPrefix("~/") {
            return String(rawPath.dropFirst(2))
        } else if rawPath.hasPrefix("~") {
            return String(rawPath.dropFirst(1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }

    /// Streams a bounded prefix of a zstd-compressed transcript. The helper is
    /// external because compression libs ship zstd only with newer SDKs; when
    /// it is unavailable the archived session is skipped rather than listed
    /// without metadata.
    /// GUI processes inherit a minimal PATH, so Homebrew's zstd is invisible to
    /// `/usr/bin/env`. Resolve an absolute executable once.
    nonisolated private static let zstdExecutable: URL? = {
        let fixed = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        if let path = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/zstd"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }()

    nonisolated private static func decompressedHeader(
        at url: URL,
        maximumBytes: Int
    ) -> Data {
        guard maximumBytes > 0, let executable = zstdExecutable else { return Data() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--decompress", "--stdout", "--quiet", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard let exit = ProcessExit(running: process) else { return Data() }
        var data = Data()
        let handle = pipe.fileHandleForReading
        while data.count < maximumBytes {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk.prefix(maximumBytes - data.count))
        }
        try? handle.close()
        exit.stopAndWait()
        return data
    }

    /// Starts a helper process and later waits for it to exit.
    /// `Process.waitUntilExit` polls a run loop, which on a worker thread
    /// costs about ten milliseconds a call; over thousands of archives that
    /// was a quarter of a scan. The termination handler returns at once.
    private struct ProcessExit {
        private let process: Process
        private let exited = DispatchSemaphore(value: 0)

        init?(running process: Process) {
            self.process = process
            process.terminationHandler = { [exited] _ in exited.signal() }
            guard (try? process.run()) != nil else { return nil }
        }

        func stopAndWait() {
            if process.isRunning { process.terminate() }
            // The process is already signalled; the timeout only keeps a
            // scan from hanging on a handler that never arrives.
            _ = exited.wait(timeout: .now() + 5)
        }
    }

    nonisolated private static func headerRecords(from data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
    }

    /// Codex archives older rollouts as `rollout-….jsonl.zst`. They hold the
    /// same JSONL records, so only the transport differs.
    nonisolated private static func isTranscript(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
    }

    nonisolated private static func headerSnapshot(
        at url: URL,
        maximumBytes: Int
    ) -> (records: [[String: Any]], isComplete: Bool) {
        guard maximumBytes > 0 else { return ([], false) }
        if url.lastPathComponent.lowercased().hasSuffix(".zst") {
            // The first prompt follows the session's base instructions, which
            // alone can exceed 64 KB. Starting zstd dominates the cost, so a
            // larger prefix is nearly free.
            let limit = min(maximumBytes, 1_024 * 1_024)
            let data = decompressedHeader(at: url, maximumBytes: limit)
            return (headerRecords(from: data), data.count < limit)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? handle.close() }
        var data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        let size = try? handle.seekToEnd()
        let isComplete = size.map { $0 <= UInt64(data.count) } ?? false
        if let size, !isComplete {
            if let newline = data.lastIndex(of: 0x0A) { data = Data(data[...newline]) }
            try? handle.seek(toOffset: size > 128 * 1_024 ? size - 128 * 1_024 : 0)
            let tail = (try? handle.readToEnd()) ?? Data()
            for line in tail.split(separator: 0x0A).dropFirst() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let kind = record["type"] as? String,
                      ["session_info", "title", "title_change", "ai-title", "custom-title"].contains(kind) else { continue }
                data.append(0x0A)
                data.append(contentsOf: line)
            }
        }
        return (data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }, isComplete)
    }

    nonisolated private static func firstTranscriptMatch(
        at url: URL,
        query: String,
        agent: SupportedAgent
    ) -> String? {
        guard let reader = TranscriptByteReader(url: url) else { return nil }
        defer { reader.close() }
        return firstTranscriptMatch(query: query, agent: agent) { reader.read(upToCount: 64 * 1_024) }
    }

    /// Reads transcript bytes in chunks. A `.zst` archive is streamed through
    /// zstd, so a reader that stops early never decompresses the remainder.
    private final class TranscriptByteReader {
        private let handle: FileHandle
        private let exit: ProcessExit?

        init?(url: URL) {
            guard url.lastPathComponent.lowercased().hasSuffix(".zst") else {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                self.handle = handle
                exit = nil
                return
            }
            guard let executable = AgentHistoryStore.zstdExecutable else { return nil }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--decompress", "--stdout", "--quiet", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard let exit = ProcessExit(running: process) else { return nil }
            handle = pipe.fileHandleForReading
            self.exit = exit
        }

        func read(upToCount count: Int) -> Data? {
            try? handle.read(upToCount: count)
        }

        func close() {
            try? handle.close()
            exit?.stopAndWait()
        }
    }

    nonisolated static func firstTranscriptMatch(
        query: String, agent: SupportedAgent, readChunk: () -> Data?
    ) -> String? {
        var filter = ConversationRecordFilter(agent: agent)
        var branches = ConversationBranches(agent: agent)
        var match: String?
        func findMatch(_ record: [String: Any]) -> Bool {
            guard let role = role(of: record, agent: agent), let cleaned = text(of: record, role: role),
                  let range = cleaned.range(of: query, options: .caseInsensitive) else { return true }
            match = searchSnippet(cleaned, around: range)
            return false
        }
        let scan = scanJSONLines(readChunk: readChunk, visit: { line in
            guard let record = conversationRecord(line, agent: agent, branches: &branches) else { return true }
            return filter.consume(record).allSatisfy(findMatch)
        })
        if match == nil, let pending = filter.finish(isComplete: scan.reachedEnd) { _ = findMatch(pending) }
        return match
    }

    /// Decodes a line only when it can carry a conversation turn or a marker
    /// the reader depends on. Tool output is most of a session file; skipping
    /// its JSON decode is what keeps a long session quick to open.
    nonisolated private static func conversationRecord(
        _ line: Data, agent: SupportedAgent, branches: inout ConversationBranches
    ) -> [String: Any]? {
        let family = RecordFamily(agent)
        if !contains(line, "\"user\""), !contains(line, "\"assistant\"") {
            switch family {
            case .codex:
                // The compaction filter resolves a pending answer on the next
                // response item; it does not need that item's content.
                if contains(line, "\"response_item\"") { return ["type": "response_item"] }
                guard contains(line, "\"token_usage_record\"") || contains(line, "\"compacted\"") ||
                    contains(line, "\"turn_context\"") || contains(line, "\"task_complete\"") ||
                    contains(line, "\"turn_aborted\"") else { return nil }
            case .pi:
                branches.note(line: line)
                return nil
            case .claude, .generic:
                return nil
            }
        }
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if family == .pi {
            branches.note(id: record["id"] as? String, parent: record["parentId"] as? String)
        }
        return record
    }

    nonisolated private static func contains(_ data: Data, _ needle: StaticString) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return needle.withUTF8Buffer { memmem(base, buffer.count, $0.baseAddress, $0.count) != nil }
        }
    }

    /// Returns whether input was cut short or an oversized record was skipped.
    /// Readers can stop on a match without scanning the rest of a session.
    /// `oversized` receives the head of a record too large to decode.
    nonisolated private static func scanJSONLines(
        maximumBytes: Int = Int.max,
        readChunk: () -> Data?,
        oversized: (Data) -> Void = { _ in },
        visit: (Data) -> Bool
    ) -> (wasTruncated: Bool, reachedEnd: Bool) {
        var leftover = Data()
        var discardingLine = false
        var truncated = false
        var count = 0
        while !Task.isCancelled, let chunk = readChunk(), !chunk.isEmpty {
            guard count < maximumBytes else { return (true, false) }
            let available = chunk.prefix(maximumBytes - count)
            count += available.count
            let buffer = leftover + available
            leftover = Data()
            var stopped = false
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                    let end = base.distance(to: newline)
                    let length = end - start
                    if !discardingLine && length <= maximumRecordBytes {
                        // The visitor decodes within the call and keeps nothing.
                        let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                        count: length, deallocator: .none)
                        if length > 0, !visit(line) {
                            stopped = true
                            return
                        }
                    } else {
                        if !discardingLine { oversized(Data(bytes: base + start, count: min(length, 512))) }
                        truncated = true
                    }
                    discardingLine = false
                    start = end + 1
                }
                let rest = raw.count - start
                if rest > maximumRecordBytes {
                    if !discardingLine { oversized(Data(bytes: base + start, count: 512)) }
                    discardingLine = true
                    truncated = true
                } else if !discardingLine, rest > 0 {
                    leftover = Data(bytes: base + start, count: rest)
                }
            }
            if stopped { return (true, false) }
            if available.count < chunk.count { return (true, false) }
        }
        guard !Task.isCancelled else { return (true, false) }
        if !discardingLine && !leftover.isEmpty && !visit(leftover) { return (true, false) }
        return (truncated, true)
    }

    nonisolated static func searchSnippet(
        _ text: String,
        around range: Range<String.Index>
    ) -> String {
        // A result row shows two short lines, so the match sits near the
        // start with most of the context after it.
        let start = text.index(
            range.lowerBound,
            offsetBy: -28,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            range.upperBound,
            offsetBy: 150,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let value = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > text.startIndex ? "…" : "") + value +
            (end < text.endIndex ? "…" : "")
    }

    // Defer only Codex records that can be compaction summaries, until the next
    // response item or its compaction marker resolves them. No file pre-pass.
    private struct ConversationRecordFilter {
        let agent: SupportedAgent
        var pending: [String: Any]?
        var responseID: String?
        var wasTruncated = false

        mutating func consume(_ record: [String: Any]) -> [[String: Any]] {
            guard agent == .codex else { return [record] }
            let payload = record["payload"] as? [String: Any] ?? [:]
            let type = record["type"] as? String
            if type == "compacted", let responseID,
               payload["compaction_response_id"] as? String == responseID {
                pending = nil
                self.responseID = nil
                return []
            }
            if type == "token_usage_record", let pending,
               let metadata = (pending["payload"] as? [String: Any])?["internal_chat_message_metadata_passthrough"] as? [String: Any],
               let turnID = metadata["turn_id"] as? String, payload["turn_id"] as? String == turnID {
                responseID = payload["response_id"] as? String
            }
            var result: [[String: Any]] = []
            let completedTurn = type == "event_msg" &&
                ["task_complete", "turn_aborted"].contains(payload["type"] as? String ?? "")
            if type == "response_item" || type == "turn_context" || completedTurn || AgentHistoryStore.role(of: record, agent: agent) == .user {
                if let pending { result.append(pending) }
                pending = nil
                responseID = nil
            }
            if type == "response_item", payload["type"] as? String == "message",
               payload["role"] as? String == "assistant", payload["phase"] as? String != "commentary",
               payload["id"] is String,
               let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
               metadata["turn_id"] is String {
                pending = record
            } else {
                result.append(record)
            }
            return result
        }

        mutating func finish(isComplete: Bool) -> [String: Any]? {
            defer { pending = nil; responseID = nil }
            guard isComplete else {
                if pending != nil { wasTruncated = true }
                return nil
            }
            return pending
        }
    }

    /// Pi and OMP store a conversation as a tree: retrying a turn or editing
    /// a prompt starts a sibling branch. Only the branch that ends at the
    /// newest entry is the conversation; the others repeat or contradict it.
    private struct ConversationBranches {
        let isTracking: Bool
        private var parents: [String: String] = [:]
        private var newest: String?
        private var held: [(entry: String?, message: ParsedMessage)] = []

        init(agent: SupportedAgent) {
            isTracking = RecordFamily(agent) == .pi
        }

        mutating func note(id: String?, parent: String?) {
            guard isTracking, let id else { return }
            if let parent { parents[id] = parent }
            newest = id
        }

        /// Links an entry that is not decoded as a turn. Message entries,
        /// which hold the large tool results, start with their identifiers;
        /// anything else is small enough to decode.
        mutating func note(line: Data) {
            guard isTracking else { return }
            // The head can end inside a multi-byte character; ASCII keys do not.
            let head = String(bytes: line.prefix(160), encoding: .isoLatin1) ?? ""
            let prefix = "{\"type\":\"message\",\"id\":\""
            if head.hasPrefix(prefix) {
                let rest = head.dropFirst(prefix.count)
                guard let idEnd = rest.firstIndex(of: "\"") else { return }
                let id = String(rest[..<idEnd])
                let after = rest[rest.index(after: idEnd)...]
                let parentPrefix = ",\"parentId\":\""
                var parent: String?
                if after.hasPrefix(parentPrefix) {
                    let value = after.dropFirst(parentPrefix.count)
                    parent = value.firstIndex(of: "\"").map { String(value[..<$0]) }
                }
                note(id: id, parent: parent)
            } else if line.count <= 512 * 1_024,
                      let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                note(id: record["id"] as? String, parent: record["parentId"] as? String)
            }
        }

        mutating func hold(_ message: ParsedMessage, entry: String?) {
            held.append((entry, message))
        }

        /// The held turns on the newest entry's branch, in file order. A turn
        /// without an identifier predates the tree format and is kept.
        func activeMessages() -> [ParsedMessage] {
            guard isTracking else { return [] }
            var active = Set<String>()
            var cursor = newest
            while let id = cursor, active.insert(id).inserted { cursor = parents[id] }
            return held.filter { $0.entry.map(active.contains) ?? true }.map(\.message)
        }
    }

    nonisolated private static func conversationRecords(
        _ records: [[String: Any]], agent: SupportedAgent, isComplete: Bool
    ) -> [[String: Any]] {
        var filter = ConversationRecordFilter(agent: agent)
        var result = records.flatMap { filter.consume($0) }
        if let pending = filter.finish(isComplete: isComplete) { result.append(pending) }
        return result
    }

    /// How an Agent's records name a conversation turn.
    enum RecordFamily: Equatable {
        /// Claude Code and its forks: `type` is the role; flags mark records
        /// the Agent wrote for itself.
        case claude
        /// Codex: turns are `response_item` messages.
        case codex
        /// Pi and OMP: turns are `message` entries of a tree.
        case pi
        /// Any other store: the role wherever a record declares one.
        case generic

        init(_ agent: SupportedAgent) {
            switch agent {
            case .claude, .qoder: self = .claude
            case .codex: self = .codex
            case .pi, .omp: self = .pi
            default: self = .generic
            }
        }
    }

    /// Records Claude Code writes around a conversation rather than in it:
    /// skill bodies, sub-agent turns, compaction summaries, API failures.
    nonisolated private static let claudeBookkeepingFlags = [
        "isMeta", "isSidechain", "isCompactSummary", "isApiErrorMessage",
    ]

    /// The role of a record that is a turn of the conversation, else nil.
    /// A store also logs requests, tool traffic and bookkeeping that carry a
    /// `role` of their own, so each family names its turns explicitly.
    nonisolated static func role(
        of record: [String: Any], agent: SupportedAgent
    ) -> AgentHistoryMessageRole? {
        func parsed(_ raw: Any?) -> AgentHistoryMessageRole? {
            switch (raw as? String)?.lowercased() {
            case "user": return .user
            case "assistant": return .assistant
            default: return nil
            }
        }
        let type = record["type"] as? String
        switch RecordFamily(agent) {
        case .claude:
            guard let role = parsed(type),
                  !claudeBookkeepingFlags.contains(where: { record[$0] as? Bool == true }) else { return nil }
            return role
        case .codex:
            // Tool calls and reasoning are response items too, without a role.
            guard type == "response_item", let payload = record["payload"] as? [String: Any],
                  (payload["type"] as? String).map({ $0 == "message" }) ?? true else { return nil }
            return parsed(payload["role"])
        case .pi:
            guard type == "message" else { return nil }
            return parsed((record["message"] as? [String: Any])?["role"])
        case .generic:
            return parsed((record["message"] as? [String: Any])?["role"] ??
                (record["payload"] as? [String: Any])?["role"] ??
                record["role"] ?? type)
        }
    }

    /// - Parameter keepingUserPastes: Keeps the body of a `<pasted_content>`
    ///   wrapper. Transcripts show what the user actually pasted, while titles
    ///   and previews drop the wrapper so the surrounding request surfaces.
    nonisolated private static func text(
        of record: [String: Any], role: AgentHistoryMessageRole, keepingUserPastes: Bool = false
    ) -> String? {
        let filterInjected = role == .user
        if let message = record["message"] as? [String: Any],
           let text = text(from: message["content"], filterInjected: filterInjected,
                           keepingUserPastes: keepingUserPastes) {
            return text
        }
        if let payload = record["payload"] as? [String: Any],
           let text = text(from: payload["content"], filterInjected: filterInjected,
                           keepingUserPastes: keepingUserPastes) {
            return text
        }
        if let text = text(from: record["content"], filterInjected: filterInjected,
                           keepingUserPastes: keepingUserPastes) {
            return text
        }
        if let humanInput = record["humanInput"] as? [String: Any],
           let text = humanInput["text"] as? String {
            return cleanMeaningfulText(text, keepingUserPastes: keepingUserPastes)
        }
        return nil
    }

    nonisolated private static func text(
        from value: Any?, filterInjected: Bool, keepingUserPastes: Bool
    ) -> String? {
        func cleaned(_ value: String) -> String {
            filterInjected
                ? cleanMeaningfulText(value, keepingUserPastes: keepingUserPastes)
                : removingLeadingReasoning(value)
        }
        if let value = value as? String { return cleaned(value) }
        guard let values = value as? [Any] else { return nil }
        let parts = values.compactMap { item -> String? in
            if let item = item as? String { return cleaned(item) }
            guard let item = item as? [String: Any], let text = item["text"] as? String else { return nil }
            return cleaned(text)
        }.filter { !$0.isEmpty && $0 != "[Image/Attachment]" }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated private static func timestamp(
        of record: [String: Any]
    ) -> Date? {
        if let raw = record["timestamp"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = fractional.date(from: raw) { return value }
            if let value = ISO8601DateFormatter().date(from: raw) { return value }
        }
        if let milliseconds = (record["message"] as? [String: Any])?["timestamp"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        return nil
    }

    nonisolated private static func stringValue(
        at keyPath: String,
        in object: [String: Any]
    ) -> String? {
        var current: Any = object
        for key in keyPath.split(separator: ".") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[String(key)] else { return nil }
            current = next
        }
        return current as? String
    }

    nonisolated private static func id(
        from relativePath: String,
        pattern: String
    ) -> String? {
        guard let range = pattern.range(of: "{id}") else { return nil }
        let usesPath = pattern.contains("/")
        var target = usesPath
            ? relativePath
            : URL(fileURLWithPath: relativePath).lastPathComponent
        let before = String(pattern[..<range.lowerBound])
            .split(separator: "*", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let after = String(pattern[range.upperBound...])
            .split(separator: "*", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard target.hasSuffix(after) else { return nil }
        if !after.isEmpty { target.removeLast(after.count) }
        if !before.isEmpty {
            guard let beforeRange = target.range(of: before, options: .backwards) else {
                return nil
            }
            target = String(target[beforeRange.upperBound...])
        }
        return target.isEmpty ? nil : target
    }

    nonisolated private static func relativePath(
        of url: URL,
        under root: URL
    ) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    nonisolated static func validWorkingDirectory(
        _ value: String?
    ) -> String? {
        guard let value,
              !value.isEmpty,
              !value.contains("\0"),
              value.utf8.count <= 4_096 else { return nil }
        return value
    }

    /// Wrapper names that agents inject into user content blocks.
    nonisolated private static let injectedWrapperNames: Set<String> = [
        "local-command-caveat", "command-name", "command-message", "command-args",
        "local-command-stdout", "system-reminder", "external_codex_apps_open_page",
        "recommended_plugins", "environment_context", "instructions", "pasted_content",
        "skills_instructions", "model_switch", "codex_apps_client_time_context",
        "task-notification", "turn_aborted", "codex_internal_context", "user_instructions",
        "subagent_notification", "user_shell_command", "skill",
    ]

    /// Wrapper families whose tag name carries a generated suffix.
    nonisolated private static let injectedWrapperPrefixes: [String] = [
        "external_codex_apps_selected_page_part",
    ]

    /// A leading injected wrapper and the tags that delimit it.
    nonisolated private struct InjectedWrapper {
        let name: String
        let opening: Range<String.Index>
        let closing: Range<String.Index>?

        var isUserPaste: Bool { name == "pasted_content" }
    }

    /// Finds the injected wrapper that starts a user content block, if any.
    nonisolated private static func leadingInjectedWrapper(
        in text: String
    ) -> InjectedWrapper? {
        guard text.hasPrefix("<"), let openEnd = text.range(of: ">") else { return nil }
        let opening = text[text.index(after: text.startIndex)..<openEnd.lowerBound]
        let name = opening.prefix { !$0.isWhitespace && $0 != "/" }
        guard !name.isEmpty, isInjectedWrapper(String(name)) else { return nil }
        let openingRange = text.startIndex..<openEnd.upperBound
        guard let match = text[openEnd.upperBound...].range(of: "</\(name)", options: .caseInsensitive),
              let closingEnd = closingTagEnd(in: text, after: match.upperBound) else {
            return .init(name: String(name), opening: openingRange, closing: nil)
        }
        return .init(name: String(name), opening: openingRange,
                     closing: match.lowerBound..<closingEnd)
    }

    /// Confirms that a closing match is the wrapper itself, not a longer name,
    /// and returns the index just after its `>`.
    nonisolated private static func closingTagEnd(
        in text: String, after index: String.Index
    ) -> String.Index? {
        if index < text.endIndex {
            let character = text[index]
            guard character == ">" || character == "/" || character.isWhitespace else {
                return nil
            }
        }
        return text.range(of: ">", range: index..<text.endIndex)?.upperBound
    }

    nonisolated private static func isInjectedWrapper(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return injectedWrapperNames.contains(lowered) ||
            injectedWrapperPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Removes `<pasted_content>` wrappers wherever they appear. The user can
    /// type a character before pasting, so the wrapper is not always at the
    /// start of the content block.
    nonisolated private static func removingUserPasteWrappers(
        in text: String, keepingBody: Bool
    ) -> String {
        guard containsIgnoringASCIICase(text, "<pasted_content") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var output = ""
        var cursor = text.startIndex
        var searchStart = text.startIndex
        while let opening = text.range(of: "<pasted_content", options: .caseInsensitive,
                                      range: searchStart..<text.endIndex) {
            guard let openEnd = text.range(of: ">", range: opening.upperBound..<text.endIndex),
                  isWrapperTagEnd(text, after: opening.upperBound, before: openEnd.lowerBound) else {
                searchStart = opening.upperBound
                continue
            }
            guard let closing = text.range(of: "</pasted_content", options: .caseInsensitive,
                                             range: openEnd.upperBound..<text.endIndex),
                  let closeEnd = closingTagEnd(in: text, after: closing.upperBound) else {
                searchStart = openEnd.upperBound
                continue
            }
            var start = opening.lowerBound
            var end = closeEnd
            if !keepingBody {
                // Quotes around a paste become orphans once the body is gone.
                start = orphanQuoteStart(in: text, before: start)
                end = orphanQuoteEnd(in: text, after: end)
            }
            output += text[cursor..<start]
            if keepingBody {
                output += text[openEnd.upperBound..<closing.lowerBound]
            }
            cursor = end
            searchStart = closeEnd
        }
        output += text[cursor...]
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Confirms that an opening match is the paste tag itself.
    nonisolated private static func isWrapperTagEnd(
        _ text: String, after nameEnd: String.Index, before tagEnd: String.Index
    ) -> Bool {
        guard nameEnd < tagEnd else { return false }
        let character = text[nameEnd]
        return character == ">" || character == "/" || character.isWhitespace
    }

    /// Extends a removal backwards over whitespace and a single orphan quote.
    nonisolated private static func orphanQuoteStart(
        in text: String, before index: String.Index
    ) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous].isWhitespace {
                cursor = previous
                continue
            }
            guard orphanQuotes.contains(text[previous]) else { break }
            return previous
        }
        return index
    }

    /// Extends a removal forwards over whitespace and a single orphan quote.
    nonisolated private static func orphanQuoteEnd(
        in text: String, after index: String.Index
    ) -> String.Index {
        var cursor = index
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
                continue
            }
            guard orphanQuotes.contains(text[cursor]) else { break }
            return text.index(after: cursor)
        }
        return index
    }

    nonisolated private static let orphanQuotes: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "`",
    ]

    nonisolated static func cleanMeaningfulText(_ raw: String) -> String {
        cleanMeaningfulText(raw, keepingUserPastes: false)
    }

    /// Removes machine-injected wrappers from a user content block.
    ///
    /// Agents emit these wrappers with a fixed name, a generated suffix, or
    /// extra attributes, so the opening and closing forms must both be matched
    /// by name. A user's own paste keeps its body when the caller asks for it.
    nonisolated static func cleanMeaningfulText(
        _ raw: String, keepingUserPastes: Bool
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if interruptionMarkers.contains(text) { return "" }
        text = collapsingSkillInvocation(text)
        // Only remove these wrappers at the beginning of a user content block.
        // Inline quotations, fenced examples and assistant answers are content.
        while let wrapper = leadingInjectedWrapper(in: text) {
            // A paste is handled below so its body and the quotes around it
            // stay consistent wherever the wrapper appears.
            if wrapper.isUserPaste { break }
            let end = wrapper.closing?.upperBound ?? wrapper.opening.upperBound
            text = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = removingUserPasteWrappers(in: text, keepingBody: keepingUserPastes)
        var output: [String] = []
        var prose: [String] = []
        var fence: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let currentFence = fence {
                output.append(line)
                if trimmed.hasPrefix(currentFence),
                   trimmed.drop(while: { $0 == currentFence.first })
                    .trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            let marker = trimmed.first
            let run = trimmed.prefix { $0 == marker }
            if (marker == "`" || marker == "~") && run.count >= 3 {
                if !prose.isEmpty { output.append(cleanUserProse(prose.joined(separator: "\n"))); prose = [] }
                output.append(line)
                fence = String(run)
            } else {
                prose.append(line)
            }
        }
        if !prose.isEmpty { output.append(cleanUserProse(prose.joined(separator: "\n"))) }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Some models write their reasoning into the answer as a leading
    /// `<thinking>` block. The reply is what follows it.
    nonisolated static func removingLeadingReasoning(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("<thinking>") {
            guard let closing = text.range(of: "</thinking>") else { return "" }
            text = String(text[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Text an Agent records as a user turn when a request is cancelled.
    nonisolated private static let interruptionMarkers: Set<String> = [
        "[Request interrupted by user]", "[Request interrupted by user for tool use]",
    ]

    /// Pi expands a skill command into the skill's whole body. The command is
    /// what the user typed, followed by whatever they wrote after it.
    nonisolated private static func collapsingSkillInvocation(_ text: String) -> String {
        guard text.hasPrefix("<skill "), let openEnd = text.range(of: ">"),
              let closing = text.range(of: "</skill>", range: openEnd.upperBound..<text.endIndex),
              let nameStart = text.range(of: "name=\"", range: text.startIndex..<openEnd.lowerBound),
              let nameEnd = text.range(of: "\"", range: nameStart.upperBound..<openEnd.lowerBound) else {
            return text
        }
        let command = "/skill:" + text[nameStart.upperBound..<nameEnd.lowerBound]
        let rest = text[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? command : command + "\n" + rest
    }

    /// Whether `text` holds `needle`, an ASCII tag opening with a character
    /// that has no letter case such as `<`, in any letter case.
    ///
    /// Foundation's case-insensitive search folds every character it passes;
    /// over a first prompt of several hundred kilobytes, once per tag, that
    /// was the largest cost of a scan. Most text holds none of the tags, and
    /// this rules them out from the bytes.
    nonisolated static func containsIgnoringASCIICase(_ text: String, _ needle: String) -> Bool {
        func lowered(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
        let pattern = needle.utf8.map(lowered)
        guard let first = pattern.first else { return true }
        assert(lowered(first) == first && !(97...122).contains(first))
        var text = text
        return text.withUTF8 { bytes -> Bool in
            guard bytes.count >= pattern.count, let base = bytes.baseAddress else { return false }
            let last = bytes.count - pattern.count
            var offset = 0
            while offset <= last {
                guard let hit = memchr(base + offset, Int32(first), last - offset + 1) else { return false }
                let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                var matches = true
                for index in 1..<pattern.count where lowered(bytes[start + index]) != pattern[index] {
                    matches = false
                    break
                }
                if matches { return true }
                offset = start + 1
            }
            return false
        }
    }

    nonisolated private static func cleanUserProse(_ raw: String) -> String {
        var text = raw
        let blockTags = ["recommended_plugins", "environment_context", "instructions"]
        for tag in blockTags where containsIgnoringASCIICase(text, "<\(tag)>") {
            var searchStart = text.startIndex
            while let startRange = text.range(of: "<\(tag)>", options: .caseInsensitive,
                                             range: searchStart..<text.endIndex),
                  let endRange = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                           range: startRange.upperBound..<text.endIndex) {
                let lineStart = text[..<startRange.lowerBound].lastIndex(of: "\n")
                    .map { text.index(after: $0) } ?? text.startIndex
                if text[lineStart..<startRange.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
                    let offset = text.distance(from: text.startIndex, to: startRange.lowerBound)
                    text.removeSubrange(startRange.lowerBound..<endRange.upperBound)
                    searchStart = text.index(text.startIndex, offsetBy: offset)
                } else {
                    searchStart = endRange.upperBound
                }
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var filtered: [String] = []
        var inInstructionsBlock = false
        var inFilesBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<INSTRUCTIONS>") || trimmed.hasPrefix("<instructions>") {
                inInstructionsBlock = true
                continue
            }
            if inInstructionsBlock {
                if trimmed.hasPrefix("</INSTRUCTIONS>") || trimmed.hasPrefix("</instructions>") {
                    inInstructionsBlock = false
                }
                continue
            }
            if trimmed.hasPrefix("# Files mentioned by the user") || trimmed.hasPrefix("Files mentioned by the user") {
                inFilesBlock = true
                continue
            }
            if inFilesBlock {
                if trimmed.hasPrefix("## ") || TransientAttachmentNoise.isNoise(line: String(line)) {
                    continue
                } else if !trimmed.isEmpty {
                    inFilesBlock = false
                }
            }
            if isMeaninglessPasteOrSystemLine(trimmed) {
                continue
            }
            filtered.append(String(line))
        }
        let result = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isMeaninglessPasteOrSystemLine(fallback) {
                return "[Image/Attachment]"
            }
            return ""
        }
        return result
    }

    nonisolated private static func isMeaninglessPasteOrSystemLine(_ line: String) -> Bool {
        if line.isEmpty { return false }
        let lower = line.lowercased()
        if lower.hasPrefix("# agents.md instructions") || lower.hasPrefix("agents.md instructions") {
            return true
        }
        if line.hasPrefix("@/Users/") && (line.hasSuffix(".md") || line.hasSuffix(".txt")) {
            return true
        }
        if TransientAttachmentNoise.isNoise(line: line) {
            return true
        }
        if line.hasPrefix("<cwd>") || line.hasPrefix("<shell>") ||
            line.hasPrefix("<current_date>") || line.hasPrefix("<timezone>") ||
            line.hasPrefix("<filesystem>") || line.hasPrefix("</filesystem>") ||
            line.hasPrefix("<permission_profile") || line.hasPrefix("</environment_context>") ||
            line.hasPrefix("<image") || line.hasPrefix("</image>") {
            return true
        }
        // Claude Code records where a pasted image was saved.
        if line.hasPrefix("[Image: source: "), line.hasSuffix("]") {
            return true
        }
        return false
    }

    nonisolated static func normalizedTitle(
        _ rawValue: String?,
        workingDirectory: String?,
        conversationID: AgentConversationID
    ) -> String {
        if let rawValue {
            let collapsed = rawValue
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if !collapsed.isEmpty {
                return String(collapsed.prefix(140))
            }
        }
        if let workingDirectory {
            let folder = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !folder.isEmpty { return folder }
        }
        return conversationID.rawValue
    }
}
