import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct AgentQuickInputTests {
    private static var retainedTestWindows: [NSWindow] = []

    @Test func shortcutRoundTripsCanonicalStorageAndDisplay() throws {
        let shortcut = try #require(
            OMGKeyboardShortcut(storageValue: "shift+command+E")
        )
        #expect(shortcut.storageValue == "shift+command+e")
        #expect(shortcut.displayValue == "⇧⌘E")
        #expect(OMGKeyboardShortcut(storageValue: "e") == nil)
        #expect(OMGKeyboardShortcut(storageValue: "command+unknown+e") == nil)
    }

    @Test func queueAndDraftAreScopedToTheirPane() throws {
        let first = UUID()
        let second = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)

        model.present(for: first)
        model.draft = "first prompt"
        let queued = try #require(model.enqueueDraft())
        #expect(model.state(for: first)?.queue == [queued])
        #expect(model.draft.isEmpty)

        model.present(for: second)
        model.draft = "second draft"
        model.dismiss()

        model.present(for: first)
        #expect(model.draft.isEmpty)
        #expect(model.targetQueue == [queued])
        #expect(model.state(for: second)?.draft == "second draft")
    }

    @Test func historyIsPaneScopedAndRecallDoesNotSendOrOverwriteDraft() {
        let first = UUID()
        let second = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: first)
        #expect(!model.recallLastSentText())
        model.recordSentText("first\nmessage 🐱", for: first)
        model.recordSentText("second pane", for: second)
        #expect(model.targetHistory == ["first\nmessage 🐱"])
        #expect(model.recallLastSentText())
        #expect(model.draft == "first\nmessage 🐱")
        #expect(model.isPresented)
        #expect(model.targetQueue.isEmpty)
        model.draft = "unfinished"
        #expect(!model.recallLastSentText())
        #expect(model.draft == "unfinished")
        model.present(for: second)
        #expect(model.recallLastSentText())
        #expect(model.draft == "second pane")
        model.removeState(for: first)
        model.present(for: first)
        #expect(model.targetHistory == ["first\nmessage 🐱"])
        // A newly created pane never inherits a closed pane's history.
        model.present(for: UUID())
        #expect(model.targetHistory.isEmpty)
    }

    @Test func historyIsBoundedDeduplicatedAndMovesWithPaneState() throws {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.recordSentText(" \n", for: surfaceID)
        model.draft = "not yet sent"
        _ = model.enqueueDraft()
        #expect(model.targetHistory == ["not yet sent"])
        for index in 0..<60 { model.recordSentText("message \(index)", for: surfaceID) }
        model.recordSentText("message 59", for: surfaceID)
        #expect(model.targetHistory.count == AgentQuickInputModel.historyLimit)
        #expect(model.targetHistory.first == "message 10")
        #expect(model.targetHistory.last == "message 59")
        let transferred = try #require(model.state(for: surfaceID))
        let destination = AgentQuickInputModel(dockHeight: 252, historyStore: model.historyStore)
        destination.bindHistory(to: UUID(), paneIDs: [surfaceID])
        destination.restore(transferred, for: surfaceID)
        destination.present(for: surfaceID)
        #expect(destination.targetHistory == model.targetHistory)
        let queued = try #require(destination.targetQueue.first)
        destination.editQueuedItem(queued.id, for: surfaceID)
        destination.draft = ""
        #expect(!destination.recallLastSentText())
        destination.useHistoryText("do not overwrite edit")
        #expect(destination.draft.isEmpty)
    }

    @Test func selectingHistoryAppendsWithoutSendingOrChangingQueue() {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: UUID())
        model.draft = "existing draft"
        model.useHistoryText("old\nmessage")
        #expect(model.draft == "existing draft\nold\nmessage")
        model.draft = "existing draft\n"
        model.useHistoryText("another")
        #expect(model.draft == "existing draft\nanother")
        #expect(model.targetQueue.isEmpty)
        #expect(model.targetHistory.isEmpty)
        #expect(model.isPresented)
    }

    @Test func nativeEditorRecallsOnlyOnUnmodifiedUpWithEmptyInput() throws {
        let editor = ComposerTextView()
        var recalled = 0
        editor.onRecallHistory = { recalled += 1; return true }
        let up = try #require(keyEvent(keyCode: 126, modifiers: []))
        editor.keyDown(with: up)
        #expect(recalled == 1)
        editor.string = "unfinished\ntext"
        editor.keyDown(with: up)
        #expect(recalled == 1)
        editor.string = ""
        let optionUp = try #require(keyEvent(keyCode: 126, modifiers: [.option]))
        editor.keyDown(with: optionUp)
        #expect(recalled == 1)
        let shiftUp = try #require(keyEvent(keyCode: 126, modifiers: [.shift]))
        editor.keyDown(with: shiftUp)
        #expect(recalled == 1)
        editor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        editor.keyDown(with: up)
        #expect(recalled == 1)
    }

    @Test func dockDoesNotWaitForAnAnimationToResizeTerminal() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        var interactions = 0
        let token = NotificationCenter.default.addObserver(forName: TerminalSurfaceResizeInteraction.didBegin,
                                                          object: window, queue: .main) { _ in
            MainActor.assumeIsolated { interactions += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        controller.toggleQuickInput()
        controller.dismissQuickInput()
        #expect(interactions == 0, "One-shot composer changes must not put every pane into live-resize deferral")
    }

    @Test func queuedMessageCanBeEditedInPlace() throws {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.draft = "revise this prompt"
        let item = try #require(model.enqueueDraft())
        model.dismiss()

        model.editQueuedItem(item.id, for: surfaceID)
        #expect(model.isPresented)
        #expect(model.isEditingQueuedItem)
        #expect(model.draft == "revise this prompt")
        #expect(model.targetQueue == [item])

        model.draft = "revised prompt"
        #expect(model.confirmQueuedItemEdit(moveToEnd: false))
        #expect(!model.isPresented)
        #expect(!model.isEditingQueuedItem)
        #expect(model.targetQueue.map(\.text) == ["revised prompt"])
        #expect(model.targetQueue.first?.id == item.id)
    }

    @Test func editedMessageCanMoveToQueueEndOrCancel() throws {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.draft = "first"
        let first = try #require(model.enqueueDraft())
        model.draft = "second"
        let second = try #require(model.enqueueDraft())
        model.dismiss()

        model.editQueuedItem(first.id, for: surfaceID)
        model.draft = "first revised"
        #expect(model.confirmQueuedItemEdit(moveToEnd: true))
        #expect(model.targetQueue.map(\.id) == [second.id, first.id])
        #expect(model.targetQueue.map(\.text) == ["second", "first revised"])

        model.editQueuedItem(second.id, for: surfaceID)
        model.draft = "discarded edit"
        model.cancelQueuedItemEdit()
        #expect(model.targetQueue.map(\.text) == ["second", "first revised"])
        #expect(!model.isPresented)
    }

    @Test func nativeEditorConsumesEscapeAndComposerCommands() throws {
        let editor = ComposerTextView()
        var cancelled = 0
        var sent = 0
        var queued = 0
        editor.onCancel = { cancelled += 1 }
        editor.onSend = { sent += 1 }
        editor.onQueue = { queued += 1 }

        let escape = try #require(keyEvent(keyCode: 53, modifiers: []))
        editor.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        editor.keyDown(with: escape)
        #expect(cancelled == 0)

        editor.unmarkText()
        editor.keyDown(with: escape)
        #expect(cancelled == 1)

        let send = try #require(keyEvent(keyCode: 36, modifiers: [.command]))
        #expect(editor.performKeyEquivalent(with: send))
        #expect(sent == 1)

        let queue = try #require(keyEvent(
            keyCode: 36,
            modifiers: [.command, .option]
        ))
        #expect(editor.performKeyEquivalent(with: queue))
        #expect(queued == 1)
    }

    @Test func optionCommandArrowsResolveAsComposerFocusNavigation() {
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 125,
            modifiers: [.option, .command]
        ) == .down)
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 126,
            modifiers: [.option, .command]
        ) == .up)
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 123,
            modifiers: [.option]
        ) == nil)
        #expect(AgentQuickInputFocusDirection.resolve(
            keyCode: 124,
            modifiers: [.option, .command, .shift]
        ) == nil)
    }

    @Test func controlJInsertsNewlineAtSelectionWhenEnabled() throws {
        let editor = ComposerTextView()
        editor.controlJNewlineEnabled = { true }
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        let event = try #require(keyEvent(keyCode: 38, modifiers: [.control]))
        editor.keyDown(with: event)
        #expect(editor.string == "hello\nworld")
        #expect(editor.selectedRange().location == 6)
    }

    @Test func nativeEditorOptionArrowMovesByWord() throws {
        let editor = ComposerTextView()
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        let optionLeft = try #require(keyEvent(
            keyCode: 123,
            modifiers: [.option]
        ))

        editor.keyDown(with: optionLeft)

        #expect(editor.selectedRange().location == 6)
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 124,
            modifiers: [.option, .shift]
        ) == .wordForward(modifySelection: true))
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 126,
            modifiers: [.option]
        ) == .paragraphBeginning(modifySelection: false))
    }

    @Test func nativeEditorImagePasteInsertsAgentTempPath() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(
            name: .init("omg-quick-input-image-\(UUID().uuidString)")
        )
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        let editor = ComposerTextView()
        editor.pasteboard = pasteboard

        editor.paste(nil)

        #expect(editor.string.contains("/omg-paste/omg-paste-"))
        #expect(editor.string.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: editor.string))
        try? FileManager.default.removeItem(atPath: editor.string)
    }

    @Test func nativeEditorImagePasteUsesRemotePathResolver() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(
            name: .init("omg-quick-input-remote-image-\(UUID().uuidString)")
        )
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        let editor = ComposerTextView()
        editor.pasteboard = pasteboard
        var localFile: URL?
        editor.onPasteImage = { file, completion in
            localFile = file
            completion("/tmp/omg-paste-remote.png")
        }

        editor.paste(nil)

        #expect(localFile?.pathExtension == "png")
        #expect(editor.string == "/tmp/omg-paste-remote.png")
        if let localFile { try? FileManager.default.removeItem(at: localFile) }
    }

    @Test func standardEditingShortcutsAreRecognized() {
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "c",
            modifiers: [.command]
        ) == .copy)
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "v",
            modifiers: [.command]
        ) == .paste)
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "z",
            modifiers: [.command, .shift]
        ) == .redo)
        #expect(AgentQuickInputEditingCommand.resolve(
            key: "v",
            modifiers: [.command, .option]
        ) == nil)
    }

    @Test func dockHeightClampsWithoutChangingTerminalMinimum() async throws {
        let model = AgentQuickInputModel(dockHeight: 252)
        model.updateDockHeight(900, availableHeight: 600, persist: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.dockHeight == 440)

        model.updateDockHeight(20, availableHeight: 600, persist: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.dockHeight == AgentQuickInputMetrics.minimumHeight)
    }

    @Test func removingPaneDropsDraftAndQueue() {
        let surfaceID = UUID()
        let model = AgentQuickInputModel(dockHeight: 252)
        model.present(for: surfaceID)
        model.draft = "queued prompt"
        _ = model.enqueueDraft()

        model.removeState(for: surfaceID)

        #expect(model.state(for: surfaceID) == nil)
        #expect(model.targetSurfaceID == nil)
        #expect(!model.isPresented)
    }

    @Test func paneStateCanMoveBetweenControllersWithoutPersistence() throws {
        let surfaceID = UUID()
        let source = AgentQuickInputModel(dockHeight: 252)
        source.present(for: surfaceID)
        source.draft = "draft"
        _ = source.enqueueDraft()
        let state = try #require(source.state(for: surfaceID))

        let destination = AgentQuickInputModel(dockHeight: 252)
        destination.restore(state, for: surfaceID)

        #expect(destination.state(for: surfaceID) == state)
    }

    @Test func queueCardsUseContentWidthAndShrinkToTheLane() {
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: 2,
            availableWidth: 1_000
        ) == AgentQuickInputMetrics.queueMinimumWidth)
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: "resume".count,
            availableWidth: 1_000
        ) == 155)
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: 100,
            availableWidth: 1_000
        ) == AgentQuickInputMetrics.queueMaximumWidth)
        #expect(AgentQuickInputMetrics.queueCardWidth(
            previewCount: 100,
            availableWidth: 160
        ) == 136)
        #expect(AgentQuickInputMetrics.queueButtonHitSize == 30)
        #expect(AgentQuickInputMetrics.queueHoverDelayMilliseconds == 300)
    }

    @Test func accessoryHeightReservesFinalLayoutWithoutAnimationSteps() {
        let divider = TerminalShellStyle.dividerWidth
        for (presented, hasQueue) in [(false, false), (true, false), (false, true), (true, true)] {
            #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
                dockHeight: 252,
                isDockPresented: presented,
                hasQueue: hasQueue
            ) == 0)
            #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
                dockHeight: 252,
                isDockPresented: presented,
                hasQueue: hasQueue,
                isPinned: false
            ) == 0)
        }
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: false,
            hasQueue: false,
            isPinned: true
        ) == 0)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: true,
            hasQueue: false,
            isPinned: true
        ) == 252 + divider)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: false,
            hasQueue: true,
            isPinned: true
        ) == AgentQuickInputMetrics.queueLaneHeight + divider)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: true,
            hasQueue: true,
            isPinned: true
        ) == 252 + AgentQuickInputMetrics.queueLaneHeight + divider * 2)
    }

    @Test @MainActor func placeholderUsesRealWindowCaretGeometry() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        let editor = ComposerTextView(frame: scrollView.bounds)
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.widthTracksTextView = true
        editor.placeholder = "Type here…"
        scrollView.documentView = editor
        window.contentView = scrollView
        window.makeFirstResponder(editor)
        editor.layoutManager?.ensureLayout(for: try #require(editor.textContainer))

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let screenRect = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: &actualRange
        )
        let localCaretRect = editor.convert(
            window.convertFromScreen(screenRect),
            from: nil
        )
        let origin = editor.placeholderDrawingOrigin()
        let expected = localCaretRect.maxX + 1 / window.backingScaleFactor

        #expect(abs(origin.x - expected) < 0.01)
        #expect(origin.x > localCaretRect.maxX)
        #expect(origin.y == editor.textContainerOrigin.y)
        Self.retainedTestWindows.append(window)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    @Test func agentStartPresentationPolicyRequiresOptInAndFocusedTarget() {
        let activity = TabActivity(
            source: "pi",
            state: .idle,
            label: nil,
            message: nil,
            detail: nil,
            progress: nil,
            icon: nil
        )
        #expect(AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: nil,
            next: activity,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: activity,
            next: activity,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: nil,
            next: activity,
            enabled: false,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentStart(
            previous: nil,
            next: activity,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: false
        ))
    }

    @Test func agentCompletionPresentationPolicyRequiresNewDoneAndFocusedTarget() {
        #expect(AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .done,
            next: .done,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: false,
            isAlreadyPresented: false,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: true,
            isAlreadyPresented: true,
            isTargetFocused: true
        ))
        #expect(!AgentQuickInputPresentationPolicy.shouldPresentForAgentCompletion(
            previous: .working,
            next: .done,
            enabled: true,
            isAlreadyPresented: false,
            isTargetFocused: false
        ))
    }

    @Test func dispatchPolicyOnlyAcceptsNewDoneTransition() {
        #expect(AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .working,
            next: .done
        ))
        #expect(AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .needsAttention,
            next: .done
        ))
        #expect(!AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .working,
            next: .needsAttention
        ))
        #expect(!AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .done,
            next: .done
        ))
        #expect(!AgentQuickInputDispatchPolicy.shouldDispatch(
            previous: .done,
            next: .idle
        ))
    }

    @Test func composerTextViewUsesIsolatedUndoManager() {
        let editor = ComposerTextView()
        let window = NSWindow()
        window.contentView = editor
        #expect(editor.undoManager != nil)
        #expect(editor.undoManager !== window.undoManager)
    }

    @Test @MainActor
    func unpinnedQuickInputRoundTripEmitsZeroSIGWINCHZeroCtrlGAndZeroDEC1004FocusChatter() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("probe.py")
        let ready = root.appendingPathComponent("ready")
        let captured = root.appendingPathComponent("captured")
        let sigwinchFile = root.appendingPathComponent("sigwinch")
        try #"""
        import os, pathlib, signal, tty
        tty.setraw(0)
        root = pathlib.Path(__file__).parent
        sigwinches = 0
        def on_winch(signum, frame):
            global sigwinches
            sigwinches += 1
            (root / "sigwinch").write_text(str(sigwinches))
        signal.signal(signal.SIGWINCH, on_winch)
        os.write(1, b"\x1b[?1004h")
        (root / "sigwinch").write_text("0")
        (root / "ready").touch()
        buf = bytearray()
        while True:
            chunk = os.read(0, 4096)
            if not chunk:
                break
            buf.extend(chunk)
            (root / "captured").write_bytes(bytes(buf))
        """#.write(to: script, atomically: true, encoding: .utf8)

        let python = try #require(LocalPythonInterpreter.cached())
        var config = Ghostty.SurfaceConfiguration()
        config.command = Ghostty.Shell.quote(python.executablePath) + " " + Ghostty.Shell.quote(script.path)
        let controller = TerminalController(app, withBaseConfig: config)
        controller.showWindow(nil)
        let window = try #require(controller.window)
        defer {
            controller.dismissQuickInput()
            window.delegate = nil
            window.close()
        }

        let surface = try #require(controller.focusedSurface)
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        window.contentView?.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(surface)
        surface.focusDidChange(true)
        try await Task.sleep(for: .milliseconds(100))

        let baselineBytes = (try? Data(contentsOf: captured))?.count ?? 0
        let baselineWinch = Int((try? String(contentsOf: sigwinchFile, encoding: .utf8)) ?? "0") ?? 0
        let initialSurfaceFrame = surface.frame
        #expect(!controller.quickInputModel.isPinned)
        #expect(surface.focused)

        // 1. Open unpinned Quick Input (⌘⇧E) and transfer focus to ComposerTextView.
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        window.contentView?.layoutSubtreeIfNeeded()
        func findEditor(_ view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap(findEditor).first
        }
        let editor = try #require(window.contentView.flatMap(findEditor))
        controller.focusQuickInputEditor(editor, for: surface.id)
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        #expect(surface.layer?.opacity == 1)
        #expect(surface.frame == initialSurfaceFrame)

        // 2. Round-trip focus between ComposerTextView and SurfaceView (⌘⌥↑ / ⌘⌥↓).
        controller.restoreTerminalFocus(surfaceID: surface.id)
        #expect(window.firstResponder === surface)
        #expect(!surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        controller.focusQuickInputEditor(editor, for: surface.id)
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)

        // 3. Queue a message while unpinned; queue bar appears as floating overlay with 0 resize.
        controller.quickInputModel.draft = "queued while unpinned"
        controller.queueQuickInputDraft()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.quickInputModel.state(for: surface.id)?.queue.count == 1)
        #expect(surface.frame == initialSurfaceFrame)
        #expect(surface.focused)

        // 4. Open again, send a draft, and dismiss on completion.
        controller.toggleQuickInput()
        window.contentView?.layoutSubtreeIfNeeded()
        controller.focusQuickInputEditor(editor, for: surface.id)
        controller.quickInputModel.draft = "direct overlay send"
        controller.sendQuickInputDraft()

        for _ in 0..<80 {
            let allData = (try? Data(contentsOf: captured)) ?? Data()
            let delta = allData.dropFirst(min(baselineBytes, allData.count))
            if let text = String(data: delta, encoding: .utf8), text.contains("direct overlay send"), text.hasSuffix("\r") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let postSendWinch = Int((try? String(contentsOf: sigwinchFile, encoding: .utf8)) ?? "0") ?? 0
        #expect(postSendWinch == baselineWinch, "Unpinned Quick Input open/queue/send/dismiss must emit 0 SIGWINCH")
        #expect(surface.frame == initialSurfaceFrame)
        #expect(surface.layer?.opacity == 1)
        #expect(surface.focused)

        let allData = try Data(contentsOf: captured)
        let roundTripSlice = Data(allData.dropFirst(min(baselineBytes, allData.count)))
        let roundTripText = try #require(String(data: roundTripSlice, encoding: .utf8))
        #expect(roundTripText.contains("direct overlay send"))
        #expect(!roundTripSlice.contains(0x07), "Default Quick Input open/send must not inject Ctrl+G (0x07)")
        #expect(!roundTripText.contains("\u{1B}[103;5u"), "Default Quick Input open/send must not inject Kitty Ctrl+G")
        #expect(!roundTripText.contains("\u{1B}[O"), "Companion focus transfer must suppress DEC 1004 focus-out")
        #expect(!roundTripText.contains("\u{1B}[I"), "Companion focus transfer must suppress duplicate DEC 1004 focus-in")

        // 5. Real non-companion focus loss still emits DEC 1004 focus-out (\x1b[O).
        let externalField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        window.contentView?.addSubview(externalField)
        _ = window.makeFirstResponder(externalField)
        #expect(!surface.focused)
        for _ in 0..<40 {
            let latest = (try? Data(contentsOf: captured)) ?? Data()
            let afterSend = Data(latest.dropFirst(min(allData.count, latest.count)))
            if String(data: afterSend, encoding: .utf8)?.contains("\u{1B}[O") == true {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let latest = try Data(contentsOf: captured)
        let afterRealBlur = try #require(String(data: Data(latest.dropFirst(min(allData.count, latest.count))), encoding: .utf8))
        #expect(afterRealBlur.contains("\u{1B}[O"))
    }

    @Test @MainActor
    func floatingQuickInputUsesOpaqueBackgroundWhenWindowIsTranslucentOrGlass() throws {
        let themeColor = Color(.sRGB, red: 0.12, green: 0.13, blue: 0.19, opacity: 1)

        // 1. Translucent background-opacity < 1.0
        let translucentChrome = TerminalController.chromeBackground(
            color: themeColor,
            opacity: 0.62,
            windowIsOpaque: false,
            usesWindowGlass: false
        )
        let floatingTranslucent = TerminalController.quickInputAccessoryBackground(
            isPinned: false,
            chromeBackground: translucentChrome,
            color: themeColor,
            opacity: 0.62
        )
        let pinnedTranslucent = TerminalController.quickInputAccessoryBackground(
            isPinned: true,
            chromeBackground: translucentChrome,
            color: themeColor,
            opacity: 0.62
        )
        #expect(NSColor(floatingTranslucent).cgColor.alpha == 1)
        let pinnedTranslucentColor = try #require(NSColor(pinnedTranslucent).usingColorSpace(.sRGB))
        #expect(abs(pinnedTranslucentColor.alphaComponent - 0.62) < 0.02)

        // 2. macOS glass style (usesWindowGlass = true -> terminalChromeBackground is .clear)
        let glassChrome = TerminalController.chromeBackground(
            color: themeColor,
            opacity: 0.62,
            windowIsOpaque: false,
            usesWindowGlass: true
        )
        let floatingGlass = TerminalController.quickInputAccessoryBackground(
            isPinned: false,
            chromeBackground: glassChrome,
            color: themeColor,
            opacity: 0.62
        )
        let pinnedGlass = TerminalController.quickInputAccessoryBackground(
            isPinned: true,
            chromeBackground: glassChrome,
            color: themeColor,
            opacity: 0.62
        )
        #expect(NSColor(floatingGlass).cgColor.alpha == 1)
        #expect(NSColor(pinnedGlass).alphaComponent == 0)
    }

    @Test @MainActor
    func keyWindowResignAndRegainPreservesCompanionQuickInputFocusWithoutLateDEC1004() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("focus_probe.py")
        let ready = root.appendingPathComponent("ready")
        let captured = root.appendingPathComponent("captured")
        try #"""
        import os, pathlib, tty
        tty.setraw(0)
        root = pathlib.Path(__file__).parent
        os.write(1, b"\x1b[?1004h")
        (root / "ready").touch()
        buf = bytearray()
        while True:
            chunk = os.read(0, 4096)
            if not chunk:
                break
            buf.extend(chunk)
            (root / "captured").write_bytes(bytes(buf))
        """#.write(to: script, atomically: true, encoding: .utf8)

        let python = try #require(LocalPythonInterpreter.cached())
        var config = Ghostty.SurfaceConfiguration()
        config.command = Ghostty.Shell.quote(python.executablePath) + " " + Ghostty.Shell.quote(script.path)
        let controller = TerminalController(app, withBaseConfig: config)
        controller.showWindow(nil)
        let window = try #require(controller.window)
        defer {
            controller.dismissQuickInput()
            window.delegate = nil
            window.close()
        }

        let surface = try #require(controller.focusedSurface)
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))

        controller.keyWindowOverrideForTesting = true
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(surface))
        controller.syncFocusToSurfaceTree()
        #expect(surface.focused)

        controller.toggleQuickInput()
        window.contentView?.layoutSubtreeIfNeeded()
        func findEditor(_ view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap(findEditor).first
        }
        let editor = try #require(window.contentView.flatMap(findEditor))
        controller.focusQuickInputEditor(editor, for: surface.id)
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        try await Task.sleep(for: .milliseconds(80))

        // Simulate ⌘Tab away (windowDidResignKey): companion ownership stays intact while surface blurs.
        let beforeResignCount = (try? Data(contentsOf: captured))?.count ?? 0
        controller.keyWindowOverrideForTesting = false
        controller.syncFocusToSurfaceTree()
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(!surface.focused)
        for _ in 0..<40 {
            let data = (try? Data(contentsOf: captured)) ?? Data()
            let slice = Data(data.dropFirst(min(beforeResignCount, data.count)))
            if String(data: slice, encoding: .utf8)?.contains("\u{1B}[O") == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        // Simulate ⌘Tab back (windowDidBecomeKey): surface regains focus immediately while QuickInput stays active.
        let beforeRegainCount = (try? Data(contentsOf: captured))?.count ?? 0
        controller.keyWindowOverrideForTesting = true
        controller.syncFocusToSurfaceTree()
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        for _ in 0..<40 {
            let data = (try? Data(contentsOf: captured)) ?? Data()
            let slice = Data(data.dropFirst(min(beforeRegainCount, data.count)))
            if String(data: slice, encoding: .utf8)?.contains("\u{1B}[I") == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(80))

        // Dismissing QuickInput afterward must emit zero late \x1b[I or \x1b[O.
        let beforeDismissCount = (try? Data(contentsOf: captured))?.count ?? 0
        controller.dismissQuickInput()
        #expect(window.firstResponder === surface)
        #expect(!surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        try await Task.sleep(for: .milliseconds(100))
        let afterDismissData = (try? Data(contentsOf: captured)) ?? Data()
        let dismissDelta = Data(afterDismissData.dropFirst(min(beforeDismissCount, afterDismissData.count)))
        let dismissText = String(data: dismissDelta, encoding: .utf8) ?? ""
        #expect(!dismissText.contains("\u{1B}[I"))
        #expect(!dismissText.contains("\u{1B}[O"))
    }

    @Test @MainActor
    func hoveringOverFloatingQuickInputSuppressesSGRMouseMotionAndFocusFollowsMouse() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mouse_probe.py")
        let ready = root.appendingPathComponent("ready")
        let captured = root.appendingPathComponent("captured")
        try #"""
        import os, pathlib, tty
        tty.setraw(0)
        root = pathlib.Path(__file__).parent
        os.write(1, b"\x1b[?1003h\x1b[?1006h")
        (root / "ready").touch()
        buf = bytearray()
        while True:
            chunk = os.read(0, 4096)
            if not chunk:
                break
            buf.extend(chunk)
            (root / "captured").write_bytes(bytes(buf))
        """#.write(to: script, atomically: true, encoding: .utf8)

        let python = try #require(LocalPythonInterpreter.cached())
        var config = Ghostty.SurfaceConfiguration()
        config.command = Ghostty.Shell.quote(python.executablePath) + " " + Ghostty.Shell.quote(script.path)
        let controller = TerminalController(app, withBaseConfig: config)
        controller.showWindow(nil)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 800, height: 600))
        defer {
            controller.dismissQuickInput()
            window.delegate = nil
            window.close()
        }

        let surface = try #require(controller.focusedSurface)
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))

        controller.keyWindowOverrideForTesting = true
        controller.focusFollowsMouseOverrideForTesting = true
        controller.presentQuickInput(for: surface, requestFocus: false)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        let externalField = NSTextField(frame: NSRect(x: 0, y: 560, width: 80, height: 24))
        window.contentView?.addSubview(externalField)
        _ = window.makeFirstResponder(externalField)
        #expect(!surface.hasCompanionQuickInputFocus)
        #expect(!surface.focused)
        #expect(window.firstResponder !== surface)

        let occludedPoint = surface.convert(NSPoint(x: 120, y: 40), to: nil)
        #expect(surface.isPointOccludedByFloatingAccessory(inWindow: occludedPoint))
        let baselineCount = (try? Data(contentsOf: captured))?.count ?? 0

        let makeMouseMoveEvent = { (location: NSPoint) throws -> NSEvent in
            try #require(NSEvent.mouseEvent(
                with: .mouseMoved,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            ))
        }
        let makeEnterExitEvent = { (type: NSEvent.EventType, location: NSPoint) throws -> NSEvent in
            try #require(NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            ))
        }

        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        NSCursor.pointingHand.set()
        surface.cursorUpdate(with: try makeEnterExitEvent(.cursorUpdate, occludedPoint))
        #expect(NSCursor.current == NSCursor.pointingHand)
        surface.mouseEntered(with: try makeEnterExitEvent(.mouseEntered, occludedPoint))
        surface.mouseMoved(with: try makeMouseMoveEvent(occludedPoint))
        try await Task.sleep(for: .milliseconds(100))

        #expect(!surface.mouseOverSurface)
        #expect(!surface.focused, "Hovering over floating Quick Input must not trigger focusFollowsMouse")
        #expect(window.firstResponder !== surface)
        let afterOccludedData = (try? Data(contentsOf: captured)) ?? Data()
        let occludedSlice = Data(afterOccludedData.dropFirst(min(baselineCount, afterOccludedData.count)))
        let occludedText = String(data: occludedSlice, encoding: .utf8) ?? ""
        #expect(!occludedText.contains("\u{1B}[<35;"), "Occluded hover must emit zero SGR mouse motion")

        // Moving into the unoccluded upper terminal region still delivers SGR motion normally,
        // and moving back over floating Quick Input exits cleanly.
        let visiblePoint = surface.convert(NSPoint(x: 120, y: surface.bounds.height - 30), to: nil)
        #expect(!surface.isPointOccludedByFloatingAccessory(inWindow: visiblePoint))
        surface.mouseMoved(with: try makeMouseMoveEvent(visiblePoint))
        #expect(surface.mouseOverSurface)
        for _ in 0..<40 {
            let data = (try? Data(contentsOf: captured)) ?? Data()
            let slice = Data(data.dropFirst(min(afterOccludedData.count, data.count)))
            if String(data: slice, encoding: .utf8)?.contains("\u{1B}[<35;") == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let afterVisibleData = try Data(contentsOf: captured)
        let visibleText = String(data: Data(afterVisibleData.dropFirst(min(afterOccludedData.count, afterVisibleData.count))), encoding: .utf8) ?? ""
        #expect(visibleText.contains("\u{1B}[<35;"))

        surface.mouseMoved(with: try makeMouseMoveEvent(occludedPoint))
        #expect(!surface.mouseOverSurface)
    }
}
