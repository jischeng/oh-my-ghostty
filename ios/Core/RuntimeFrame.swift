import Foundation

public struct RuntimeFrame: Equatable {
    public static let maximumPayload = 16 * 1024 * 1024 + 13
    public let kind: UInt8
    public let sequence: UInt64
    public let data: Data

    public init(_ kind: UInt8, _ sequence: UInt64 = 0, _ data: Data = Data()) {
        self.kind = kind
        self.sequence = sequence
        self.data = data
    }

    public func encoded() -> Data {
        var result = Data([kind])
        for shift in stride(from: 56, through: 0, by: -8) {
            result.append(UInt8(truncatingIfNeeded: sequence >> shift))
        }
        let length = UInt32(data.count)
        for shift in stride(from: 24, through: 0, by: -8) {
            result.append(UInt8(truncatingIfNeeded: length >> shift))
        }
        result.append(data)
        return result
    }

    /// Inner `'C'` (`67`) frame acknowledging completed (`done` / `error`) activity.
    /// Carries an 8-byte big-endian `maxRevision` watermark when `> 0` so a fresh
    /// completion racing in flight on a higher revision is never wiped.
    public static func acknowledgeActivity(maxRevision: UInt64? = nil) -> RuntimeFrame {
        guard let revision = maxRevision, revision > 0 else {
            return RuntimeFrame(67, 0)
        }
        var payload = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            payload.append(UInt8(truncatingIfNeeded: revision >> shift))
        }
        return RuntimeFrame(67, 0, payload)
    }

    /// Inner v2 `'R'` (`82`) frame carrying 8-byte big-endian `[cols, rows, px_w, px_h]`.
    public static func resize(_ viewport: RuntimeViewport) -> RuntimeFrame {
        var payload = Data(capacity: 8)
        for field in [viewport.columns, viewport.rows, viewport.pixelWidth, viewport.pixelHeight] {
            payload.append(UInt8(field >> 8))
            payload.append(UInt8(field & 0xFF))
        }
        return RuntimeFrame(82, 0, payload)
    }

    /// Decodes an inner `'R'` (`82`) payload (v2 8-byte `[cols, rows, px_w, px_h]` or
    /// legacy 4-byte `[cols, rows]`). Rejects zero or out-of-range dimensions matching `omgd`.
    public static func decodeResizePayload(_ data: Data) -> RuntimeViewport? {
        guard data.count == 4 || data.count == 8 else { return nil }
        let start = data.startIndex
        let cols = UInt16(data[start]) << 8 | UInt16(data[start + 1])
        let rows = UInt16(data[start + 2]) << 8 | UInt16(data[start + 3])
        guard cols >= 1, cols <= RuntimeViewport.maximumColumns,
              rows >= 1, rows <= RuntimeViewport.maximumRows else {
            return nil
        }
        if data.count == 8 {
            let pxW = UInt16(data[start + 4]) << 8 | UInt16(data[start + 5])
            let pxH = UInt16(data[start + 6]) << 8 | UInt16(data[start + 7])
            guard pxW <= RuntimeViewport.maximumPixels,
                  pxH <= RuntimeViewport.maximumPixels else {
                return nil
            }
            return RuntimeViewport.clamped(
                columns: Int(cols),
                rows: Int(rows),
                pixelWidth: Int(pxW),
                pixelHeight: Int(pxH)
            )
        }
        return RuntimeViewport.clamped(columns: Int(cols), rows: Int(rows), pixelWidth: 0, pixelHeight: 0)
    }

    public enum Failure: Error, Equatable { case oversized, invalidSequence, missingSnapshot }

    public struct Decoder {
        private var pending = Data()
        public init() {}
        public mutating func append(_ data: Data) throws -> [RuntimeFrame] {
            // Consume chunks incrementally; a transport chunk can span several frames.
            var frames: [RuntimeFrame] = []
            var offset = 0
            while offset < data.count {
                let room = RuntimeFrame.maximumPayload + 13 - pending.count
                guard room > 0 else { throw Failure.oversized }
                let count = min(room, data.count - offset)
                pending.append(data.subdata(in: offset ..< offset + count))
                offset += count
                var consumed = 0
                while pending.count - consumed >= 13 {
                    let start = pending.startIndex + consumed
                    let length = pending[(start + 9)..<(start + 13)].reduce(0) { ($0 << 8) | Int($1) }
                    guard length <= RuntimeFrame.maximumPayload else { throw Failure.oversized }
                    guard pending.count - consumed >= 13 + length else { break }
                    let seq = pending[(start + 1)..<(start + 9)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    frames.append(RuntimeFrame(pending[start], seq,
                        Data(pending[(start + 13)..<(start + 13 + length)])))
                    consumed += 13 + length
                }
                if consumed > 0 { pending.removeFirst(consumed) }
            }
            return frames
        }
    }
}

