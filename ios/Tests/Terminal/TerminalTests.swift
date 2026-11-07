import XCTest
import GhosttyVt
@testable import OMGTerminal

final class TerminalTests: XCTestCase {
    private func screen(_ text: String) throws -> TermiodStreamTerminal {
        try screen(data: Data(text.utf8))
    }
    private func screen(data: Data,
                        onSignal: @escaping (TermiodStreamTerminal.Signal) -> Void = { _ in }) throws -> TermiodStreamTerminal {
        var terminal: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &terminal, 80, 24), GHOSTTY_SUCCESS)
        defer { ghostty_terminal_free(terminal) }
        var limit = 1 << 20
        XCTAssertEqual(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &limit), GHOSTTY_SUCCESS)
        let input = Array(data)
        input.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(terminal, nil, &bytes, &count), GHOSTTY_SUCCESS)
        guard let bytes else { throw NSError(domain: "snapshot", code: 1) }
        defer { ghostty_free(nil, bytes, count) }
        return try TermiodStreamTerminal(nativeSnapshot: Data(bytes: bytes, count: count), onSignal: onSignal)
    }

    func testNativeSnapshotKeepsUnicodeAlternateScreenAndContinuation() throws {
        let terminal = try screen("\u{1b}[?1049h中文\u{1b}[31")
        terminal.write(Data("mRED".utf8))
        XCTAssertTrue(try terminal.activeText().contains("中文RED"))
        terminal.write(Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(try terminal.activeText().contains("RED"))
    }

    func testKeyEncoderTracksApplicationCursorAndCtrlAndPasteModes() throws {
        let terminal = try screen("")
        XCTAssertEqual(try terminal.encodeInput(.key(.init(key: "arrow_up"))), Data("\u{1b}[A".utf8))
        terminal.write(Data("\u{1b}[?1h\u{1b}[?2004h".utf8))
        XCTAssertEqual(try terminal.encodeInput(.key(.init(key: "arrow_up"))), Data("\u{1b}OA".utf8))
        XCTAssertEqual(try terminal.encodeInput(.key(.init(key: "c", mods: 2, unshifted: 99))), Data([3]))
        XCTAssertEqual(try terminal.encodeInput(.paste("中文")), Data("\u{1b}[200~中文\u{1b}[201~".utf8))
    }

    func testSnapshotRestoresSplitUTF8AndOSCWithoutPrintingControlPayload() throws {
        let unicode = try screen(data: Data([0xe4, 0xb8]))
        unicode.write(Data([0xad]))
        XCTAssertTrue(try unicode.activeText().contains("中"))
        let title = try screen("\u{1b}]2;unfinished-title")
        title.write(Data("\u{7}VISIBLE".utf8))
        let text = try title.activeText()
        XCTAssertTrue(text.contains("VISIBLE"))
        XCTAssertFalse(text.contains("unfinished-title"))
    }

}
