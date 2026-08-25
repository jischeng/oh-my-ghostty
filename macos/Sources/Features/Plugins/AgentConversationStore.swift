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
            guard let buckets = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ), buckets.count <= maximumFiles else { return false }
            let target = store.entryPattern.replacingOccurrences(
                of: "{id}",
                with: conversationID.rawValue
            )
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
        rootURL: URL? = nil
    ) -> AgentConversationID? {
        let resume = agent.definition.resume
        guard let rootValue = resume.discover?.root ?? resume.store?.root else {
            return nil
        }
        let root = rootURL ?? URL(
            fileURLWithPath: (rootValue as NSString).expandingTildeInPath
        )
        let target = canonical(workingDirectory)
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let threshold = launchedAfter.addingTimeInterval(-creationTolerance)
        var inspected = 0
        var matches = Set<AgentConversationID>()
        for case let url as URL in enumerator {
            inspected += 1
            guard inspected <= maximumFiles else { return nil }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let created = values.creationDate,
                  created >= threshold,
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
                  let id = AgentConversationID(candidate.id) else { continue }
            matches.insert(id)
            if matches.count > 1 { return nil }
        }
        return matches.first
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