/// The snapshot is applied before acknowledging its watermark. A gap always
/// requires a new attachment; input from that old connection is never replayed.
public struct RuntimeWatermark {
    public private(set) var position: UInt64?
    public init() {}
    public mutating func snapshot(_ sequence: UInt64) { position = sequence }
    public mutating func output(_ frame: RuntimeFrame) throws {
        guard let position else { throw RuntimeFrame.Failure.missingSnapshot }
        let (next, overflow) = position.addingReportingOverflow(UInt64(frame.data.count))
        guard !overflow, next == frame.sequence else { throw RuntimeFrame.Failure.invalidSequence }
        self.position = next
    }
}

/// Stream IDs are never reused inside a transport. A detached session can
/// still have output or a writer grant in flight when another session opens.
public struct RuntimeAttachment {
    private var counter: UInt64 = 0
    public private(set) var stream: UInt64?
    public init() {}
    public mutating func open() -> UInt64 {
        counter += 1
        stream = counter
        return counter
    }
    public mutating func detach() -> UInt64? {
        let previous = stream
        stream = nil
        return previous
    }
    public func accepts(_ frame: RuntimeFrame) -> Bool {
        stream != nil && frame.sequence == stream
    }
}

/// Decodes and reduces a live `'G'` (`71`) `omgd` activity snapshot frame using
/// the canonical 3-tier authority hierarchy (`OSC 7501` > Hook/`omgd` > Fallback).
public struct RuntimeActivitySnapshot: Equatable, Sendable {
    public static let maximumSnapshotBytes = 2 * 1024 * 1024
    public static let maximumRecords = 64

    public struct Signal: Codable, Equatable, Sendable {
        public let id: String
        public let metadata: String

        public init(id: String, metadata: String) {
            self.id = id
            self.metadata = metadata
        }
    }

    private struct WirePayload: Decodable {
        let version: Int
        let revision: UInt64
        let records: [Signal]
        let pending: [Signal]?
        let remote_host: String?
        let remote_cwd: String?
        let sync_restore: Bool?
    }

    private enum Tier: Int, Comparable {
        case fallback = 1
        case hook = 2
        case programStatus = 3

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Presentation {
        let tier: Tier
        let agent: String
        let state: String
        let attention: String?
        let message: String
        let background: Bool

        var rank: Int {
            switch state {
            case "needsAttention": 0
            case "working" where !background: 1
            case "working": 2
            case "error": 3
            case "done": 4
            default: 5
            }
        }
    }

    public let version: Int
    public let revision: UInt64
    public let agent: String?
    public let state: String
    public let attention: String?
    public let message: String
    public let isSyncRestore: Bool
    public let remoteHost: String?
    public let remoteCwd: String?

