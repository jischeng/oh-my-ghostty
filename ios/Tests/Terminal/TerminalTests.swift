import XCTest
import CoreText
import Metal
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

    func testWheelEncodingUsesPageKeysOnAlternateScreenAndSGRWheelWhenMouseTracking() throws {
        let alt = try screen("\u{1b}[?1049h")
        let pointer = Termiod.InputEvent.Pointer(x: 40, y: 40, cellWidth: 10, cellHeight: 20)
        XCTAssertEqual(
            try alt.encodeInput(.wheel(.init(rows: -1, columns: 0, mods: 0, at: pointer))),
            Data("\u{1b}[5~".utf8)
        )
        XCTAssertEqual(
            try alt.encodeInput(.wheel(.init(rows: 1, columns: 0, mods: 0, at: pointer))),
            Data("\u{1b}[6~".utf8)
        )

        alt.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let wheelUp = try String(
            decoding: alt.encodeInput(.wheel(.init(rows: -1, columns: 0, mods: 0, at: pointer))),
            as: UTF8.self
        )
        XCTAssertTrue(wheelUp.hasPrefix("\u{1b}[<64;"), "Expected SGR wheel-up sequence, got: \(wheelUp.debugDescription)")
    }

    @MainActor
    func testBundledNerdFontRasterizesPowerlineAndPromptSymbolsWithinCellBounds() throws {
        TermiodGlyphAtlas.registerBundledSymbolFonts()
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: TermiodGlyphAtlas.symbolsFontFamily] as CFDictionary
        )
        let symbolFont = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        XCTAssertEqual(CTFontCopyFamilyName(symbolFont) as String, TermiodGlyphAtlas.symbolsFontFamily)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo",
            fallbackFamilies: [],
            fontSize: 16,
            paddingX: 0,
            paddingY: 0,
            backgroundOpacity: 1
        )
        let atlas = try TermiodGlyphAtlas(device: device, appearance: appearance, scale: 2.0, size: 1024)
        let cellSize = SIMD2(UInt16(atlas.metrics.width), UInt16(atlas.metrics.height))

        func readAlpha(_ slot: TermiodGlyphAtlas.Slot) -> [UInt8] {
            let w = Int(slot.size.x)
            let h = Int(slot.size.y)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            atlas.texture.getBytes(
                &bytes,
                bytesPerRow: w * 4,
                from: MTLRegionMake2D(Int(slot.origin.x), Int(slot.origin.y), w, h),
                mipmapLevel: 0
            )
            return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
        }

        // Powerline separators (, , , ) fill the cell edge-to-edge.
        for codepoint: UInt32 in [0xE0B0, 0xE0B2, 0xE0B4, 0xE0B6] {
            let slot = try XCTUnwrap(atlas.slot(graphemes: [codepoint], bold: false, italic: false, cells: 1))
            XCTAssertEqual(slot.size, cellSize, "Powerline U+\(String(codepoint, radix: 16)) must fill cell")
            XCTAssertEqual(slot.offset, SIMD2(0, 0))
            XCTAssertFalse(slot.colored)
            let alpha = readAlpha(slot)
            XCTAssertTrue(alpha.contains(where: { $0 == 255 }))
        }

        // Starship Nerd Font PUA icons (󰀵, , , , ) are constrained to the cell width.
        for codepoint: UInt32 in [0xF0035, 0xF418, 0xF43A, 0xEAF4, 0xE0A0] {
            let slot = try XCTUnwrap(atlas.slot(graphemes: [codepoint], bold: false, italic: false, cells: 1))
            XCTAssertEqual(slot.size, cellSize, "Icon U+\(String(codepoint, radix: 16)) must fit within cell")
            XCTAssertEqual(slot.offset, SIMD2(0, 0))
            XCTAssertFalse(slot.colored)
            let alpha = readAlpha(slot)
            XCTAssertTrue(alpha.contains(where: { $0 > 128 }), "Icon U+\(String(codepoint, radix: 16)) must draw visible pixels")
        }
    }

}
