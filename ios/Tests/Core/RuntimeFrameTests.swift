import XCTest
@testable import OMGMobileCore

final class RuntimeFrameTests: XCTestCase {
    func testFragmentedAndCoalescedFramesRetainBinaryAndSequence() throws {
        let frames = [RuntimeFrame(83, 0x1122334455667788, Data([0, 255, 27])),
                      RuntimeFrame(79, 100, Data("中文".utf8))]
        let wire = frames.reduce(into: Data()) { $0.append($1.encoded()) }
        for width in [1, 2, 7, 13, wire.count] {
            var decoder = RuntimeFrame.Decoder()
            var decoded: [RuntimeFrame] = []
            for offset in stride(from: 0, to: wire.count, by: width) {
                decoded += try decoder.append(wire.subdata(in: offset..<min(wire.count, offset + width)))
            }
            XCTAssertEqual(decoded, frames)
        }
    }
    func testOversizedHeaderIsRejectedBeforeAllocatingBody() {
        var decoder = RuntimeFrame.Decoder()
        XCTAssertThrowsError(try decoder.append(Data([79] + Array(repeating: 0, count: 8) + [255, 255, 255, 255])))
    }
    func testGapAndMissingSnapshotAreRejected() throws {
        var watermark = RuntimeWatermark()
        XCTAssertThrowsError(try watermark.output(RuntimeFrame(79, 1, Data([1]))))
        watermark.snapshot(12)
        try watermark.output(RuntimeFrame(79, 15, Data([1, 2, 3])))
        XCTAssertThrowsError(try watermark.output(RuntimeFrame(79, 17, Data([4]))))
        XCTAssertEqual(watermark.position, 15)
    }

    func testSwitchingSessionsRejectsInFlightOldSnapshotGrantAndExit() {
        var attachment = RuntimeAttachment()
        let previous = attachment.open()
        XCTAssertEqual(attachment.detach(), previous)
        let current = attachment.open()
        let stale = [83, 87, 88].map { kind in
            RuntimeFrame(68, previous, RuntimeFrame(UInt8(kind), 0, Data("old session".utf8)).encoded())
        }
        let live = RuntimeFrame(68, current, RuntimeFrame(83, 100, Data("new session".utf8)).encoded())
        XCTAssertEqual((stale + [live]).filter(attachment.accepts), [live])
        _ = attachment.detach()
        XCTAssertFalse(attachment.accepts(live))
    }
}