    public var isTerminal: Bool {
        state == "done" || state == "error"
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumSnapshotBytes else { throw RuntimeFrame.Failure.oversized }
        let payload: WirePayload
        do {
            payload = try JSONDecoder().decode(WirePayload.self, from: data)
        } catch {
            throw RuntimeFrame.Failure.invalidSequence
        }
        guard payload.version == 1,
              payload.records.count <= Self.maximumRecords,
              (payload.pending?.count ?? 0) <= Self.maximumRecords else {
            throw RuntimeFrame.Failure.invalidSequence
        }

        version = payload.version
        revision = payload.revision
        isSyncRestore = payload.sync_restore ?? false
        remoteHost = payload.remote_host
        remoteCwd = payload.remote_cwd

        var programAppByID: [String: String] = [:]
        for signal in payload.records where signal.id == "omg-program-status" {
            let recordID = Self.field(signal.metadata, separator: ":", key: "id") ?? ""
            if let rawApp = Self.field(signal.metadata, separator: ":", key: "app"),
               let normalized = MobileSessionIcon.normalizeAgentID(rawApp) {
                programAppByID[recordID] = normalized
            }
        }
        let uniqueProgramApps = Set(programAppByID.values)
        var fallbackApp: String? = uniqueProgramApps.count == 1 ? uniqueProgramApps.first : nil
        if fallbackApp == nil {
            for signal in payload.records where signal.id.hasPrefix("omg-agent-") && signal.id != "omg-agent-sync" {
                if let rawApp = Self.field(signal.metadata, separator: ";", key: "omg_agent"),
                   let normalized = MobileSessionIcon.normalizeAgentID(rawApp) {
                    fallbackApp = normalized
                }
            }
        }

        var bestT1: Presentation?
        var bestT2: Presentation?
        var bestT3: Presentation?

        for signal in payload.records {
            guard let item = Self.parsePresentation(
                signal,
                programAppByID: programAppByID,
                fallbackApp: fallbackApp
            ) else { continue }
            switch item.tier {
            case .programStatus:
                if bestT1 == nil || item.rank <= bestT1!.rank { bestT1 = item }
            case .hook:
                if bestT2 == nil || item.rank <= bestT2!.rank { bestT2 = item }
            case .fallback:
                if bestT3 == nil || item.rank <= bestT3!.rank { bestT3 = item }
            }
        }

        let resolved: Presentation?
        if let t1 = bestT1, t1.state != "idle" {
            if t1.state == "working", let t2 = bestT2, t2.state == "needsAttention", t2.agent == t1.agent {
                resolved = t2
            } else {
                resolved = t1
            }
        } else if let t2 = bestT2, t2.state != "idle" {
            resolved = t2
        } else if let t3 = bestT3, t3.state != "idle",
                  bestT1?.agent != t3.agent, bestT2?.agent != t3.agent {
            resolved = t3
        } else {
            resolved = bestT1 ?? bestT2 ?? bestT3
        }

        agent = resolved?.agent ?? fallbackApp
        state = resolved?.state ?? "idle"
        attention = resolved?.attention
        message = resolved?.message ?? ""
    }

    private static func inheritedProgramAgent(
        recordID: String,
        programAppByID: [String: String],
        fallbackApp: String?
    ) -> String? {
        if let exact = programAppByID[recordID] { return exact }
        var prefix = recordID[...]
        while let slash = prefix.lastIndex(of: "/") {
            prefix = prefix[..<slash]
            if let parent = programAppByID[String(prefix)] { return parent }
        }
        if let root = programAppByID[""] { return root }
        return fallbackApp
    }

