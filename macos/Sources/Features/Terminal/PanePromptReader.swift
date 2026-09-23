import Foundation

/// The live pane reader is deliberately separate from the bounded transcript
/// preview used by Agent History. It keeps complete user text, never assistants.
actor PanePromptReader {
    struct Snapshot: Equatable, Sendable {
        var items: [InspectorHistoryItem] = []
        var limited = false
    }

    static let maximumReadBytes = 8 * 1_024 * 1_024
    private let session: AgentHistorySession
    private let remoteAccess: AgentHistoryRemoteAccess?
    private var parser = Parser()
    private var offset: UInt64 = 0
    private var identity: String?
    private var modified: Date?
    private var remoteRevision: String?
    private var generation = UUID()

    init(session: AgentHistorySession, remoteAccess: AgentHistoryRemoteAccess? = nil) {
        self.session = session
        self.remoteAccess = remoteAccess
    }

    func refresh() async throws -> Snapshot {
        try Task.checkCancellation()
        if let host = session.remoteHost {
            // No store rediscovery: read only this session's known file, and
            // transfer no body if its revision hasn't changed.
            let access = remoteAccess ?? AgentHistoryRemoteAccess(alias: host)
            let tail = try await access.promptTail(
                path: session.sourcePath,
                previousRevision: remoteRevision,
                maximumBytes: Self.maximumReadBytes
            )
            try Task.checkCancellation()
            if let data = tail.data {
                let previous = remoteRevision?.split(separator: ":", maxSplits: 2)
                let current = tail.revision.split(separator: ":", maxSplits: 2)
                let previousSize = previous?.dropFirst().first.flatMap { UInt64($0) } ?? 0
                let currentSize = current.dropFirst().first.flatMap { UInt64($0) } ?? 0
                if previous?.first != current.first || currentSize <= previousSize {
                    generation = UUID()
                }
                parser = Parser()
                parser.reset(offset: tail.offset)
                parser.append(data, namespace: "\(session.id):\(generation)")
                remoteRevision = tail.revision
            }
        } else {
            try readLocal()
        }
        return parser.snapshot
    }

    private func readLocal() throws {
        let url = URL(fileURLWithPath: session.sourcePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = String(describing: attributes[.systemFileNumber])
        let date = attributes[.modificationDate] as? Date
        let reset = identity != fileID || size < offset || (size == offset && modified != date)
            || (size > offset && size - offset > UInt64(Self.maximumReadBytes))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if reset {
            generation = UUID()
            parser = Parser()
            offset = size > UInt64(Self.maximumReadBytes) ? size - UInt64(Self.maximumReadBytes) : 0
            parser.reset(offset: offset)
        }
        try handle.seek(toOffset: offset)
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(65_536, size - offset))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
            parser.append(data, namespace: "\(session.id):\(generation)")
            offset += UInt64(data.count)
        }
        identity = fileID
        modified = date
    }

    /// Byte-offset occurrence IDs survive append, repeated text and polling.
    /// Incomplete JSONL records remain buffered until the next append.
    struct Parser {
        private var pending = Data()
        private var lineOffset: UInt64 = 0
        private var skippingLine = false
        private var retainedBytes = 0
        private(set) var snapshot = Snapshot()
        private static let maximumLineBytes = 8 * 1_024 * 1_024
        private static let maximumTextBytes = 1 * 1_024 * 1_024

        mutating func reset(offset: UInt64) {
            self = Parser()
            lineOffset = offset
            skippingLine = offset > 0
            snapshot.limited = offset > 0
        }

        mutating func append(_ data: Data, namespace: String) {
            for fragment in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                if fragment.offset > 0 {
                    if !skippingLine { consume(namespace: namespace) }
                    lineOffset += UInt64(pending.count) + 1
                    pending.removeAll(keepingCapacity: true)
                    skippingLine = false
                }
                if skippingLine {
                    lineOffset += UInt64(fragment.element.count)
                } else if pending.count + fragment.element.count > Self.maximumLineBytes {
                    lineOffset += UInt64(pending.count + fragment.element.count)
                    pending.removeAll(keepingCapacity: true)
                    skippingLine = true
                    snapshot.limited = true
                } else {
                    pending.append(contentsOf: fragment.element)
                }
            }
        }

        private mutating func consume(namespace: String) {
            guard let record = try? JSONSerialization.jsonObject(with: pending) as? [String: Any],
                  let text = Self.userText(record), !text.isEmpty else { return }
            let bytes = text.utf8.count
            guard bytes <= Self.maximumTextBytes else {
                // Never offer a silently truncated value as "Copy".
                snapshot.limited = true
                return
            }
            let message = record["message"] as? [String: Any]
            var timestamp: Date?
            if let raw = record["timestamp"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                timestamp = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
            } else if let milliseconds = message?["timestamp"] as? Double {
                timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            }
            snapshot.items.append(.init(
                id: "\(namespace):byte:\(lineOffset)", kind: .agentPrompt,
                text: text, timestamp: timestamp, location: .unavailable(.transcriptOnly)
            ))
            retainedBytes += bytes
            while snapshot.items.count > 100 || retainedBytes > Self.maximumLineBytes {
                retainedBytes -= snapshot.items.removeFirst().text.utf8.count
                snapshot.limited = true
            }
        }

        private static func userText(_ record: [String: Any]) -> String? {
            let message = record["message"] as? [String: Any]
                ?? record["payload"] as? [String: Any] ?? record
            let role = message["role"] as? String ?? record["role"] as? String ?? record["type"] as? String
            guard role == "user", record["isMeta"] as? Bool != true else { return nil }
            if let text = message["content"] as? String { return text }
            if let input = record["humanInput"] as? [String: Any], let text = input["text"] as? String {
                return text
            }
            guard let blocks = message["content"] as? [Any] else { return nil }
            let parts = blocks.compactMap { value -> String? in
                if let text = value as? String { return text }
                guard let block = value as? [String: Any] else { return nil }
                let type = block["type"] as? String
                guard type == nil || type == "text" || type == "input_text" else { return nil }
                return block["text"] as? String
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
    }
}
