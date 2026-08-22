import Foundation
import Testing
@testable import Ghostty

struct PluginProtocolTests {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test func roundTripsEveryMessageBody() throws {
        let snapshot = PluginSessionSnapshot(
            id: sessionID,
            title: "build",
            foregroundPID: 42,
            progress: .init(state: .set, percent: 75),
            isFocused: true
        )
        let status = PluginSessionStatus(agent: "Codex", title: nil, state: .running)
        let bodies: [PluginWireMessage.Body] = [
            .hello(.init(
                pluginID: "dev.ghostty.agent-status",
                pluginVersion: "0.1.0",
                supportedProtocolVersions: [1],
                requestedCapabilities: [.terminalEvents, .sessionStatus],
                nonce: "test-nonce"
            )),
            .welcome(.init(
                selectedProtocolVersion: 1,
                grantedCapabilities: [.terminalEvents],
                hostVersion: "1.0.0"
            )),
            .subscribe(.init(events: [.opened, .progressChanged])),
            .sessionEvent(.init(kind: .opened, session: snapshot)),
            .setSessionStatus(.init(
                sessionID: sessionID,
                revision: 3,
                status: status,
                ttlMilliseconds: 15_000
            )),
            .clearSessionStatus(.init(sessionID: sessionID, revision: 4)),
            .acknowledgement(.init(acceptedSequence: 7)),
            .failure(.init(code: .permissionDenied, message: "not granted")),
        ]

        for (offset, body) in bodies.enumerated() {
            let message = PluginWireMessage(
                sequence: UInt64(offset + 1),
                correlationID: 99,
                body: body
            )
            let frame = try PluginWireCodec.encode(message)
            let decoded = try PluginWireCodec.decode(frame.dropFirst(4))
            #expect(decoded == message)
        }
    }

    @Test func decodesAFrameAcrossPartialReads() throws {
        let message = PluginWireMessage(
            sequence: 1,
            body: .clearSessionStatus(.init(sessionID: sessionID, revision: 8))
        )
        let encoded = try PluginWireCodec.encode(message)
        var decoder = PluginWireCodec.FrameDecoder()
        var payloads: [Data] = []

        for byte in encoded {
            payloads.append(contentsOf: try decoder.append(Data([byte])))
        }

        #expect(payloads.count == 1)
        #expect(decoder.bufferedByteCount == 0)
        #expect(try PluginWireCodec.decode(payloads[0]) == message)
    }

    @Test func decodesCoalescedFramesAndRetainsAnIncompleteTail() throws {
        let first = PluginWireMessage(
            sequence: 1,
            body: .subscribe(.init(events: [.opened, .closed]))
        )
        let second = PluginWireMessage(
            sequence: 2,
            body: .failure(.init(code: .staleRevision, message: "stale"))
        )
        let third = PluginWireMessage(
            sequence: 3,
            body: .clearSessionStatus(.init(sessionID: sessionID, revision: 9))
        )
        let firstFrame = try PluginWireCodec.encode(first)
        let secondFrame = try PluginWireCodec.encode(second)
        let thirdFrame = try PluginWireCodec.encode(third)
        let splitIndex = thirdFrame.count / 2

        var input = Data()
        input.append(firstFrame)
        input.append(secondFrame)
        input.append(thirdFrame.prefix(splitIndex))

        var decoder = PluginWireCodec.FrameDecoder()
        let initialPayloads = try decoder.append(input)
        #expect(initialPayloads.count == 2)
        #expect(try initialPayloads.map(PluginWireCodec.decode) == [first, second])
        #expect(decoder.bufferedByteCount == splitIndex)

        let finalPayloads = try decoder.append(thirdFrame.dropFirst(splitIndex))
        #expect(finalPayloads.count == 1)
        #expect(try PluginWireCodec.decode(finalPayloads[0]) == third)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func rejectsEmptyAndOversizedFrames() {
        var emptyDecoder = PluginWireCodec.FrameDecoder()
        #expect(throws: PluginWireCodec.CodecError.emptyFrame) {
            try emptyDecoder.append(Data([0, 0, 0, 0]))
        }

        var oversizedDecoder = PluginWireCodec.FrameDecoder()
        let oversizedLength = UInt32(PluginProtocolContract.maximumFrameLength + 1)
        let header = Data([
            UInt8((oversizedLength >> 24) & 0xff),
            UInt8((oversizedLength >> 16) & 0xff),
            UInt8((oversizedLength >> 8) & 0xff),
            UInt8(oversizedLength & 0xff),
        ])
        #expect(
            throws: PluginWireCodec.CodecError.frameTooLarge(Int(oversizedLength))
        ) {
            try oversizedDecoder.append(header)
        }
    }
}