    private static func parsePresentation(
        _ signal: Signal,
        programAppByID: [String: String],
        fallbackApp: String?
    ) -> Presentation? {
        if signal.id == "omg-program-status" {
            let recordID = field(signal.metadata, separator: ":", key: "id") ?? ""
            guard let agent = field(signal.metadata, separator: ":", key: "app")
                .flatMap(MobileSessionIcon.normalizeAgentID)
                ?? inheritedProgramAgent(
                    recordID: recordID,
                    programAppByID: programAppByID,
                    fallbackApp: fallbackApp
                ) else { return nil }
            let state: String
            switch field(signal.metadata, separator: ":", key: "state") {
            case "working": state = "working"
            case "blocked": state = "needsAttention"
            case "error": state = "error"
            case "done": state = "done"
            case "idle": state = "idle"
            default: return nil
            }
            let attention: String? = if state == "needsAttention" {
                switch field(signal.metadata, separator: ":", key: "kind") {
                case "permission": "permission"
                case "question": "question"
                default: nil
                }
            } else {
                nil
            }
            let background = field(signal.metadata, separator: ":", key: "phase") == "background"
            let message = field(signal.metadata, separator: ":", key: "msg")
                .flatMap(decodeBase64UTF8)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultMessage(state: state, attention: attention)
            return Presentation(
                tier: .programStatus,
                agent: agent,
                state: state,
                attention: attention,
                message: message,
                background: background
            )
        }

        guard signal.id.hasPrefix("omg-agent-"), signal.id != "omg-agent-sync",
              let rawAgent = field(signal.metadata, separator: ";", key: "omg_agent"),
              let agent = MobileSessionIcon.normalizeAgentID(rawAgent) else { return nil }

        let state: String
        switch field(signal.metadata, separator: ";", key: "omg_state") {
        case "working", "processing", "active": state = "working"
        case "waiting", "awaiting", "blocked", "needsAttention": state = "needsAttention"
        case "error", "failed": state = "error"
        case "done", "completed": state = "done"
        case "idle": state = "idle"
        default: return nil
        }

        let tier: Tier = field(signal.metadata, separator: ";", key: "omg_tier") == "fallback"
            ? .fallback
            : .hook
        let attention: String? = if state == "needsAttention" {
            switch field(signal.metadata, separator: ";", key: "omg_attention") {
            case "permission": "permission"
            case "question": "question"
            default: nil
            }
        } else {
            nil
        }
        let background = field(signal.metadata, separator: ";", key: "omg_phase") == "background"
        let message = field(signal.metadata, separator: ";", key: "message")
            .flatMap { $0.removingPercentEncoding ?? $0 }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultMessage(state: state, attention: attention)
        return Presentation(
            tier: tier,
            agent: agent,
            state: state,
            attention: attention,
            message: message,
            background: background
        )
    }

    private static func defaultMessage(state: String, attention: String?) -> String {
        switch state {
        case "working": "Working"
        case "needsAttention": attention == "permission" ? "Waiting for permission" : "Waiting for you"
        case "error": "Error"
        case "done": "Done"
        default: ""
        }
    }

    private static func field(_ metadata: String, separator: Character, key: String) -> String? {
        for part in metadata.split(separator: separator, omittingEmptySubsequences: false).reversed() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if k == key {
                return String(trimmed[trimmed.index(after: eq)...])
            }
        }
        return nil
    }

    private static func decodeBase64UTF8(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 2800 else { return nil }
        let rem = raw.utf8.count % 4
        let padded = rem == 0 ? raw : raw + String(repeating: "=", count: 4 - rem)
        guard let data = Data(base64Encoded: padded),
              let text = String(data: data, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }) else {
            return nil
        }
        return text
    }
}

/// Pure acknowledgment rules shared between `OMGSession` and unit tests so
/// attach, foreground visibility, and raw/VT-encoded input never emit passive or
/// unwatermarked `'C'` frames.
public enum RuntimeActivityAckPolicy {
    public static func shouldAcknowledgeOnActivity(
        rendering: Bool,
        snapshot: RuntimeActivitySnapshot
    ) -> Bool {
        rendering && snapshot.isSyncRestore && snapshot.isTerminal
    }

    public static func shouldAcknowledgeOnBecomeVisible(
        isAttached: Bool,
        liveActivity: RuntimeActivitySnapshot?
    ) -> Bool {
        isAttached && liveActivity?.isTerminal == true
    }

    public static func shouldAcknowledgeOnInput(
        _ data: Data,
        acknowledgesActivity: Bool = true,
        liveActivity: RuntimeActivitySnapshot?
    ) -> Bool {
        guard acknowledgesActivity,
              liveActivity?.isTerminal == true else { return false }
        return shouldAcknowledgeRawInput(data)
    }

