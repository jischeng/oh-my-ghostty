import Combine
import Foundation
import os

/// Where a conversation's title came from, weakest first.
enum AgentConversationTitleSource: String, Codable, CaseIterable, Sendable {
    /// The opening prompt, cut short. Shown until something better exists.
    case prompt
    /// Summarised from the opening prompt by the configured endpoint.
    case generated
    /// The Agent's own name for the conversation.
    case native

    var rank: Int {
        switch self {
        case .prompt: 0
        case .generated: 1
        case .native: 2
        }
    }
}

struct AgentConversationTitleRecord: Codable, Equatable, Sendable {
    let agent: SupportedAgent
    let conversationID: AgentConversationID
    var title: String
    var source: AgentConversationTitleSource
    /// The SSH destination the conversation ran on; nil for a local one.
    var remoteHost: String?
    var updatedAt: Date
}

/// Where conversation titles report what they decided, so a tab that keeps
/// its folder name can be explained afterwards:
///
///     log stream --level debug --predicate 'category == "agent-titles"'
///
/// A line names the Agent, the start of the conversation ID and the decision.
/// It never holds a prompt or a title.
enum AgentConversationTitleLog {
    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty", category: "agent-titles"
    )

    /// A conversation as a log line names it.
    nonisolated static func tag(_ conversationID: AgentConversationID) -> String {
        String(conversationID.rawValue.prefix(8))
    }

    /// A decision: a lookup started, what it found, what was stored.
    nonisolated static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// A request that needed nothing; there is one for every Agent state change.
    nonisolated static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}

/// Titles of Agent conversations, keyed by `(agent, conversationID)`.
///
/// A title belongs to the conversation, not to the tab or pane showing it, so
/// it survives the Agent exiting, the tab closing and a relaunch. Whether a
/// pane shows one is decided from the pane's current resume descriptor.
@MainActor
final class AgentConversationTitleStore: ObservableObject {
    typealias Record = AgentConversationTitleRecord
    typealias Source = AgentConversationTitleSource

    struct Key: Hashable, Sendable {
        let agent: SupportedAgent
        let conversationID: AgentConversationID
    }

    static let shared = AgentConversationTitleStore(
        // App-hosted tests share this instance and must not write the user's archive.
        fileURL: OMGApplicationEnvironment.isRunningTests ? nil : defaultFileURL
    )

    nonisolated static var defaultFileURL: URL {
        OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("agent-titles", isDirectory: true)
            .appendingPathComponent("titles.json")
    }

    static let maximumRecords = 2_000
    static let retention: TimeInterval = 90 * 86_400
    /// Display columns kept of a native or generated title; a wide character takes two.
    nonisolated static let maximumTitleColumns = 120
    /// Display columns kept of the opening prompt fallback; matches generated tab titles.
    nonisolated static let promptTitleColumns = AITitleSanitizer.maxWidth
    private static let maximumArchiveBytes = 8 * 1_024 * 1_024

    @Published private(set) var records: [Key: Record] = [:]
    /// Sent after the title of a conversation changed. Tab chrome that shows
    /// one conversation listens here instead of redrawing on every change.
    let titleChanges = PassthroughSubject<Key, Never>()

    private let fileURL: URL?
    private let now: () -> Date
    private let diskQueue = DispatchQueue(label: "omg.agent-titles.storage", qos: .utility)
    /// False once an archive from a newer build was found, which this build must not replace.
    private var writesArchive = true

    private struct Archive: Codable {
        static let currentVersion = 1
        let version: Int
        let records: [Record]

        init(records: [Record]) {
            version = Self.currentVersion
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case records
        }

        private struct Unreadable: Decodable {
            init(from decoder: Decoder) throws {}
        }

