import Foundation

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

    var id: String { "\(agent.rawValue):\(conversationID.rawValue)" }
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
    private static let maximumHeaderBytes = 256 * 1_024
    private static let maximumTranscriptBytes = 2 * 1_024 * 1_024
    private static let maximumTranscriptMessages = 500
    private static let maximumTranscriptCharacters = 500_000
    private static let maximumMessageCharacters = 16_000

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
        cacheURL: URL? = nil
    ) async -> [AgentHistorySession] {
        let diskTask = Task.detached(priority: .utility) {
            scan(
                agents: agents,
                rootURLs: rootURLs,
                maximumSessions: maximumSessions,
                cacheURL: cacheURL
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
        maximumSessions: Int = AgentHistoryStore.maximumSessions
    ) async -> [AgentHistorySession] {
        let diskTask = Task.detached(priority: .utility) {
            await scanRemote(
                access: access,
                agents: agents,
                maximumSessions: maximumSessions
            )
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func transcript(
        for session: AgentHistorySession,
        remoteAccess: AgentHistoryRemoteAccess? = nil
    ) async -> AgentHistoryTranscript {
        if let alias = session.remoteHost {
            let access = remoteAccess ?? AgentHistoryRemoteAccess(alias: alias)
            guard let data = try? await access.read(
                path: session.sourcePath,
                maximumBytes: 8 * 1_024 * 1_024
            ) else {
                return .init(
                    sessionID: session.id,
                    messages: [],
                    wasTruncated: false
                )
            }
            return parseTranscript(
                data: data,
                session: session,
                sourceWasTruncated: data.count == 8 * 1_024 * 1_024
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

    /// Searches metadata and complete user/assistant transcript text off the
    /// main actor. Values are bounded snippets used for result highlighting.
    static func search(
        sessions: [AgentHistorySession],
        query: String
    ) async -> [String: String] {
        var latest: [String: String] = [:]
        for await matches in searchUpdates(sessions: sessions, query: query) {
            latest = matches
        }
        return latest
    }

    /// Emits cached metadata/preview matches immediately, then progressively
    /// adds complete transcript matches in recent-session order. A cold deep
    /// search can scan gigabytes, but useful results never wait for the tail.
    static func searchUpdates(
        sessions: [AgentHistorySession],
        query: String
    ) -> AsyncStream<[String: String]> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield([:])
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var matches: [String: String] = [:]

                // Phase 1: title and small metadata only. This intentionally
                // avoids touching multi-kilobyte preview strings so the first
                // result batch can render immediately.
                for session in sessions {
                    guard !Task.isCancelled else { break }
                    let metadata = [
                        session.title,
                        session.agent.rawValue,
                        session.conversationID.rawValue,
                        session.workingDirectory ?? "",
                    ].joined(separator: "\n")
                    guard let range = metadata.range(
                        of: needle,
                        options: .caseInsensitive
                    ) else { continue }
                    matches[session.id] = searchSnippet(
                        metadata,
                        around: range
                    )
                }
                continuation.yield(matches)

                // Phase 2: cached bounded body previews. This still avoids
                // filesystem I/O and usually resolves recent-session queries.
                for session in sessions where matches[session.id] == nil {
                    guard !Task.isCancelled else { break }
                    guard let preview = session.previewSnippet,
                          let range = preview.range(
                              of: needle,
                              options: .caseInsensitive
                          ) else { continue }
                    matches[session.id] = searchSnippet(
                        preview,
                        around: range
                    )
                }
                continuation.yield(matches)

                // Phase 3: complete transcript scan, yielding each newly found
                // match instead of waiting for every historical file.
                for (index, session) in sessions.enumerated() {
                    guard !Task.isCancelled else { break }
                    // Remote full-body search would otherwise open one SSH
                    // process per session. Remote sessions use their bounded
                    // metadata/preview index; local sessions keep deep search.
                    guard session.remoteHost == nil,
                          matches[session.id] == nil else { continue }
                    if let snippet = firstTranscriptMatch(
                        at: URL(fileURLWithPath: session.sourcePath),
                        query: needle
                    ) {
                        matches[session.id] = snippet
                        continuation.yield(matches)
                    } else if index.isMultiple(of: 100) {
                        continuation.yield(matches)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct DiskCache: Codable {
        static let currentVersion = 3
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
        cacheURL: URL? = nil
    ) -> [AgentHistorySession] {
        guard maximumSessions > 0 else { return [] }
        let resolvedCacheURL = cacheURL ?? defaultCacheURL()
        var diskCache: DiskCache = {
            if let data = try? Data(contentsOf: resolvedCacheURL),
               let decoded = try? JSONDecoder().decode(DiskCache.self, from: data),
               decoded.version == DiskCache.currentVersion {
                return decoded
            }
            return DiskCache()
        }()

        var candidates: [Candidate] = []
        var inspectedFiles = 0

        for agent in agents where !Task.isCancelled {
            guard let source = source(for: agent, rootURL: rootURLs[agent]) else {
                continue
            }
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
                guard url.pathExtension.lowercased() == "jsonl",
                      let values = try? url.resourceValues(forKeys: [
                          .contentModificationDateKey,
                          .creationDateKey,
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }

                let filenameID: AgentConversationID?
                if let pattern = source.entryPattern {
                    let relativePath = relativePath(of: url, under: source.root)
                    guard let rawID = id(from: relativePath, pattern: pattern),
                          let id = AgentConversationID(rawID) else { continue }
                    filenameID = id
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

        candidates.sort { $0.updatedAt > $1.updatedAt }
        var sessionsByID: [String: AgentHistorySession] = [:]
        var cacheUpdated = false

        for candidate in candidates.prefix(maximumHeaderCandidates) {
            guard !Task.isCancelled, sessionsByID.count < maximumSessions else { break }
            let candidateMtime = candidate.updatedAt.timeIntervalSince1970

            if let cached = diskCache.entries[candidate.url.path],
               abs(cached.mtime - candidateMtime) < 0.001 {
                let session = cached.session
                if let existing = sessionsByID[session.id], existing.updatedAt >= session.updatedAt {
                    continue
                }
                sessionsByID[session.id] = session
                continue
            }

            guard let session = session(from: candidate) else { continue }
            diskCache.entries[candidate.url.path] = .init(session: session, mtime: candidateMtime)
            cacheUpdated = true

            if let existing = sessionsByID[session.id], existing.updatedAt >= session.updatedAt {
                continue
            }
            sessionsByID[session.id] = session
        }

        if cacheUpdated && !Task.isCancelled {
            try? FileManager.default.createDirectory(
                at: resolvedCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(diskCache) {
                try? data.write(to: resolvedCacheURL, options: .atomic)
            }
        }

        return sessionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    nonisolated private static func source(
        for agent: SupportedAgent,
        rootURL: URL?
    ) -> Source? {
        let resume = agent.definition.resume
        guard !resume.resumeArguments.isEmpty else { return nil }

        if let discovery = resume.discover, discovery.format == .jsonl {
            let root = rootURL ?? URL(fileURLWithPath:
                (discovery.root as NSString).expandingTildeInPath
            )
            return .init(
                agent: agent,
                root: root,
                format: .jsonl,
                entryPattern: nil,
                idKeyPath: discovery.idKeyPath,
                cwdKeyPath: discovery.cwdKeyPath
            )
        }

        guard let store = resume.store,
              store.entryPattern.lowercased().contains(".jsonl") else {
            return nil
        }
        let root = rootURL ?? URL(fileURLWithPath:
            (store.root as NSString).expandingTildeInPath
        )
        return .init(
            agent: agent,
            root: root,
            format: .jsonl,
            entryPattern: store.entryPattern,
            idKeyPath: nil,
            cwdKeyPath: nil
        )
    }

    nonisolated private static func session(
        from candidate: Candidate
    ) -> AgentHistorySession? {
        let records = headerRecords(
            at: candidate.url,
            maximumBytes: maximumHeaderBytes
        )
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
                  ["title", "title_change", "session"].contains(type),
                  let title = record["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return current
            }
            return title
        }
        let userTitle = records.lazy.compactMap { record -> String? in
            guard role(of: record) == .user else { return nil }
            return text(of: record)
        }.compactMap { raw -> String? in
            let cleaned = cleanMeaningfulText(raw)
            guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return nil }
            return cleaned
        }.first
        let title = normalizedTitle(
            explicitTitle ?? userTitle,
            workingDirectory: workingDirectory,
            conversationID: conversationID
        )

        let previewSnippet = records.lazy.compactMap { record -> String? in
            guard let raw = text(of: record) else { return nil }
            let cleaned = cleanMeaningfulText(raw)
            return cleaned.isEmpty || cleaned == "[Image/Attachment]" ? nil : String(cleaned.prefix(1_000))
        }.prefix(10).joined(separator: "\n")

        return .init(
            agent: candidate.source.agent,
            conversationID: conversationID,
            title: title,
            workingDirectory: workingDirectory,
            updatedAt: candidate.updatedAt,
            sourcePath: candidate.url.path,
            isActive: false,
            previewSnippet: previewSnippet.isEmpty ? nil : previewSnippet
        )
    }

    nonisolated private static func parseTranscript(
        data: Data,
        session: AgentHistorySession,
        sourceWasTruncated: Bool = false
    ) -> AgentHistoryTranscript {
        var messages: [AgentHistoryMessage] = []
        var characterCount = 0
        var truncated = sourceWasTruncated
        let delimiter = UInt8(ascii: "\n")
        var messageIndex = 0
        var buffer = data

        while let newlineIndex = buffer.firstIndex(of: delimiter) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = buffer[buffer.index(after: newlineIndex)...]

            guard lineData.count > 10,
                  let lineString = String(data: lineData, encoding: .utf8),
                  lineString.contains("\"role\"") || lineString.contains("\"type\""),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let role = role(of: record),
                  let rawText = text(of: record) else { continue }
            let cleaned = cleanMeaningfulText(rawText)
            guard !cleaned.isEmpty else { continue }

            if messages.count >= maximumTranscriptMessages ||
                characterCount >= maximumTranscriptCharacters {
                truncated = true
                break
            }
            let remaining = maximumTranscriptCharacters - characterCount
            let limit = min(maximumMessageCharacters, remaining)
            let value = String(cleaned.prefix(limit))
            if value.count < cleaned.count { truncated = true }
            characterCount += value.count

            messages.append(.init(
                id: "\(session.id):\(messageIndex)",
                role: role,
                text: value,
                timestamp: timestamp(of: record)
            ))
            messageIndex += 1
        }

        if !truncated && !buffer.isEmpty,
           let lineString = String(data: buffer, encoding: .utf8),
           lineString.contains("\"role\"") || lineString.contains("\"type\""),
           let record = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
           let role = role(of: record),
           let rawText = text(of: record) {
            let cleaned = cleanMeaningfulText(rawText)
            if !cleaned.isEmpty {
                let value = String(cleaned.prefix(maximumMessageCharacters))
                messages.append(.init(
                    id: "\(session.id):\(messageIndex)",
                    role: role,
                    text: value,
                    timestamp: timestamp(of: record)
                ))
            }
        }

        return .init(
            sessionID: session.id,
            messages: messages,
            wasTruncated: truncated
        )
    }

    nonisolated private static func parseTranscript(
        for session: AgentHistorySession
    ) -> AgentHistoryTranscript {
        let url = URL(fileURLWithPath: session.sourcePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .init(sessionID: session.id, messages: [], wasTruncated: false)
        }
        defer { try? handle.close() }

        var messages: [AgentHistoryMessage] = []
        var characterCount = 0
        var truncated = false
        var leftover = Data()
        let delimiter = UInt8(ascii: "\n")
        var messageIndex = 0

        while !Task.isCancelled {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            var buffer = leftover + chunk
            leftover = Data()

            while let newlineIndex = buffer.firstIndex(of: delimiter) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = buffer[buffer.index(after: newlineIndex)...]

                // Quick pre-check before expensive JSON parsing
                guard lineData.count > 10,
                      let lineString = String(data: lineData, encoding: .utf8),
                      lineString.contains("\"role\"") || lineString.contains("\"type\"") else {
                    continue
                }
                guard let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let role = role(of: record),
                      let rawText = text(of: record) else {
                    continue
                }
                let cleaned = cleanMeaningfulText(rawText)
                guard !cleaned.isEmpty else { continue }

                if messages.count >= maximumTranscriptMessages ||
                    characterCount >= maximumTranscriptCharacters {
                    truncated = true
                    break
                }
                let remaining = maximumTranscriptCharacters - characterCount
                let limit = min(maximumMessageCharacters, remaining)
                let value = String(cleaned.prefix(limit))
                if value.count < cleaned.count { truncated = true }
                characterCount += value.count

                messages.append(.init(
                    id: "\(session.id):\(messageIndex)",
                    role: role,
                    text: value,
                    timestamp: timestamp(of: record)
                ))
                messageIndex += 1
            }

            if truncated { break }
            leftover = buffer
        }

        if !truncated && !leftover.isEmpty && !Task.isCancelled {
            if let lineString = String(data: leftover, encoding: .utf8),
               lineString.contains("\"role\"") || lineString.contains("\"type\""),
               let record = try? JSONSerialization.jsonObject(with: leftover) as? [String: Any],
               let role = role(of: record),
               let rawText = text(of: record) {
                let cleaned = cleanMeaningfulText(rawText)
                if !cleaned.isEmpty {
                    let value = String(cleaned.prefix(maximumMessageCharacters))
                    messages.append(.init(
                        id: "\(session.id):\(messageIndex)",
                        role: role,
                        text: value,
                        timestamp: timestamp(of: record)
                    ))
                }
            }
        }

        return .init(
            sessionID: session.id,
            messages: messages,
            wasTruncated: truncated
        )
    }

    nonisolated private static func scanRemote(
        access: AgentHistoryRemoteAccess,
        agents: [SupportedAgent],
        maximumSessions: Int
    ) async -> [AgentHistorySession] {
        guard maximumSessions > 0, !Task.isCancelled else { return [] }
        guard let home = try? await access.remoteHome() else { return [] }
        guard !Task.isCancelled else { return [] }

        var sources: [RemoteSource] = []
        for agent in agents {
            guard let source = remoteSource(for: agent, remoteHome: home) else { continue }
            sources.append(source)
        }
        guard !sources.isEmpty else { return [] }

        let roots = Array(Set(sources.map(\.rootPath)))
        guard let files = try? await access.enumerate(
            roots: roots,
            maximumFiles: maximumHeaderCandidates
        ) else { return [] }

        var candidates: [RemoteCandidate] = []
        for file in files {
            guard !Task.isCancelled else { return [] }
            guard let source = sources.first(where: { file.path.hasPrefix($0.rootPath + "/") }) else {
                continue
            }
            let filenameID: AgentConversationID?
            if let pattern = source.entryPattern {
                let relative = relativeRemotePath(file.path, under: source.rootPath)
                guard let rawID = id(from: relative, pattern: pattern),
                      let id = AgentConversationID(rawID) else { continue }
                filenameID = id
            } else {
                filenameID = nil
            }
            candidates.append(.init(
                source: source,
                file: file,
                filenameID: filenameID
            ))
        }

        var sessionsByID: [String: AgentHistorySession] = [:]
        for candidate in candidates.prefix(maximumSessions) {
            guard !Task.isCancelled, sessionsByID.count < maximumSessions else { break }
            guard let headerData = try? await access.read(
                path: candidate.file.path,
                maximumBytes: maximumHeaderBytes
            ) else { continue }
            let records = headerRecords(from: headerData)
            guard !records.isEmpty else { continue }

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
                continue
            }
            guard let conversationID = metadataID ?? candidate.filenameID else {
                continue
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
                      ["title", "title_change", "session"].contains(type),
                      let title = record["title"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return current
                }
                return title
            }
            let userTitle = records.lazy.compactMap { record -> String? in
                guard role(of: record) == .user else { return nil }
                return text(of: record)
            }.compactMap { raw -> String? in
                let cleaned = cleanMeaningfulText(raw)
                guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return nil }
                return cleaned
            }.first
            let title = normalizedTitle(
                explicitTitle ?? userTitle,
                workingDirectory: workingDirectory,
                conversationID: conversationID
            )
            let previewSnippet = records.lazy.compactMap { record -> String? in
                guard let raw = text(of: record) else { return nil }
                let cleaned = cleanMeaningfulText(raw)
                return cleaned.isEmpty || cleaned == "[Image/Attachment]"
                    ? nil
                    : String(cleaned.prefix(1_000))
            }.prefix(10).joined(separator: "\n")

            let session = AgentHistorySession(
                agent: candidate.source.agent,
                conversationID: conversationID,
                title: title,
                workingDirectory: workingDirectory,
                updatedAt: candidate.file.modifiedAt,
                sourcePath: candidate.file.path,
                remoteHost: access.alias,
                isActive: false,
                previewSnippet: previewSnippet.isEmpty ? nil : previewSnippet
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

    nonisolated private static func remoteSource(
        for agent: SupportedAgent,
        remoteHome: String
    ) -> RemoteSource? {
        let resume = agent.definition.resume
        guard !resume.resumeArguments.isEmpty else { return nil }

        if let discovery = resume.discover, discovery.format == .jsonl {
            let rootPath = expandRemoteHome(discovery.root, remoteHome: remoteHome)
            guard AgentHistoryRemoteAccess.validRemotePath(rootPath) else { return nil }
            return .init(
                agent: agent,
                rootPath: rootPath,
                entryPattern: nil,
                idKeyPath: discovery.idKeyPath,
                cwdKeyPath: discovery.cwdKeyPath
            )
        }

        guard let store = resume.store,
              store.entryPattern.lowercased().contains(".jsonl") else {
            return nil
        }
        let rootPath = expandRemoteHome(store.root, remoteHome: remoteHome)
        guard AgentHistoryRemoteAccess.validRemotePath(rootPath) else { return nil }
        return .init(
            agent: agent,
            rootPath: rootPath,
            entryPattern: store.entryPattern,
            idKeyPath: nil,
            cwdKeyPath: nil
        )
    }

    nonisolated private static func expandRemoteHome(
        _ path: String,
        remoteHome: String
    ) -> String {
        if path == "~" { return remoteHome }
        if path.hasPrefix("~/") {
            let trimmed = remoteHome.hasSuffix("/") ? String(remoteHome.dropLast()) : remoteHome
            return trimmed + String(path.dropFirst())
        }
        return path
    }

    nonisolated private static func relativeRemotePath(
        _ path: String,
        under root: String
    ) -> String {
        guard path.hasPrefix(root) else { return path }
        let suffix = path.dropFirst(root.count)
        return String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated private static func headerRecords(from data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
    }

    nonisolated private static func headerRecords(
        at url: URL,
        maximumBytes: Int
    ) -> [[String: Any]] {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
    }

    nonisolated private static func firstTranscriptMatch(
        at url: URL,
        query: String
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let queryData = Data(query.utf8)
        var leftover = Data()
        let delimiter = UInt8(ascii: "\n")

        while !Task.isCancelled {
            guard let chunk = try? handle.read(upToCount: 128 * 1_024),
                  !chunk.isEmpty else { break }
            var buffer = leftover + chunk
            leftover = Data()
            while let newlineIndex = buffer.firstIndex(of: delimiter) {
                let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
                buffer = buffer[buffer.index(after: newlineIndex)...]
                guard lineData.range(of: queryData) != nil,
                      let record = try? JSONSerialization.jsonObject(
                          with: lineData
                      ) as? [String: Any],
                      role(of: record) != nil,
                      let rawText = text(of: record) else { continue }
                let cleaned = cleanMeaningfulText(rawText)
                guard let range = cleaned.range(
                    of: query,
                    options: .caseInsensitive
                ) else { continue }
                return searchSnippet(cleaned, around: range)
            }
            // Agent records can be large, but an unbounded malformed line must
            // not turn one search into unbounded memory growth.
            leftover = buffer.count <= 4 * 1_024 * 1_024 ? buffer : Data()
        }
        return nil
    }

    nonisolated private static func searchSnippet(
        _ text: String,
        around range: Range<String.Index>
    ) -> String {
        let start = text.index(
            range.lowerBound,
            offsetBy: -80,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            range.upperBound,
            offsetBy: 120,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let value = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > text.startIndex ? "…" : "") + value +
            (end < text.endIndex ? "…" : "")
    }

    nonisolated private static func role(
        of record: [String: Any]
    ) -> AgentHistoryMessageRole? {
        let rawRole = (record["message"] as? [String: Any])?["role"] as? String ??
            (record["payload"] as? [String: Any])?["role"] as? String ??
            record["role"] as? String ??
            record["type"] as? String
        switch rawRole?.lowercased() {
        case "user": return .user
        case "assistant": return .assistant
        default: return nil
        }
    }

    nonisolated private static func text(of record: [String: Any]) -> String? {
        if let message = record["message"] as? [String: Any],
           let text = text(from: message["content"]) {
            return text
        }
        if let payload = record["payload"] as? [String: Any],
           let text = text(from: payload["content"]) {
            return text
        }
        if let text = text(from: record["content"]) { return text }
        if let humanInput = record["humanInput"] as? [String: Any],
           let text = humanInput["text"] as? String {
            return text
        }
        return nil
    }

    nonisolated private static func text(from value: Any?) -> String? {
        if let value = value as? String { return value }
        guard let values = value as? [Any] else { return nil }
        var parts: [String] = []
        for item in values {
            if let item = item as? String {
                parts.append(item)
            } else if let item = item as? [String: Any] {
                guard let text = item["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isMeaninglessBlockOrInstruction(trimmed) {
                    continue
                }
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated private static func isMeaninglessBlockOrInstruction(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("<recommended_plugins") ||
            lower.hasPrefix("<environment_context") ||
            lower.hasPrefix("<instructions") ||
            lower.hasPrefix("# agents.md instructions") ||
            lower.hasPrefix("agents.md instructions") ||
            lower.hasPrefix("# files mentioned by the user") ||
            lower.hasPrefix("files mentioned by the user") {
            return true
        }
        return false
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

    nonisolated private static func validWorkingDirectory(
        _ value: String?
    ) -> String? {
        guard let value,
              !value.isEmpty,
              !value.contains("\0"),
              value.utf8.count <= 4_096 else { return nil }
        return value
    }

    nonisolated static func cleanMeaningfulText(_ raw: String) -> String {
        var text = raw
        let blockTags = ["recommended_plugins", "environment_context", "INSTRUCTIONS", "instructions"]
        for tag in blockTags {
            while let startRange = text.range(of: "<\(tag)>", options: .caseInsensitive),
                  let endRange = text.range(of: "</\(tag)>", options: .caseInsensitive),
                  startRange.lowerBound < endRange.upperBound {
                text.removeSubrange(startRange.lowerBound..<endRange.upperBound)
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
                if trimmed.hasPrefix("## ") || trimmed.hasPrefix("/var/folders") || trimmed.contains("codex-clipboard") {
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
            return fallback
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
        if line.contains("omg-paste") || line.contains("otty-paste") || line.contains("codex-clipboard") {
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.count <= 3 && (line.hasPrefix("/") || line.hasPrefix("##")) { return true }
        }
        if line.hasPrefix("/var/folders/") || line.hasPrefix("/private/var/folders/") {
            if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") ||
                lower.hasSuffix(".jpeg") || lower.hasSuffix(".webp") ||
                lower.contains("/t/omg-") || lower.contains("/t/otty-") ||
                lower.contains("/t/codex-") {
                let words = line.split(whereSeparator: \.isWhitespace)
                if words.count <= 3 { return true }
            }
        }
        if line.hasPrefix("<cwd>") || line.hasPrefix("<shell>") ||
            line.hasPrefix("<current_date>") || line.hasPrefix("<timezone>") ||
            line.hasPrefix("<filesystem>") || line.hasPrefix("</filesystem>") ||
            line.hasPrefix("<permission_profile") || line.hasPrefix("</environment_context>") ||
            line.hasPrefix("<image") || line.hasPrefix("</image>") {
            return true
        }
        return false
    }

    nonisolated private static func normalizedTitle(
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
