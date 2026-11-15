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

    func testAcknowledgeActivityEncodesOptionalMaxRevisionBigEndian() {
        let untagged = RuntimeFrame.acknowledgeActivity()
        XCTAssertEqual(untagged, RuntimeFrame(67, 0, Data()))
        XCTAssertEqual(RuntimeFrame.acknowledgeActivity(maxRevision: 0), RuntimeFrame(67, 0, Data()))

        let watermarked = RuntimeFrame.acknowledgeActivity(maxRevision: 0x0102030405060708)
        XCTAssertEqual(watermarked.kind, 67)
        XCTAssertEqual(watermarked.sequence, 0)
        XCTAssertEqual(watermarked.data, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testRuntimeActivitySnapshotDecodesErrorInheritsAppAndHonorsTierPriority() throws {
        let errorJSON = #"""
        {
          "version": 1,
          "revision": 9,
          "records": [
            { "id": "omg-agent-claude-77", "metadata": "type=app;omg_agent=claude;omg_state=error" }
          ],
          "sync_restore": false
        }
        """#
        let errorSnap = try RuntimeActivitySnapshot(data: Data(errorJSON.utf8))
        XCTAssertEqual(errorSnap.revision, 9)
        XCTAssertEqual(errorSnap.agent, "claude")
        XCTAssertEqual(errorSnap.state, "error")
        XCTAssertEqual(errorSnap.message, "Error")
        XCTAssertTrue(errorSnap.isTerminal)
        XCTAssertFalse(errorSnap.isSyncRestore)

        let subRecordJSON = #"""
        {
          "version": 1,
          "revision": 12,
          "records": [
            { "id": "omg-program-status", "metadata": "state=working:app=codex:id=main" },
            { "id": "omg-program-status", "metadata": "state=blocked:kind=permission:id=main/sub" }
          ],
          "sync_restore": true
        }
        """#
        let subSnap = try RuntimeActivitySnapshot(data: Data(subRecordJSON.utf8))
        XCTAssertEqual(subSnap.agent, "codex")
        XCTAssertEqual(subSnap.state, "needsAttention")
        XCTAssertEqual(subSnap.attention, "permission")
        XCTAssertEqual(subSnap.message, "Waiting for permission")
        XCTAssertTrue(subSnap.isSyncRestore)

        let hookOverGenericWorkingJSON = #"""
        {
          "version": 1,
          "revision": 15,
          "records": [
            { "id": "omg-program-status", "metadata": "state=working:app=agy" },
            { "id": "omg-agent-antigravity-88", "metadata": "type=app;omg_agent=antigravity;omg_state=needsAttention;omg_attention=question;omg_tier=hook" },
            { "id": "omg-agent-antigravity-88", "metadata": "type=app;omg_agent=antigravity;omg_state=idle;omg_tier=fallback" }
          ]
        }
        """#
        let hookSnap = try RuntimeActivitySnapshot(data: Data(hookOverGenericWorkingJSON.utf8))
        XCTAssertEqual(hookSnap.agent, "antigravity")
        XCTAssertEqual(hookSnap.state, "needsAttention")
        XCTAssertEqual(hookSnap.attention, "question")
        XCTAssertEqual(hookSnap.message, "Waiting for you")
    }

    func testAttachVisibilityAndRawInputAcknowledgmentPolicy() throws {
        let idleRestore = try RuntimeActivitySnapshot(data: Data(#"""
        {"version":1,"revision":21,"records":[{"id":"omg-agent-codex-1","metadata":"type=app;omg_agent=codex;omg_state=idle"}],"sync_restore":true}
        """#.utf8))
        let workingRestore = try RuntimeActivitySnapshot(data: Data(#"""
        {"version":1,"revision":22,"records":[{"id":"omg-agent-codex-1","metadata":"type=app;omg_agent=codex;omg_state=working"}],"sync_restore":true}
        """#.utf8))
        let doneRestore = try RuntimeActivitySnapshot(data: Data(#"""
        {"version":1,"revision":42,"records":[{"id":"omg-agent-codex-1","metadata":"type=app;omg_agent=codex;omg_state=done"}],"sync_restore":true}
        """#.utf8))
        let doneLive = try RuntimeActivitySnapshot(data: Data(#"""
        {"version":1,"revision":43,"records":[{"id":"omg-agent-codex-1","metadata":"type=app;omg_agent=codex;omg_state=done"}],"sync_restore":false}
        """#.utf8))

        // Attach on idle/working emits zero 'C' frames; foreground attach on done emits watermarked 'C' after 'G'.
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnActivity(rendering: true, snapshot: idleRestore))
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnActivity(rendering: true, snapshot: workingRestore))
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnActivity(rendering: false, snapshot: doneRestore))
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnActivity(rendering: true, snapshot: doneLive))
        XCTAssertTrue(RuntimeActivityAckPolicy.shouldAcknowledgeOnActivity(rendering: true, snapshot: doneRestore))
        let ackFrame = RuntimeFrame.acknowledgeActivity(maxRevision: doneRestore.revision)
        XCTAssertEqual(ackFrame, RuntimeFrame(67, 0, Data([0, 0, 0, 0, 0, 0, 0, 42])))

        // Visibility transition only acknowledges terminal done/error states when attached.
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnBecomeVisible(isAttached: true, liveActivity: nil))
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnBecomeVisible(isAttached: true, liveActivity: workingRestore))
        XCTAssertFalse(RuntimeActivityAckPolicy.shouldAcknowledgeOnBecomeVisible(isAttached: false, liveActivity: doneLive))
        XCTAssertTrue(RuntimeActivityAckPolicy.shouldAcknowledgeOnBecomeVisible(isAttached: true, liveActivity: doneLive))

        // Passive focus and SGR/X10 mouse motion, release, and wheel never acknowledge done.
        for passive in [
            Data(),
            Data("\u{1B}[I".utf8),
            Data("\u{1B}[O".utf8),
            Data("\u{1B}[<35;10;10M".utf8),
            Data("\u{1B}[<64;10;10M".utf8),
            Data("\u{1B}[<0;10;10m".utf8),
            Data([0x1B, 0x5B, 0x4D, 32 + 35, 42, 42]),
            Data([0x1B, 0x5B, 0x4D, 32 + 64, 42, 42]),
            Data([0x1B, 0x5B, 0x4D, 32 + 3, 42, 42]),
        ] {
            XCTAssertFalse(
                RuntimeActivityAckPolicy.shouldAcknowledgeOnInput(passive, liveActivity: doneLive),
                "Expected passive sequence \(Array(passive)) not to acknowledge done"
            )
        }
        XCTAssertFalse(
            RuntimeActivityAckPolicy.shouldAcknowledgeOnInput(
                Data("a".utf8),
                acknowledgesActivity: false,
                liveActivity: doneLive
            )
        )

        // Intentional typing, paste, and mouse button presses DO acknowledge done.
        for intentional in [
            Data("a".utf8),
            Data("\u{1B}[200~ls\u{1B}[201~".utf8),
            Data("\u{1B}[<0;10;10M".utf8),
            Data([0x1B, 0x5B, 0x4D, 32 + 0, 42, 42]),
        ] {
            XCTAssertTrue(
                RuntimeActivityAckPolicy.shouldAcknowledgeOnInput(intentional, liveActivity: doneLive),
                "Expected intentional sequence \(Array(intentional)) to acknowledge done"
            )
        }
    }

    func testDuplicateFieldKeysUseLastMatchAndMultiAppProgramStatusDoesNotGuessGlobalFallback() throws {
        let duplicateKeysJSON = #"""
        {
          "version": 1,
          "revision": 30,
          "records": [
            { "id": "omg-program-status", "metadata": "state=idle:app=codex:state=done" }
          ]
        }
        """#
        let duplicateSnap = try RuntimeActivitySnapshot(data: Data(duplicateKeysJSON.utf8))
        XCTAssertEqual(duplicateSnap.agent, "codex")
        XCTAssertEqual(duplicateSnap.state, "done")

        let multiAppJSON = #"""
        {
          "version": 1,
          "revision": 31,
          "records": [
            { "id": "omg-program-status", "metadata": "state=idle:app=codex:id=pane-a" },
            { "id": "omg-program-status", "metadata": "state=idle:app=claude:id=pane-b" },
            { "id": "omg-program-status", "metadata": "state=blocked:kind=question:id=orphan" },
            { "id": "omg-agent-opencode-9", "metadata": "type=app;omg_agent=opencode;omg_state=idle" }
          ]
        }
        """#
        let multiAppSnap = try RuntimeActivitySnapshot(data: Data(multiAppJSON.utf8))
        // `orphan` must not pick an arbitrary entry from `{codex, claude}`; it inherits the unambiguous hook fallback `opencode`.
        XCTAssertEqual(multiAppSnap.agent, "opencode")
        XCTAssertEqual(multiAppSnap.state, "needsAttention")
    }

    func testResizeFrameEncodes8BytePixelPayloadAndClampsServerBounds() {
        let viewport = RuntimeViewport(columns: 48, rows: 24, pixelWidth: 1392, pixelHeight: 1440)
        let frame = RuntimeFrame.resize(viewport)
        XCTAssertEqual(frame.kind, 82)
        XCTAssertEqual(frame.sequence, 0)
        XCTAssertEqual(frame.data.count, 8)
        XCTAssertEqual(
            frame.data,
            Data([0x00, 48, 0x00, 24, 0x05, 0x70, 0x05, 0xA0])
        )
        XCTAssertEqual(RuntimeFrame.decodeResizePayload(frame.data), viewport)

        // Legacy 4-byte incoming server echo still decodes cleanly with non-zero fallback pixels.
        let legacy = RuntimeFrame.decodeResizePayload(Data([0x00, 80, 0x00, 25]))
        XCTAssertEqual(legacy, RuntimeViewport(columns: 80, rows: 25, pixelWidth: 640, pixelHeight: 400))

        // Oversized values clamp to omgd's server limits (500x300 cells, 16000x16000 pixels); 0 cells rejected.
        XCTAssertNil(RuntimeViewport.clamped(columns: 0, rows: 24, pixelWidth: 800, pixelHeight: 600))
        XCTAssertNil(RuntimeFrame.decodeResizePayload(Data([0, 0, 0, 24, 0, 100, 0, 100])))
        let clamped = RuntimeViewport.clamped(columns: 999, rows: 999, pixelWidth: 50_000, pixelHeight: 40_000)
        XCTAssertEqual(
            clamped,
            RuntimeViewport(columns: 500, rows: 300, pixelWidth: 16_000, pixelHeight: 16_000)
        )
    }

    func testPassiveViewerNeverAutoClaimsOrResizesUntilInputOrExplicitTakeover() throws {
        var gate = RuntimeWriterGate()
        let portrait = RuntimeViewport(columns: 39, rows: 44, pixelWidth: 1131, pixelHeight: 2640)
        let landscape = RuntimeViewport(columns: 84, rows: 19, pixelWidth: 2436, pixelHeight: 1140)
        let keyboard = RuntimeViewport(columns: 39, rows: 21, pixelWidth: 1131, pixelHeight: 1260)

        // Attach, viewport declaration, rotation, keyboard toggle, background/foreground, and reassertGrid
        // MUST emit zero claimWriter and zero sendResize effects while passively observing.
        XCTAssertEqual(gate.didAttach(), [])
        XCTAssertFalse(gate.isWriter)
        XCTAssertEqual(gate.setViewport(portrait), [])
        XCTAssertEqual(gate.setViewport(landscape), [])
        XCTAssertEqual(gate.setViewport(keyboard), [])
        XCTAssertEqual(gate.setRendering(false), [])
        XCTAssertEqual(gate.setRendering(true), [])
        XCTAssertEqual(gate.reassertGrid(), [])

        // Intentional typing claims writer once and coalesces subsequent keystrokes until 'W' arrives.
        XCTAssertEqual(
            try gate.enqueueInput(Data("l".utf8), maximumBytes: 1024).get(),
            [.claimWriter]
        )
        XCTAssertEqual(
            try gate.enqueueInput(Data("s\n".utf8), maximumBytes: 1024).get(),
            []
        )
        XCTAssertTrue(gate.isClaiming)

        // Server grants 'W': flushes pending input and emits the cached 8-byte pixel viewport resize.
        XCTAssertEqual(
            gate.writerChanged(true),
            [.sendInput(Data("ls\n".utf8)), .sendResize(keyboard)]
        )
        XCTAssertTrue(gate.isWriter)

        // Desktop reclaims writer ('B'): iPhone returns to passive observer; viewport changes stop resizing again.
        XCTAssertEqual(gate.writerChanged(false), [])
        XCTAssertFalse(gate.isWriter)
        XCTAssertEqual(gate.setViewport(portrait), [])

        // Explicit Take Over Size claims writer without sending stray input bytes.
        XCTAssertEqual(gate.requestTakeover(), [.claimWriter])
        XCTAssertEqual(gate.writerChanged(true), [.sendResize(portrait)])
    }

    func testPrimaryScreenPanDontResizeEmitsZeroResizesAcrossKeyboardAndIME() throws {
        var policy = MobileTerminalViewportPolicy()
        let cell = CGSize(width: 9.5, height: 19.0)
        let padding = CGSize(width: 8, height: 2)
        // Unoccluded phone terminal area: 390 x 750pt.
        let hidden = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 750),
            containerWidth: 390,
            keyboardOverlap: 0,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 39, cols: 39),
            caretMaxY: 720,
            isAlternateScreen: false,
            isWriter: true
        ))
        let baseViewport = try XCTUnwrap(hidden.declaredViewport)
        XCTAssertEqual(hidden.verticalPan, 0)
        XCTAssertEqual(hidden.surfaceScale, 1.0)
        XCTAssertFalse(hidden.shouldDebounceDeclaration)

        // Software keyboard + accessory bar appears (overlap = 380, visible host = 370):
        // fullHeight remains 370 + 380 = 750 -> declaredViewport MUST NOT CHANGE!
        let englishKeyboard = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 370),
            containerWidth: 390,
            keyboardOverlap: 380,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 39, cols: 39),
            caretMaxY: 720,
            isAlternateScreen: false,
            isWriter: true
        ))
        XCTAssertEqual(englishKeyboard.declaredViewport, baseViewport)
        XCTAssertFalse(englishKeyboard.shouldDebounceDeclaration)
        XCTAssertGreaterThan(englishKeyboard.verticalPan, 350, "Bottom prompt must pan above keyboard")
        XCTAssertEqual(englishKeyboard.surfaceScale, 1.0)

        // Chinese Pinyin +44pt candidate bar appears (overlap = 424, visible host = 326):
        // fullHeight remains 326 + 424 = 750 -> still ZERO PTY resize, local pan absorbs +44pt!
        let pinyinCandidateBar = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 326),
            containerWidth: 390,
            keyboardOverlap: 424,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 39, cols: 39),
            caretMaxY: 720,
            isAlternateScreen: false,
            isWriter: true
        ))
        XCTAssertEqual(pinyinCandidateBar.declaredViewport, baseViewport)
        XCTAssertFalse(pinyinCandidateBar.shouldDebounceDeclaration)
        XCTAssertGreaterThan(pinyinCandidateBar.verticalPan, englishKeyboard.verticalPan)

        // Cursor near top of screen (row 1, caretMaxY = 30) stays unpanned even with keyboard up.
        let topPrompt = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 326),
            containerWidth: 390,
            keyboardOverlap: 424,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 39, cols: 39),
            caretMaxY: 30,
            isAlternateScreen: false,
            isWriter: true
        ))
        XCTAssertEqual(topPrompt.declaredViewport, baseViewport)
        XCTAssertEqual(topPrompt.verticalPan, 0)
    }

    func testAlternateScreenCandidateBarSizeLockNoPostageStampBounceAndNoDisappearResize() throws {
        var policy = MobileTerminalViewportPolicy()
        let cell = CGSize(width: 9.5, height: 19.0)
        let padding = CGSize(width: 8, height: 2)

        // 1. Alt-Screen open without keyboard (390 x 750 -> 39 rows).
        let fullAlt = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 750),
            containerWidth: 390,
            keyboardOverlap: 0,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 39, cols: 39),
            caretMaxY: 700,
            isAlternateScreen: true,
            isWriter: true
        ))
        XCTAssertEqual(fullAlt.declaredViewport?.rows, 39)
        XCTAssertEqual(fullAlt.surfaceScale, 1.0)

        // 2. Software keyboard rises (overlap = 356, visible host = 394) BEFORE server echoes new 'R'
        // (sharedGrid is still 39x39 ~ 750pt tall):
        // MUST debounce (>= 180ms) AND keep surfaceScale == 1.0 (NO 0.46x postage-stamp bounce!).
        let preEcho = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 394),
            containerWidth: 390,
            keyboardOverlap: 356,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 39, cols: 39),
            caretMaxY: 700,
            isAlternateScreen: true,
            isWriter: true
        ))
        let lockedRows = try XCTUnwrap(preEcho.declaredViewport?.rows)
        XCTAssertEqual(lockedRows, 20)
        XCTAssertTrue(preEcho.shouldDebounceDeclaration)
        XCTAssertGreaterThanOrEqual(MobileTerminalViewportPolicy.keyboardSettleInterval, 0.18)
        XCTAssertEqual(preEcho.surfaceScale, 1.0, "Active writer must never downscale to 0.46x postage stamp")

        // 3. Server echoes 20-row Alt-Screen grid; user switches ABC -> 简体拼音 and types Chinese:
        // +44pt Pinyin candidate bar (overlap 356 -> 400, host 394 -> 350, delta = 44pt <= 60pt):
        // Declared rows MUST remain locked at 20 (ZERO SIGWINCH!), absorbed by local verticalPan!
        let pinyinShow = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 350),
            containerWidth: 390,
            keyboardOverlap: 400,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 20, cols: 39),
            caretMaxY: 375,
            isAlternateScreen: true,
            isWriter: true
        ))
        XCTAssertEqual(pinyinShow.declaredViewport?.rows, lockedRows)
        XCTAssertFalse(pinyinShow.shouldDebounceDeclaration)
        XCTAssertEqual(pinyinShow.surfaceScale, 1.0)
        XCTAssertGreaterThan(pinyinShow.verticalPan, 0)

        // Candidate committed -> candidate bar hides (overlap 400 -> 356): still locked at 20 rows!
        let pinyinCommit = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 394),
            containerWidth: 390,
            keyboardOverlap: 356,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 20, cols: 39),
            caretMaxY: 375,
            isAlternateScreen: true,
            isWriter: true
        ))
        XCTAssertEqual(pinyinCommit.declaredViewport?.rows, lockedRows)
        XCTAssertFalse(pinyinCommit.shouldDebounceDeclaration)

        // 4. Passive observer (`isWriter == false`) viewing a wide 120x40 Desktop TUI letterboxes cleanly (< 1.0)
        // against full unoccluded height, with zero scale bounce when keyboard toggles.
        let passiveKeyboardDown = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 750),
            containerWidth: 390,
            keyboardOverlap: 0,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 40, cols: 120),
            caretMaxY: 400,
            isAlternateScreen: true,
            isWriter: false
        ))
        let passiveKeyboardUp = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 394),
            containerWidth: 390,
            keyboardOverlap: 356,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 40, cols: 120),
            caretMaxY: 400,
            isAlternateScreen: true,
            isWriter: false
        ))
        XCTAssertLessThan(passiveKeyboardDown.surfaceScale, 1.0)
        XCTAssertEqual(passiveKeyboardDown.surfaceScale, passiveKeyboardUp.surfaceScale, accuracy: 0.0001)

        // 5. Navigating back (`viewWillDisappear` / `goBack` -> `canDeclareViewport == false`):
        // Keyboard dismissal MUST emit nil declaredViewport (zero parting Resize!).
        let disappearing = policy.evaluate(.init(
            hostSize: CGSize(width: 390, height: 750),
            containerWidth: 390,
            keyboardOverlap: 0,
            cellSize: cell,
            cellPixelWidth: 29,
            cellPixelHeight: 57,
            padding: padding,
            sharedGrid: (rows: 20, cols: 39),
            caretMaxY: 300,
            isAlternateScreen: true,
            isWriter: true,
            canDeclareViewport: false
        ))
        XCTAssertNil(disappearing.declaredViewport)
    }

    func testStreamDisplayLinkPausePolicyCoversWindowVisibilityHostParkingAndAppBackground() {
        // Active foreground visible terminal: displayLink runs unpaused.
        XCTAssertFalse(
            MobileStreamDisplayLinkPolicy.shouldPause(
                hasWindow: true,
                isHidden: false,
                hostAllowsRendering: true,
                isAppInBackground: false
            )
        )

        // Off-window view: paused.
        XCTAssertTrue(
            MobileStreamDisplayLinkPolicy.shouldPause(
                hasWindow: false,
                isHidden: false,
                hostAllowsRendering: true,
                isAppInBackground: false
            )
        )

        // Parked terminal kept in window with `view.isHidden = true`: paused (no 60-120 Hz spin).
        XCTAssertTrue(
            MobileStreamDisplayLinkPolicy.shouldPause(
                hasWindow: true,
                isHidden: true,
                hostAllowsRendering: true,
                isAppInBackground: false
            )
        )

        // Parked via `RootContainerViewController.open(_:)` / `goHome()` (`hostAllowsRendering == false`): paused immediately.
        XCTAssertTrue(
            MobileStreamDisplayLinkPolicy.shouldPause(
                hasWindow: true,
                isHidden: false,
                hostAllowsRendering: false,
                isAppInBackground: false
            )
        )

        // App entered background while terminal is visible on screen: paused.
        XCTAssertTrue(
            MobileStreamDisplayLinkPolicy.shouldPause(
                hasWindow: true,
                isHidden: false,
                hostAllowsRendering: true,
                isAppInBackground: true
            )
        )
    }

    func testSwipeReloadGateDefersBackgroundReloadsWhileSwipeEditingAndAllowsExplicitSwipeClose() {
        var gate = MobileSwipeReloadGate()

        // Normal non-editing updates reload immediately.
        XCTAssertTrue(gate.shouldReloadNow(isTableEditing: false))
        XCTAssertFalse(gate.hasDeferredReload)

        // While user has swiped a row open (`isTableEditing == true`), background roster pushes defer.
        XCTAssertFalse(gate.shouldReloadNow(isTableEditing: true))
        XCTAssertTrue(gate.hasDeferredReload)
        XCTAssertFalse(gate.consumeDeferredReloadIfReady(isTableEditing: true))

        // Dismissing swipe without closing flushes the deferred reload once editing ends.
        XCTAssertTrue(gate.consumeDeferredReloadIfReady(isTableEditing: false))
        XCTAssertFalse(gate.hasDeferredReload)
        XCTAssertFalse(gate.consumeDeferredReloadIfReady(isTableEditing: false))

        // Tapping "Close" between `beginSwipeAction()` and `endSwipeAction()` reloads immediately
        // even while `isTableEditing == true`, without overlapping struct mutation.
        XCTAssertFalse(gate.shouldReloadNow(isTableEditing: true))
        XCTAssertTrue(gate.hasDeferredReload)
        gate.beginSwipeAction()
        XCTAssertTrue(gate.shouldReloadNow(isTableEditing: true))
        gate.endSwipeAction()
        XCTAssertFalse(gate.isPerformingSwipeAction)
        XCTAssertFalse(gate.hasDeferredReload)
    }
}
