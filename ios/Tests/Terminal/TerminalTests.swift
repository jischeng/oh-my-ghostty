import XCTest
import CoreText
import Metal
import GhosttyVt
import OMGMobileCore
import TermioShared
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

    func testCompanionControlAcknowledgeRoundTrip() {
        let sessionID = "0123456789abcdef/session-pi/gen-1"
        let encoded = CompanionControl.acknowledge(sessionID: sessionID).encoded()
        let decoded = CompanionControl.decode(encoded)
        XCTAssertEqual(decoded, .acknowledge(sessionID: sessionID))
    }

    func testSessionStatusErrorRankAndVectorBrandLogosFitCanvas() throws {
        XCTAssertLessThan(SessionStatus.needsAttention.rank, SessionStatus.error.rank)
        XCTAssertLessThan(SessionStatus.error.rank, SessionStatus.working.rank)
        XCTAssertLessThan(SessionStatus.working.rank, SessionStatus.idle.rank)
        XCTAssertLessThan(SessionStatus.idle.rank, SessionStatus.done.rank)

        let canvas = CGRect(x: 0, y: 0, width: 24, height: 24)
        let toleranceCanvas = canvas.insetBy(dx: -1, dy: -1)
        for ref in ["claude", "codex", "grok", "qoder", "reasonix", "aider"] {
            let logo = try XCTUnwrap(BrandLogo(reference: ref), "Missing BrandLogo for \(ref)")
            let path = BrandLogoShape(logo: logo).path(in: canvas)
            let bounds = path.boundingRect
            XCTAssertFalse(bounds.isEmpty, "Empty vector path for \(ref)")
            XCTAssertTrue(
                toleranceCanvas.contains(bounds),
                "Vector bounds \(bounds) for \(ref) escaped canvas \(canvas)"
            )
        }
    }

    func testInputEventActivityAcknowledgmentRejectsPassiveMouseWheelAndKeyRepeat() {
        let pointer = Termiod.InputEvent.Pointer(x: 16, y: 24, cellWidth: 8, cellHeight: 16)

        XCTAssertTrue(Termiod.InputEvent.key(.init(action: .press, key: "a", text: "a")).acknowledgesActivity)
        XCTAssertFalse(Termiod.InputEvent.key(.init(action: .repeat, key: "a", text: "a")).acknowledgesActivity)
        XCTAssertFalse(Termiod.InputEvent.key(.init(action: .release, key: "a", text: "a")).acknowledgesActivity)
        XCTAssertFalse(Termiod.InputEvent.key(.init(action: .press, key: "shift_left")).acknowledgesActivity)
        XCTAssertFalse(Termiod.InputEvent.key(.init(action: .press, key: "a", text: "a", composing: true)).acknowledgesActivity)

        XCTAssertTrue(Termiod.InputEvent.paste("echo ok\n").acknowledgesActivity)

        XCTAssertTrue(
            Termiod.InputEvent.mouse(.init(action: .press, button: 1, mods: 0, at: pointer, buttonsHeld: true))
                .acknowledgesActivity
        )
        XCTAssertFalse(
            Termiod.InputEvent.mouse(.init(action: .motion, button: nil, mods: 0, at: pointer, buttonsHeld: false))
                .acknowledgesActivity
        )
        XCTAssertFalse(
            Termiod.InputEvent.mouse(.init(action: .release, button: 1, mods: 0, at: pointer, buttonsHeld: false))
                .acknowledgesActivity
        )
        XCTAssertFalse(
            Termiod.InputEvent.wheel(.init(rows: 3, columns: 0, mods: 0, at: pointer))
                .acknowledgesActivity
        )
        XCTAssertFalse(Termiod.InputEvent.focus(true).acknowledgesActivity)
        XCTAssertFalse(Termiod.InputEvent.focus(false).acknowledgesActivity)
    }

    func testStreamTerminalTracksAlternateScreenAcrossSnapshotAndLiveWrites() throws {
        let terminal = try screen("\u{1b}[?1049hALT-TUI")
        XCTAssertTrue(terminal.isAlternateScreen)
        terminal.write(Data("\u{1b}[?1049lPRIMARY".utf8))
        XCTAssertFalse(terminal.isAlternateScreen)
        terminal.write(Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(terminal.isAlternateScreen)
    }

    func testIMEStatePreservesChineseCandidateCommitAndClearsBeforePassiveResign() {
        var ime = TermiodStreamIMEState()
        XCTAssertFalse(ime.hasMarkedText)
        XCTAssertFalse(ime.needsPreeditDraw)

        // Typing Pinyin: n -> ni -> nih -> backspace -> ni -> candidate "你好" -> unmarkTextForCommit()
        ime.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(ime.needsPreeditDraw)
        ime.consumePreeditDraw()

        ime.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        ime.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(ime.deleteBackwardInMarkedText())
        XCTAssertEqual(ime.markedText, "ni")
        XCTAssertTrue(ime.needsPreeditDraw)
        ime.consumePreeditDraw()

        // Selecting a Chinese candidate in iOS Pinyin calls setMarkedText("你好") followed by unmarkText():
        // MUST return "你好" so StreamTerminalView.unmarkText() commits it via insertText("你好")!
        ime.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        let committed = ime.unmarkTextForCommit()
        XCTAssertEqual(committed, "你好")
        XCTAssertFalse(ime.hasMarkedText)
        XCTAssertTrue(ime.needsPreeditDraw)
        ime.consumePreeditDraw()

        // Passive focus loss (resignFirstResponder) clears marked text BEFORE super.resignFirstResponder()
        // so any subsequent UIKit unmarkText() callback during teardown commits nil (zero leaked Pinyin!).
        ime.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertTrue(ime.discardMarkedTextBeforeResign())
        XCTAssertNil(ime.unmarkTextForCommit())
        XCTAssertFalse(ime.hasMarkedText)
    }

    @MainActor
    func testIncrementalIMEPreeditRendersOverlayWithoutRebuildingTerminalRows() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }
        var lines = ""
        for row in 1...20 {
            lines += "row-\(row): const value = \(row * 42);\r\n"
        }
        lines += "prompt> "
        let terminal = try screen(lines)
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo",
            fallbackFamilies: ["PingFang SC"],
            fontSize: 14,
            paddingX: 4,
            paddingY: 4,
            backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2.0)
        let width = renderer.atlas.metrics.width * 80 + 16
        let height = renderer.atlas.metrics.height * 24 + 16

        func pixels(_ image: CGImage) -> Data {
            let bpr = image.width * 4
            var data = [UInt8](repeating: 0, count: bpr * image.height)
            guard let ctx = CGContext(
                data: &data,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return Data(data) }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(data)
        }

        // Initial forced draw builds all 24 rows once.
        let baselineImage = try renderer.image(
            of: terminal,
            width: width,
            height: height,
            focused: false,
            force: true,
            preedit: nil
        )
        let baselineFullCount = renderer.fullRebuildCount
        let baselineRowCount = renderer.rowRebuildCount
        let baselinePreeditCount = renderer.preeditBuildCount
        XCTAssertEqual(baselineFullCount, 1)
        XCTAssertEqual(baselineRowCount, 24)

        // Incremental Pinyin preedit updates (`force: false`) must rebuild ZERO terminal rows!
        let compositionSteps: [String?] = ["n", "ni", "nih", "niha", "nihao", "你好", nil]
        var composedPixels = Data()
        var clearedPixels = Data()
        for step in compositionSteps {
            let frame = try renderer.image(
                of: terminal,
                width: width,
                height: height,
                focused: false,
                force: false,
                preedit: step
            )
            if step == "nihao" {
                composedPixels = pixels(frame)
            } else if step == nil {
                clearedPixels = pixels(frame)
            }
        }

        XCTAssertEqual(
            renderer.fullRebuildCount,
            baselineFullCount,
            "Incremental IME preedit must never call builder.invalidate()"
        )
        XCTAssertEqual(
            renderer.rowRebuildCount,
            baselineRowCount,
            "Incremental IME preedit must rebuild 0 terminal rows across n->ni->nih->niha->nihao->你好->clear"
        )
        XCTAssertEqual(
            renderer.preeditBuildCount,
            baselinePreeditCount + UInt64(compositionSteps.count)
        )
        let basePixels = pixels(baselineImage)
        XCTAssertFalse(composedPixels == basePixels, "Preedit overlay must visibly render at cursor")
        XCTAssertTrue(clearedPixels == basePixels, "Clearing preedit must restore exact baseline frame")
    }

    func testPassiveViewerWheelOnAltScreenAndMouseTrackingDoesNotClaimWriterOrEnqueueInput() throws {
        let terminal = try screen("\u{1b}[?1049h\u{1b}[?1007h")
        XCTAssertTrue(terminal.isAlternateScreen)
        XCTAssertTrue(terminal.wheelGoesToProgram)

        var gate = RuntimeWriterGate()
        XCTAssertEqual(gate.didAttach(), [])
        let viewport = RuntimeViewport(columns: 39, rows: 42, pixelWidth: 702, pixelHeight: 1512)
        XCTAssertEqual(gate.setViewport(viewport), [])

        let pointer = Termiod.InputEvent.Pointer(x: 24, y: 48, cellWidth: 9, cellHeight: 18)
        let wheelDown = Termiod.InputEvent.wheel(.init(rows: 3, columns: 0, mods: 0, at: pointer))

        func forward(_ event: Termiod.InputEvent) throws -> [RuntimeWriterGate.Effect] {
            guard event.shouldForwardToRuntimeSession(
                isWriter: gate.isWriter,
                hasPendingInput: !gate.pendingInput.isEmpty
            ) else {
                return []
            }
            let bytes = try terminal.encodeInput(event)
            guard !bytes.isEmpty else { return [] }
            return try gate.enqueueInput(bytes, maximumBytes: 1 << 20).get()
        }

        // Passive viewer vertical drag on Alt-Screen (?1007h) must not claim writer or enqueue input.
        XCTAssertEqual(try forward(wheelDown), [])
        XCTAssertFalse(gate.isWriter)
        XCTAssertFalse(gate.isClaiming)
        XCTAssertTrue(gate.pendingInput.isEmpty)

        // Mouse-tracking TUI (?1000h + ?1006h) must likewise drop passive wheel, motion, focus, and orphan key release.
        terminal.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertTrue(terminal.wheelGoesToProgram)
        XCTAssertEqual(try forward(wheelDown), [])
        XCTAssertEqual(try forward(.focus(true)), [])
        XCTAssertEqual(
            try forward(.mouse(.init(action: .motion, button: nil, mods: 0, at: pointer, buttonsHeld: false))),
            []
        )
        XCTAssertEqual(
            try forward(.key(.init(action: .release, key: "j", text: "j"))),
            []
        )
        XCTAssertFalse(gate.isWriter)
        XCTAssertFalse(gate.isClaiming)
        XCTAssertTrue(gate.pendingInput.isEmpty)

        // Real key press claims writer; once writer is granted, wheel events forward normally.
        XCTAssertEqual(try forward(.key(.init(action: .press, key: "j", text: "j"))), [.claimWriter])
        XCTAssertEqual(
            gate.writerChanged(true),
            [.sendInput(Data("j".utf8)), .sendResize(viewport)]
        )

        let writerWheel = try forward(wheelDown)
        XCTAssertEqual(writerWheel.count, 1)
        guard case .sendInput(let wheelBytes) = writerWheel.first else {
            return XCTFail("Expected .sendInput for active writer wheel event, got \(writerWheel)")
        }
        let wheelString = try XCTUnwrap(String(data: wheelBytes, encoding: .utf8))
        XCTAssertTrue(wheelString.hasPrefix("\u{1b}[<65;"))
    }

    func testReconnectPolicyBacksOffOnPostUpgradeAndPostSnapshotStreamErrorsUntilHealthyUptime() {
        var policy = ReconnectPolicy()
        let exact = 1.0...1.0

        // 1. Repeated HTTP 101 upgrades that drop or resync before protocol readiness
        //    (e.g. unexpected `'Q'` or missing `'S'`) MUST advance exponential backoff
        //    (`0.5 -> 1 -> 2 -> 4 -> 5 -> 5 -> 30s`) instead of spinning at ~2 Hz (`0.5s`)!
        var delaysBeforeReady: [Double] = []
        var now: TimeInterval = 100
        for _ in 0..<7 {
            policy.noteSocketOpened(at: now, requiresProtocolReady: true)
            now += 0.02
            let delay = policy.nextDelayAfterDrop(at: now, ceiling: 30, jitter: exact)
            delaysBeforeReady.append(delay)
            now += delay
        }
        XCTAssertEqual(delaysBeforeReady, [0.5, 1.0, 2.0, 4.0, 5.0, 5.0, 30.0])
        XCTAssertEqual(policy.attempts, 7)

        // 2. Even if `'S'` (`noteProtocolReady`) arrives right before a stream error in the same
        //    attach burst (e.g. `'G'` activity with >64 records or invalid sequence 10ms after `'S'`),
        //    uptime < `minimumHealthyUptime` (5s) MUST NOT reset `attempts` to 0!
        policy.noteSocketOpened(at: now, requiresProtocolReady: true)
        policy.noteProtocolReady(at: now + 0.01)
        XCTAssertFalse(policy.hasSustainedHealthyConnection(at: now + 0.02))
        let postBurstErrorDelay = policy.nextDelayAfterDrop(at: now + 0.02, ceiling: 30, jitter: exact)
        XCTAssertEqual(postBurstErrorDelay, 30.0, "Immediate post-snapshot stream error must stay backed off")
        XCTAssertEqual(policy.attempts, 8)

        // 3. Opening a session stream on an already-ready catalogue link (`requireFreshProtocolReady()`)
        //    clears prior readiness until the session's `'S'` arrives and sustains healthy uptime.
        now += 30.0
        policy.noteSocketOpened(at: now, requiresProtocolReady: true)
        policy.noteProtocolReady(at: now + 0.05) // `'L'` arrived while session == nil
        policy.requireFreshProtocolReady()       // `'U'` sent to attach session
        XCTAssertFalse(policy.hasSustainedHealthyConnection(at: now + 10.0))

        // 4. Once `'S'` arrives AND the stream stays healthy for >= `minimumHealthyUptime` (5s),
        //    a later transient Wi-Fi drop resets `attempts` back to the fast `0.5s` burst.
        policy.noteProtocolReady(at: now + 0.10)
        XCTAssertTrue(policy.hasSustainedHealthyConnection(at: now + 5.20))
        let recoveredDropDelay = policy.nextDelayAfterDrop(at: now + 5.20, ceiling: 30, jitter: exact)
        XCTAssertEqual(recoveredDropDelay, 0.5)
        XCTAssertEqual(policy.attempts, 1)
    }

    func testReconnectPolicyPreservesProtocolReadyAndStrictGateWhenCallbacksRaceNoteSocketOpened() {
        var policy = ReconnectPolicy()
        let exact = 1.0...1.0

        // Seed non-zero backoff attempts.
        _ = policy.nextDelay(ceiling: 30, jitter: exact)
        _ = policy.nextDelay(ceiling: 30, jitter: exact)
        XCTAssertEqual(policy.attempts, 2)

        // Case 1 (`delegateQueue == .main` fast local link): `connect()` calls `beginConnectAttempt`,
        // then `onOpen` + first frame (`noteProtocolReady`) arrive before an async `noteSocketOpened`.
        // `noteSocketOpened` MUST NOT wipe `protocolReadyAt`!
        let t0: TimeInterval = 500
        policy.beginConnectAttempt(requiresProtocolReady: true)
        policy.requireFreshProtocolReady()
        policy.noteProtocolReady(at: t0 + 0.01)
        policy.noteSocketOpened(at: t0, requiresProtocolReady: true)

        XCTAssertFalse(policy.hasSustainedHealthyConnection(at: t0 + 1.0))
        XCTAssertTrue(
            policy.hasSustainedHealthyConnection(at: t0 + 5.05),
            "Late noteSocketOpened must preserve earlier protocolReadyAt on the same connection attempt"
        )
        XCTAssertEqual(policy.nextDelayAfterDrop(at: t0 + 5.05, ceiling: 30, jitter: exact), 0.5)
        XCTAssertEqual(policy.attempts, 1)

        // Case 2 (`delegateQueue == nil` background delegate): `beginConnectAttempt(requiresProtocolReady: false)`
        // followed by `onOpen` calling `requireFreshProtocolReady()` ahead of `noteSocketOpened(..., requiresProtocolReady: false)`.
        // `noteSocketOpened` MUST NOT downgrade `requiresProtocolReady` back to `false`!
        let t1: TimeInterval = 600
        _ = policy.nextDelay(ceiling: 30, jitter: exact) // attempts == 2
        policy.beginConnectAttempt(requiresProtocolReady: false)
        policy.requireFreshProtocolReady()
        policy.noteSocketOpened(at: t1, requiresProtocolReady: false)

        // Even after >5s of raw TCP uptime, protocolReady was required and never arrived -> must NOT be healthy!
        XCTAssertFalse(
            policy.hasSustainedHealthyConnection(at: t1 + 10.0),
            "Late noteSocketOpened(requiresProtocolReady: false) must not downgrade requireFreshProtocolReady()"
        )
        XCTAssertEqual(policy.nextDelayAfterDrop(at: t1 + 10.0, ceiling: 30, jitter: exact), 2.0)
        XCTAssertEqual(policy.attempts, 3)

        // Starting the next connect attempt resets per-attempt state cleanly.
        let t2: TimeInterval = 700
        policy.beginConnectAttempt(requiresProtocolReady: false)
        policy.noteSocketOpened(at: t2, requiresProtocolReady: false)
        XCTAssertTrue(policy.hasSustainedHealthyConnection(at: t2 + 5.1))
    }
}
