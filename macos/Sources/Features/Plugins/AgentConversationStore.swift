import Foundation

enum AgentConversationStore {
    private static let maximumFiles = 20_000
    private static let maximumHeaderBytes = 64 * 1_024
    private static let creationTolerance: TimeInterval = 2

    static func contains(
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        rootURL: URL? = nil
    ) -> Bool {
        let resume = agent.definition.resume
        let rootValue = resume.store?.root ?? resume.discover?.root
        guard let rootValue else { return false }
        let root = rootURL ?? URL(
            fileURLWithPath: (rootValue as NSString).expandingTildeInPath
        )
        if let store = resume.store {
            let target = store.entryPattern.replacingOccurrences(
                of: "{id}",
                with: conversationID.rawValue
            )
            if !target.contains("*"),
               FileManager.default.fileExists(
                   atPath: root.appendingPathComponent(target).path
               ) {
                return true
            }
            guard let buckets = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ), buckets.count <= maximumFiles else { return false }
            for bucket in buckets {
                if !target.contains("*") {
                    if FileManager.default.fileExists(
                        atPath: bucket.appendingPathComponent(target).path
                    ) { return true }
                } else if let entries = try? FileManager.default.contentsOfDirectory(
                    atPath: bucket.path
                ), entries.contains(where: { id(
                    fromEntryName: $0,
                    pattern: store.entryPattern
                ) == conversationID.rawValue }) {
                    return true
                }
            }
            return false
        }
        guard let discovery = resume.discover,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return false }
        var inspected = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            inspected += 1
            guard inspected <= maximumFiles else { return false }
            guard let objects = headerObjects(at: url) else { continue }
            if objects.contains(where: {
                value(at: discovery.idKeyPath, in: $0) == conversationID.rawValue
            }) { return true }
        }
        return false
    }

    static func discover(
        agent: SupportedAgent,
        workingDirectory: String,
        launchedAfter: Date,
        excluding claimedConversationIDs: Set<AgentConversationID> = [],
        rootURL: URL? = nil
    ) -> AgentConversationID? {
        if agent == .antigravity {
            return discoverAntigravity(
                workingDirectory: workingDirectory,
                launchedAfter: launchedAfter,
                excluding: claimedConversationIDs,
                rootURL: rootURL
            )
        }
        let resume = agent.definition.resume
        if let command = resume.commandDiscovery {
            return discover(
                command: command,
                workingDirectory: workingDirectory,
                launchedAfter: launchedAfter,
                excluding: claimedConversationIDs
            )
        }
        guard let rootValue = resume.discover?.root ?? resume.store?.root else {
            return nil
        }
        let root = rootURL ?? URL(
            fileURLWithPath: (rootValue as NSString).expandingTildeInPath
        )
        let target = canonical(workingDirectory)
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let threshold = launchedAfter.addingTimeInterval(-creationTolerance)
        var inspected = 0
        // A conversation this launch started, and one the Agent resumed: a
        // resumed session keeps its old transcript and writes to it again the
        // moment it comes back. Conversations already claimed by another live
        // pane are excluded so a second pane never adopts an active sibling's ID.
        var created = Set<AgentConversationID>()
        var resumed: [(id: AgentConversationID, modified: Date)] = []
        for case let url as URL in enumerator {
            inspected += 1
            guard inspected <= maximumFiles else { return nil }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let createdAt = values.creationDate,
                  let modified = values.contentModificationDate,
                  createdAt >= threshold || modified >= threshold,
                  let objects = headerObjects(at: url) else { continue }
            let candidate: (id: String, cwd: String)?
            if let discovery = resume.discover {
                candidate = objects.lazy.compactMap { object in
                    guard let id = value(at: discovery.idKeyPath, in: object),
                          let cwd = value(at: discovery.cwdKeyPath, in: object) else {
                        return nil
                    }
                    return (id, cwd)
                }.first
            } else if let store = resume.store,
                      let id = id(fromEntryName: url.lastPathComponent, pattern: store.entryPattern),
                      let cwd = objects.lazy.compactMap({ value(at: "cwd", in: $0) }).first {
                candidate = (id, cwd)
            } else {
                candidate = nil
            }
            guard let candidate,
                  canonical(candidate.cwd) == target,
                  let id = AgentConversationID(candidate.id),
                  !claimedConversationIDs.contains(id) else { continue }
            if createdAt >= threshold {
                created.insert(id)
                if created.count > 1 { return nil }
            } else {
                resumed.removeAll { $0.id == id }
                resumed.append((id, modified))
            }
        }
        if let only = created.first { return only }
        // Several resumed transcripts of one directory are common; the one the
        // Agent touched when it came back is the newest. Two touched within a
        // moment of each other cannot be told apart, so neither is adopted.
        resumed.sort { $0.modified > $1.modified }
        guard let newest = resumed.first else { return nil }
        if resumed.count > 1, newest.modified.timeIntervalSince(resumed[1].modified) < creationTolerance {
            return nil
        }
        return newest.id
    }

    private static func discoverAntigravity(
        workingDirectory: String,
        launchedAfter: Date,
        excluding claimedConversationIDs: Set<AgentConversationID>,
        rootURL: URL?
    ) -> AgentConversationID? {
        let root = rootURL ?? URL(
            fileURLWithPath: ("~/.gemini/antigravity-cli/conversations" as NSString).expandingTildeInPath
        )
        let index = root.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db")
        guard let database = AgentHistoryDatabase(path: index.path) else { return nil }
        let target = canonical(workingDirectory)
        let threshold = launchedAfter.addingTimeInterval(-creationTolerance)
        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        var created = Set<AgentConversationID>()
        var resumed: [(id: AgentConversationID, modified: Date)] = []
        var ambiguousCreated = false

        let visit: (AgentHistoryDatabase.Row) -> Bool = { row in
            guard let id = row.text(0).flatMap(AgentConversationID.init),
                  !claimedConversationIDs.contains(id) else { return true }
            let uris = (row.text(1) ?? "").data(using: .utf8).flatMap {
                try? JSONDecoder().decode([String].self, from: $0)
            } ?? []
            let matchesWorkspace = uris.compactMap(URL.init(string:))
                .contains { $0.isFileURL && canonical($0.path) == target }
            guard matchesWorkspace else { return true }
            let trajectoryURL = root.appendingPathComponent(id.rawValue + ".db")
            guard let values = try? trajectoryURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { return true }
            let indexedModified = (row.text(2).flatMap(Double.init) ?? row.double(2))
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let modified = indexedModified ?? values.contentModificationDate ?? .distantPast
            let createdAt = values.creationDate ?? modified
            guard createdAt >= threshold || modified >= threshold else { return true }
            if createdAt >= threshold {
                created.insert(id)
                if created.count > 1 {
                    ambiguousCreated = true
                    return false
                }
            } else {
                resumed.removeAll { $0.id == id }
                resumed.append((id, modified))
            }
            return true
        }

        let primary = """
        SELECT conversation_id, workspace_uris, strftime('%s', last_modified_time)
        FROM conversation_summaries WHERE nesting_depth = 0
        ORDER BY last_modified_time DESC LIMIT 500
        """
        let fallback = """
        SELECT conversation_id, workspace_uris, strftime('%s', last_modified_time)
        FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 500
        """
        if !database.query(primary, visit: visit) {
            database.query(fallback, visit: visit)
        }
        guard !ambiguousCreated else { return nil }
        if let only = created.first { return only }
        resumed.sort { $0.modified > $1.modified }
        guard let newest = resumed.first else { return nil }
        if resumed.count > 1, newest.modified.timeIntervalSince(resumed[1].modified) < creationTolerance {
            return nil
        }
        return newest.id
    }

    private static func discover(
        command: AgentDefinition.ResumeSpec.CommandDiscovery,
        workingDirectory: String,
        launchedAfter: Date,
        excluding claimedConversationIDs: Set<AgentConversationID>
    ) -> AgentConversationID? {
        guard !workingDirectory.contains("\0"),
              workingDirectory.utf8.count <= 4_096 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments.map {
            $0.replacingOccurrences(of: "{cwd}", with: workingDirectory)
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var data = Data()
            var oversized = false
            while let chunk = try output.fileHandleForReading.read(upToCount: 8_192),
                  !chunk.isEmpty {
                let remaining = max(0, 1_048_576 - data.count)
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { oversized = true }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  !oversized,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = root[command.listKey] as? [[String: Any]] else {
                return nil
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let threshold = launchedAfter.addingTimeInterval(-creationTolerance)
            let matches = Set(entries.compactMap { entry -> AgentConversationID? in
                guard let rawID = entry[command.idKey] as? String,
                      let rawDate = entry[command.createdAtKey] as? String,
                      let created = formatter.date(from: rawDate),
                      created >= threshold,
                      let id = AgentConversationID(rawID),
                      !claimedConversationIDs.contains(id) else { return nil }
                return id
            })
            return matches.count == 1 ? matches.first : nil
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
    }

    private static func headerObjects(at url: URL) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumHeaderBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 63).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private static func value(at keyPath: String, in object: [String: Any]) -> String? {
        var current: Any = object
        for key in keyPath.split(separator: ".") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[String(key)] else { return nil }
            current = next
        }
        return current as? String
    }

    private static func id(fromEntryName name: String, pattern: String) -> String? {
        guard let idRange = pattern.range(of: "{id}") else { return nil }
        let prefix = pattern[..<idRange.lowerBound].replacingOccurrences(of: "*", with: "")
        let suffix = pattern[idRange.upperBound...].replacingOccurrences(of: "*", with: "")
        var core = Substring(name)
        if !suffix.isEmpty {
            guard core.hasSuffix(suffix) else { return nil }
            core = core.dropLast(suffix.count)
        }
        if !prefix.isEmpty, let range = core.range(of: prefix) {
            core = core[range.upperBound...]
        }
        return core.isEmpty ? nil : String(core)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}