        /// A record naming an Agent this build does not know is skipped; it
        /// must not cost every other title.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else {
                records = []
                return
            }
            var list = try container.nestedUnkeyedContainer(forKey: .records)
            var decoded: [Record] = []
            while !list.isAtEnd {
                if let record = try? list.decode(Record.self) {
                    decoded.append(record)
                } else {
                    _ = try list.decode(Unreadable.self)
                }
            }
            records = decoded
        }
    }

    private enum StorageError: Error {
        case invalidArchive
        case unsafePath
    }

    // No file URL means an isolated in-memory store (also used by tests).
    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw StorageError.unsafePath }
            guard (values.fileSize ?? 0) <= Self.maximumArchiveBytes else { throw StorageError.invalidArchive }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version <= Archive.currentVersion else {
                writesArchive = false
                return
            }
            var loaded: [Key: Record] = [:]
            for var record in archive.records {
                guard let title = Self.displayTitle(record.title, columns: Self.maximumTitleColumns) else { continue }
                record.title = title
                let key = Key(agent: record.agent, conversationID: record.conversationID)
                if let existing = loaded[key], existing.updatedAt >= record.updatedAt { continue }
                loaded[key] = record
            }
            records = bounded(loaded)
        } catch {
            // Do not destroy an unreadable archive just by launching.
            Self.report(error)
        }
    }

    func record(agent: SupportedAgent, conversationID: AgentConversationID) -> Record? {
        records[Key(agent: agent, conversationID: conversationID)]
    }

    func title(agent: SupportedAgent, conversationID: AgentConversationID) -> String? {
        record(agent: agent, conversationID: conversationID)?.title
    }

    /// Records a title unless a better one is already known. A source is never
    /// downgraded, and among equals only the Agent renames its own
    /// conversation: the opening prompt does not change and a generated title
    /// is never generated again, except when `force` is true, when
    /// `allowGeneratedOverNative` is true for a `.generated` title replacing a
    /// `.native` title, or when a Chinese generated title localizes an
    /// English-only native title.
    ///
    /// - Returns: Whether the conversation's title changed.
    @discardableResult
    func set(
        _ title: String,
        source: Source,
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        remoteHost: String? = nil,
        force: Bool = false,
        allowGeneratedOverNative: Bool = false
    ) -> Bool {
        let columns = source == .prompt ? Self.promptTitleColumns : Self.maximumTitleColumns
        guard let title = Self.displayTitle(title, columns: columns) else { return false }
        let key = Key(agent: agent, conversationID: conversationID)
        if let existing = records[key], !force {
            let renamed = source == .native && existing.source == .native && existing.title != title
            let localizedUpgrade = source == .generated
                && existing.source == .native
                && !Self.containsCJK(existing.title)
                && Self.containsCJK(title)
            let generatedOverride = allowGeneratedOverNative
                && source == .generated
                && existing.source == .native
            guard source.rank > existing.source.rank || renamed || localizedUpgrade || generatedOverride else {
                return false
            }
        }
        var next = records
        next[key] = Record(
            agent: agent, conversationID: conversationID, title: title,
            source: source, remoteHost: remoteHost, updatedAt: now()
        )
        records = bounded(next)
        persist()
        let archive = fileURL == nil ? "memory" : (writesArchive ? "file" : "read-only")
        AgentConversationTitleLog.info(
            "stored \(agent.rawValue) \(AgentConversationTitleLog.tag(conversationID)) " +
                "source=\(source.rawValue) archive=\(archive)"
        )
        titleChanges.send(key)
        return true
    }

    func removeAll() {
        guard !records.isEmpty else { return }
        let keys = Array(records.keys)
        records = [:]
        persist()
        for key in keys { titleChanges.send(key) }
    }

    /// Termination and tests drain pending atomic writes before reading the file.
    func flushPendingWrites() {
        diskQueue.sync {}
    }

    private func bounded(_ candidates: [Key: Record]) -> [Key: Record] {
        let cutoff = now().addingTimeInterval(-Self.retention)
        var kept = candidates.filter { $0.value.updatedAt > cutoff }
        if kept.count > Self.maximumRecords {
            let newest = kept.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maximumRecords)
            kept = Dictionary(
                newest.map { (Key(agent: $0.agent, conversationID: $0.conversationID), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return kept
    }

    private func persist() {
        guard let fileURL, writesArchive else { return }
        let snapshot = records.values.sorted { $0.updatedAt < $1.updatedAt }
        diskQueue.async {
            do {
                if snapshot.isEmpty {
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
                    try FileManager.default.removeItem(at: fileURL)
                } else {
                    let data = try JSONEncoder().encode(Archive(records: snapshot))
                    try OMGPrivateFileWriter.writeAtomically(data, to: fileURL)
                }
            } catch {
                Self.report(error)
            }
        }
    }

    nonisolated private static func report(_ error: Error) {
        AgentConversationTitleLog.logger
            .error("Title storage failed: \(error.localizedDescription, privacy: .private)")
    }

    // MARK: Title text

    /// A title as one line that fits a tab: the first line with text, without
    /// control or direction-override characters, cut to `columns` display
    /// columns. nil when nothing readable is left.
    nonisolated static func displayTitle(_ raw: String, columns: Int) -> String? {
        let firstLine = raw.split(whereSeparator: \.isNewline)
            .lazy
            .map { line -> String in
                // A tab is a control character too, but it separates words.
                let scalars = line.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                    if scalar.properties.isWhitespace { return " " }
                    if scalar.properties.generalCategory == .control || isDirectionOverride(scalar) { return nil }
                    return scalar
                }
                return String(String.UnicodeScalarView(scalars))
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
            }
            .first { !$0.isEmpty }
        guard let line = firstLine else { return nil }
        var used = 0
        var result = ""
        for character in line {
            let width = isWide(character) ? 2 : 1
            guard used + width <= columns else {
                let trimmed = result.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed + "…"
            }
            result.append(character)
            used += width
        }
        return result
    }

    /// Whether `text` contains any CJK Unified Ideograph character.
    nonisolated static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
                return true
            default:
                return false
            }
        }
    }

    nonisolated private static func isDirectionOverride(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// East Asian wide and emoji characters occupy two columns in a tab row.
    nonisolated private static func isWide(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