    /// Rejects empty payloads, terminal focus-in/out reports (`CSI I` / `CSI O`),
    /// and passive SGR/X10 mouse motion, release, or wheel sequences while still
    /// allowing intentional mouse button presses and keyboard/paste bytes.
    public static func shouldAcknowledgeRawInput(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let bytes = [UInt8](data)
        if bytes == [0x1B, 0x5B, 0x49] || bytes == [0x1B, 0x5B, 0x4F] {
            return false
        }
        // SGR mouse: ESC [ < Cb ; Cx ; Cy (M|m)
        if bytes.starts(with: [0x1B, 0x5B, 0x3C]) {
            guard let final = bytes.last, final == 0x4D else { return false }
            var index = 3
            var cb = 0
            var hasDigits = false
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                hasDigits = true
                cb = cb &* 10 &+ Int(bytes[index] - 0x30)
                if cb > 4096 { return false }
                index += 1
            }
            guard hasDigits, index < bytes.count, bytes[index] == 0x3B else { return false }
            // Bit 32 = motion, bit 64 = wheel, low bits 3 = release/no-button.
            return (cb & 32) == 0 && (cb & 64) == 0 && (cb & 3) != 3
        }
        // X10 / normal mouse: ESC [ M Cb Cx Cy
        if bytes.starts(with: [0x1B, 0x5B, 0x4D]) {
            guard bytes.count >= 6 else { return false }
            let cb = Int(bytes[3]) - 32
            guard cb >= 0 else { return false }
            return (cb & 32) == 0 && (cb & 64) == 0 && (cb & 3) != 3
        }
        return true
    }
}

/// Cell and backing-pixel dimensions for an `omgd` v2 `'R'` resize payload.
public struct RuntimeViewport: Equatable, Sendable {
    public static let maximumColumns: UInt16 = 500
    public static let maximumRows: UInt16 = 300
    public static let maximumPixels: UInt16 = 16_000
    public static let fallbackCellPixelWidth = 8
    public static let fallbackCellPixelHeight = 16

    public let columns: UInt16
    public let rows: UInt16
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16

    public init(columns: UInt16, rows: UInt16, pixelWidth: UInt16, pixelHeight: UInt16) {
        self.columns = min(max(columns, 1), Self.maximumColumns)
        self.rows = min(max(rows, 1), Self.maximumRows)
        let defaultPxW = UInt16(min(Int(self.columns) * Self.fallbackCellPixelWidth, Int(Self.maximumPixels)))
        let defaultPxH = UInt16(min(Int(self.rows) * Self.fallbackCellPixelHeight, Int(Self.maximumPixels)))
        self.pixelWidth = pixelWidth > 0 ? min(pixelWidth, Self.maximumPixels) : max(1, defaultPxW)
        self.pixelHeight = pixelHeight > 0 ? min(pixelHeight, Self.maximumPixels) : max(1, defaultPxH)
    }

