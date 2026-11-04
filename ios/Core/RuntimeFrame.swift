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
