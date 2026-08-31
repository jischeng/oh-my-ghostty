import AppKit
import Foundation
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
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: false,
            hasQueue: false
        ) == 0)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: true,
            hasQueue: false
        ) == 252 + divider)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: false,
            hasQueue: true
        ) == AgentQuickInputMetrics.queueLaneHeight + divider)
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 252,
            isDockPresented: true,
            hasQueue: true
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
}