    public static func clamped(
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> RuntimeViewport? {
        guard columns > 0, rows > 0 else { return nil }
        let cols = UInt16(min(max(columns, 1), Int(maximumColumns)))
        let rws = UInt16(min(max(rows, 1), Int(maximumRows)))
        let pxW: UInt16
        let pxH: UInt16
        if pixelWidth > 0, pixelHeight > 0 {
            pxW = UInt16(min(max(pixelWidth, 1), Int(maximumPixels)))
            pxH = UInt16(min(max(pixelHeight, 1), Int(maximumPixels)))
        } else {
            pxW = UInt16(min(max(Int(cols) * fallbackCellPixelWidth, 1), Int(maximumPixels)))
            pxH = UInt16(min(max(Int(rws) * fallbackCellPixelHeight, 1), Int(maximumPixels)))
        }
        return RuntimeViewport(columns: cols, rows: rws, pixelWidth: pxW, pixelHeight: pxH)
    }

    public static func fromCellPixels(
        columns: Int,
        rows: Int,
        cellPixelWidth: Int?,
        cellPixelHeight: Int?
    ) -> RuntimeViewport? {
        guard columns > 0, rows > 0 else { return nil }
        let cols = min(max(columns, 1), Int(maximumColumns))
        let rws = min(max(rows, 1), Int(maximumRows))
        let cellW = max(1, cellPixelWidth ?? fallbackCellPixelWidth)
        let cellH = max(1, cellPixelHeight ?? fallbackCellPixelHeight)
        return clamped(
            columns: cols,
            rows: rws,
            pixelWidth: cols * cellW,
            pixelHeight: rws * cellH
        )
    }
}

/// Passive-viewer isolation and writer-takeover state machine shared by `OMGSession`.
///
/// Attaching, foregrounding, rotating, or toggling the keyboard while observing a
/// session MUST NEVER claim the writer token (`takeover/1`) or emit `'R'` resize
/// frames. Only intentional user input or an explicit takeover request claims writer,
/// and only an active writer emits `'R'` resize frames while rendering.
public struct RuntimeWriterGate: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case claimWriter
        case sendInput(Data)
        case sendResize(RuntimeViewport)
    }

    public enum EnqueueError: Error, Equatable, Sendable {
        case inputLimitExceeded
    }

    public private(set) var isAttached = false
    public private(set) var isWriter = false
    public private(set) var isClaiming = false
    public private(set) var isRendering = true
    public private(set) var viewport: RuntimeViewport?
    public private(set) var pendingInput = Data()

    public init(isRendering: Bool = true) {
        self.isRendering = isRendering
    }

    /// Passive attach: never claims writer and never resizes the remote PTY.
    @discardableResult
    public mutating func didAttach() -> [Effect] {
        isAttached = true
        return []
    }

    public mutating func didDetach() {
        isAttached = false
        isWriter = false
        isClaiming = false
        clearPending()
    }

    /// Foreground/visibility updates: never auto-claims; re-syncs viewport only if already writer.
    public mutating func setRendering(_ showing: Bool) -> [Effect] {
        let becameVisible = !isRendering && showing
        isRendering = showing
        guard becameVisible, isAttached, isWriter, let viewport else { return [] }
        return [.sendResize(viewport)]
    }

    /// Re-asserts this client's viewport only when already holding the writer token.
    public mutating func reassertGrid() -> [Effect] {
        guard isAttached, isWriter, isRendering, let viewport else { return [] }
        return [.sendResize(viewport)]
    }

    /// Stores the local screen's viewport. Passive viewers cache it locally without
    /// claiming writer or resizing the desktop terminal.
    public mutating func setViewport(_ next: RuntimeViewport?) -> [Effect] {
        viewport = next
        guard isAttached, isWriter, isRendering, let next else { return [] }
        return [.sendResize(next)]
    }

    /// Intentional user input/paste: sends immediately when writer, or queues input and
    /// issues a single `claimWriter` (`takeover/1`) request when observing.
    public mutating func enqueueInput(
        _ data: Data,
        maximumBytes: Int
    ) -> Result<[Effect], EnqueueError> {
        guard isAttached, !data.isEmpty else { return .success([]) }
        guard data.count <= maximumBytes,
              pendingInput.count + data.count <= maximumBytes else {
            clearPending()
            isClaiming = false
            return .failure(.inputLimitExceeded)
        }
        if isWriter {
            return .success([.sendInput(data)])
        }
        pendingInput.append(data)
        guard !isClaiming else { return .success([]) }
        isClaiming = true
        return .success([.claimWriter])
    }

    /// Explicit user-initiated takeover without injecting stray bytes into the PTY.
    public mutating func requestTakeover() -> [Effect] {
        guard isAttached else { return [] }
        if isWriter {
            if isRendering, let viewport {
                return [.sendResize(viewport)]
            }
            return []
        }
        guard !isClaiming else { return [] }
        isClaiming = true
        return [.claimWriter]
    }

    /// Handles server `'W'` (`true`) grant or `'B'` (`false`) revocation.
    public mutating func writerChanged(_ granted: Bool) -> [Effect] {
        isWriter = granted
        isClaiming = false
        guard granted else {
            clearPending()
            return []
        }
        var effects: [Effect] = []
        if !pendingInput.isEmpty {
            effects.append(.sendInput(pendingInput))
            clearPending()
        }
        if isRendering, let viewport {
            effects.append(.sendResize(viewport))
        }
        return effects
    }

    public mutating func discardPending() {
        clearPending()
        isClaiming = false
    }

    private mutating func clearPending() {
        if !pendingInput.isEmpty {
            pendingInput.resetBytes(in: pendingInput.indices)
            pendingInput.removeAll()
        }
    }
}
