import AppKit
import Foundation
import GhosttyKit
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
        #expect(AgentQuickInputMetrics.queueCardHeight == 38)
        #expect(AgentQuickInputMetrics.queueFloatingHeight == 46)
        #expect(AgentQuickInputMetrics.collapsedQueueHeight == 28)
        #expect(AgentQuickInputMetrics.collapsedQueueWidth(
            labelCount: 2,
            availableWidth: 1_000
        ) == AgentQuickInputMetrics.collapsedQueueMinimumWidth)
        #expect(AgentQuickInputMetrics.collapsedQueueWidth(
            labelCount: 100,
            availableWidth: 1_000
        ) == AgentQuickInputMetrics.collapsedQueueMaximumWidth)
        #expect(AgentQuickInputMetrics.collapsedQueueWidth(
            labelCount: 100,
            availableWidth: 140
        ) == 108)
        #expect(AgentQuickInputMetrics.queueHoverDelayMilliseconds == 300)
        #expect(QuickInputQueueStackLayout.stackHeight(itemCount: 0) == 0)
        #expect(QuickInputQueueStackLayout.stackHeight(itemCount: 1) == 34)
        #expect(QuickInputQueueStackLayout.stackHeight(itemCount: 3) == 116)
        #expect(QuickInputQueueStackLayout.stackHeight(itemCount: 5) == 198)
        #expect(QuickInputQueueStackLayout.stackHeight(itemCount: 9) == 198)
        #expect(QuickInputQueueStackLayout.stackHeight(itemCount: 5, maxHeight: 120) == 120)
        #expect(QuickInputQueueStackLayout.capsuleWidth(
            previewCount: 2,
            availableWidth: 1_000
        ) == QuickInputQueueStackLayout.minimumCapsuleWidth)
        #expect(QuickInputQueueStackLayout.capsuleWidth(
            previewCount: 20,
            isEditing: false,
            availableWidth: 1_000
        ) == 280)
        #expect(QuickInputQueueStackLayout.capsuleWidth(
            previewCount: 20,
            isEditing: true,
            availableWidth: 1_000
        ) == 326)
        #expect(QuickInputQueueStackLayout.capsuleWidth(
            previewCount: 100,
            availableWidth: 1_000
        ) == QuickInputQueueStackLayout.maximumCapsuleWidth)
        #expect(QuickInputQueueStackLayout.capsuleWidth(
            previewCount: 100,
            availableWidth: 160
        ) == QuickInputQueueStackLayout.minimumCapsuleWidth)
    }

    @Test func queueStackWidthUnifiesShortLongAndCollapsedPillFloors() {
        let shortItem = AgentQuickInputQueueItem(text: "1234")
        let longItem = AgentQuickInputQueueItem(
            text: "investigate quick input capsule width synchronization"
        )

        #expect(AgentQuickInputMetrics.displayColumnCount("1234") == 4)
        #expect(AgentQuickInputMetrics.displayColumnCount("排队 1 · 1234") == 13)

        #expect(QuickInputQueueStackLayout.stackWidth(
            items: [shortItem],
            editingItemID: nil,
            availableWidth: 1_000
        ) == QuickInputQueueStackLayout.minimumCapsuleWidth)

        #expect(QuickInputQueueStackLayout.stackWidth(
            items: [shortItem],
            editingItemID: nil,
            availableWidth: 1_000,
            minimumWidth: 210
        ) == 210)

        let longOnlyWidth = QuickInputQueueStackLayout.stackWidth(
            items: [longItem],
            editingItemID: nil,
            availableWidth: 1_000,
            minimumWidth: 150
        )
        let mixedWidth = QuickInputQueueStackLayout.stackWidth(
            items: [shortItem, longItem],
            editingItemID: nil,
            availableWidth: 1_000,
            minimumWidth: 150
        )
        #expect(mixedWidth == longOnlyWidth)
        #expect(mixedWidth > QuickInputQueueStackLayout.minimumCapsuleWidth)

        #expect(QuickInputQueueStackLayout.stackWidth(
            items: [longItem],
            editingItemID: nil,
            availableWidth: 160,
            minimumWidth: 108
        ) == 128)
    }

    @Test func accessoryHeightNeverReservesInFlowTerminalSpace() {
        #expect(AgentQuickInputMetrics.minimumHeight == 96)
        #expect(AgentQuickInputMetrics.defaultHeight == 165)
        #expect(AgentQuickInputMetrics.maximumHeight == 480)
        #expect(AgentQuickInputMetrics.floatingHorizontalInset == 16)
        #expect(AgentQuickInputMetrics.floatingBottomInset == 12)
        #expect(AgentQuickInputMetrics.floatingStackSpacing == 8)
        #expect(AgentQuickInputMetrics.floatingTopMargin == 16)
        #expect(AgentQuickInputMetrics.cardCornerRadius == 12)
        for pinned in [false, true] {
            for presented in [false, true] {
                for hasQueue in [false, true] {
                    #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
                        dockHeight: 148,
                        isDockPresented: presented,
                        hasQueue: hasQueue,
                        isPinned: pinned
                    ) == 0)
                }
            }
        }
        #expect(AgentQuickInputMetrics.reservedAccessoryHeight(
            dockHeight: 148,
            isDockPresented: true,
            hasQueue: false
        ) == 0)

        let english = SettingsStrings(language: .english)
        let chinese = SettingsStrings(language: .simplifiedChinese)
        #expect(english.quickInputPlaceholder == "Type multiline input — ⌘↩ send, ⇧↩ newline, ⌥⌘↩ queue…")
        #expect(chinese.quickInputPlaceholder == "输入多行内容，⌘↩ 发送，⇧↩ 换行，⌥⌘↩ 排队…")
        #expect(english.quickInputEditQueuedPlaceholder == "Edit queued message — ⌘↩ save, ⎋ cancel…")
        #expect(chinese.quickInputEditQueuedPlaceholder == "编辑排队消息，⌘↩ 保存，⎋ 取消…")
        #expect(english.quickInputCancelTitle == "Cancel")
        #expect(chinese.quickInputCancelTitle == "关闭")
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
        let expected = localCaretRect.maxX + ComposerTextView.placeholderCaretGap

        #expect(ComposerTextView.placeholderCaretGap == 3)
        #expect(abs(origin.x - expected) < 0.01)
        #expect(origin.x >= localCaretRect.maxX + 3)
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
    func dockedQuickInputShrinksVisuallyWithZeroSIGWINCHZeroCtrlGAndZeroDEC1004FocusChatter() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("probe.py")
        let ready = root.appendingPathComponent("ready")
        let captured = root.appendingPathComponent("captured")
        let winchFile = root.appendingPathComponent("winch")
        try #"""
        import os, pathlib, signal, tty
        tty.setraw(0)
        root = pathlib.Path(__file__).parent
        winches = 0
        def on_winch(signum, frame):
            global winches
            winches += 1
            (root / "winch").write_text(str(winches))
        signal.signal(signal.SIGWINCH, on_winch)
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
        _ = window.makeFirstResponder(surface)
        surface.focusDidChange(true)
        try await Task.sleep(for: .milliseconds(100))

        let baselineBytes = (try? Data(contentsOf: captured))?.count ?? 0
        let baselineWinches = Int((try? String(contentsOf: winchFile, encoding: .utf8)) ?? "0") ?? 0
        let initialSurfaceFrame = surface.frame
        let expectedDockedHeight = initialSurfaceFrame.height - controller.quickInputModel.dockHeight
        #expect(!controller.quickInputModel.isPinned)
        #expect(surface.focused)

        // 1. Open Quick Input (⌘⇧E); it docks in-flow below the terminal visually without SIGWINCH.
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        func findEditor(_ view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap(findEditor).first
        }
        try await waitForAppKit {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let editor = window.contentView.flatMap(findEditor) else { return false }
            return !editor.isHiddenOrHasHiddenAncestor
        }
        let editor = try #require(window.contentView.flatMap(findEditor))
        controller.focusQuickInputEditor(editor, for: surface.id)
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        #expect(surface.layer?.opacity == 1)
        #expect(abs(surface.frame.height - expectedDockedHeight) < 1)
        #expect(!surface.isPointOccludedByFloatingAccessory(
            inWindow: surface.convert(NSPoint(x: 100, y: 40), to: nil)
        ))

        // 2. Round-trip focus between ComposerTextView and SurfaceView (⌘⌥↑ / ⌘⌥↓).
        controller.restoreTerminalFocus(surfaceID: surface.id)
        #expect(window.firstResponder === surface)
        #expect(!surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        controller.focusQuickInputEditor(editor, for: surface.id)
        #expect(window.firstResponder === editor)
        #expect(surface.hasCompanionQuickInputFocus)
        #expect(surface.focused)
        #expect(abs(surface.frame.height - expectedDockedHeight) < 1)

        // 3. Queue a message while unpinned; dismissing restores full surface height with zero SIGWINCH.
        controller.quickInputModel.draft = "queued while unpinned"
        controller.queueQuickInputDraft()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.quickInputModel.state(for: surface.id)?.queue.count == 1)
        #expect(surface.frame == initialSurfaceFrame)
        #expect(surface.focused)

        // 4. Open again, send a draft, and dismiss on completion with zero SIGWINCH.
        controller.toggleQuickInput()
        window.contentView?.layoutSubtreeIfNeeded()
        controller.focusQuickInputEditor(editor, for: surface.id)
        controller.quickInputModel.draft = "direct floating send"
        controller.sendQuickInputDraft()

        for _ in 0..<80 {
            let allData = (try? Data(contentsOf: captured)) ?? Data()
            let delta = allData.dropFirst(min(baselineBytes, allData.count))
            if let text = String(data: delta, encoding: .utf8), text.contains("direct floating send"), text.hasSuffix("\r") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(surface.frame == initialSurfaceFrame)
        #expect(surface.layer?.opacity == 1)
        #expect(surface.focused)

        let afterWinches = Int((try? String(contentsOf: winchFile, encoding: .utf8)) ?? "0") ?? 0
        #expect(afterWinches == baselineWinches, "Docking/undocking Quick Input must emit zero SIGWINCH to the PTY")

        let allData = try Data(contentsOf: captured)
        let roundTripSlice = Data(allData.dropFirst(min(baselineBytes, allData.count)))
        let roundTripText = try #require(String(data: roundTripSlice, encoding: .utf8))
        #expect(roundTripText.contains("direct floating send"))
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
    func floatingQuickInputAlwaysUsesOpaqueQuantizedThemeBackground() throws {
        let darkThemeColor = Color(.sRGB, red: 0.12, green: 0.13, blue: 0.19, opacity: 1)
        let expectedDarkColor = try #require(
            NSColor(TerminalController.chromeBackground(
                color: darkThemeColor,
                opacity: 0.62,
                windowIsOpaque: true,
                usesWindowGlass: false
            )).usingColorSpace(.sRGB)
        )

        // 1. Translucent background-opacity < 1.0 still yields a 100% opaque renderer-matched theme card.
        let translucentChrome = TerminalController.chromeBackground(
            color: darkThemeColor,
            opacity: 0.62,
            windowIsOpaque: false,
            usesWindowGlass: false
        )
        let unpinnedTranslucent = TerminalController.quickInputAccessoryBackground(
            isPinned: false,
            chromeBackground: translucentChrome,
            color: darkThemeColor,
            opacity: 0.62
        )
        let pinnedTranslucent = TerminalController.quickInputAccessoryBackground(
            isPinned: true,
            chromeBackground: translucentChrome,
            color: darkThemeColor,
            opacity: 0.62
        )
        let unpinnedTranslucentColor = try #require(NSColor(unpinnedTranslucent).usingColorSpace(.sRGB))
        let pinnedTranslucentColor = try #require(NSColor(pinnedTranslucent).usingColorSpace(.sRGB))
        #expect(unpinnedTranslucentColor.alphaComponent == 1.0)
        #expect(pinnedTranslucentColor.alphaComponent == 1.0)
        #expect(abs(unpinnedTranslucentColor.redComponent - expectedDarkColor.redComponent) < 0.005)
        #expect(abs(unpinnedTranslucentColor.greenComponent - expectedDarkColor.greenComponent) < 0.005)
        #expect(abs(unpinnedTranslucentColor.blueComponent - expectedDarkColor.blueComponent) < 0.005)
        #expect(abs(pinnedTranslucentColor.redComponent - expectedDarkColor.redComponent) < 0.005)
        #expect(abs(pinnedTranslucentColor.greenComponent - expectedDarkColor.greenComponent) < 0.005)
        #expect(abs(pinnedTranslucentColor.blueComponent - expectedDarkColor.blueComponent) < 0.005)

        // 2. macOS glass style (usesWindowGlass = true -> terminalChromeBackground is .clear) stays opaque.
        let glassChrome = TerminalController.chromeBackground(
            color: darkThemeColor,
            opacity: 0.62,
            windowIsOpaque: false,
            usesWindowGlass: true
        )
        let unpinnedGlass = TerminalController.quickInputAccessoryBackground(
            isPinned: false,
            chromeBackground: glassChrome,
            color: darkThemeColor,
            opacity: 0.62
        )
        let pinnedGlass = TerminalController.quickInputAccessoryBackground(
            isPinned: true,
            chromeBackground: glassChrome,
            color: darkThemeColor,
            opacity: 0.62
        )
        let unpinnedGlassColor = try #require(NSColor(unpinnedGlass).usingColorSpace(.sRGB))
        let pinnedGlassColor = try #require(NSColor(pinnedGlass).usingColorSpace(.sRGB))
        #expect(unpinnedGlassColor.alphaComponent == 1.0)
        #expect(pinnedGlassColor.alphaComponent == 1.0)
        #expect(abs(unpinnedGlassColor.redComponent - expectedDarkColor.redComponent) < 0.005)
        #expect(abs(unpinnedGlassColor.greenComponent - expectedDarkColor.greenComponent) < 0.005)
        #expect(abs(unpinnedGlassColor.blueComponent - expectedDarkColor.blueComponent) < 0.005)

        // 3. Light theme matches exact opaque renderer-quantized Display P3 theme color.
        let lightThemeColor = Color(.sRGB, red: 0.95, green: 0.95, blue: 0.97, opacity: 1)
        let expectedLightColor = try #require(
            NSColor(TerminalController.chromeBackground(
                color: lightThemeColor,
                opacity: 0.5,
                windowIsOpaque: true,
                colorspaceIsDisplayP3: true,
                usesWindowGlass: false
            )).usingColorSpace(.sRGB)
        )
        let lightCard = TerminalController.quickInputAccessoryBackground(
            isPinned: false,
            chromeBackground: .clear,
            color: lightThemeColor,
            opacity: 0.5,
            colorspaceIsDisplayP3: true
        )
        let lightNSColor = NSColor(lightCard)
        #expect(lightNSColor.alphaComponent == 1.0)
        let lightSRGB = try #require(lightNSColor.usingColorSpace(.sRGB))
        #expect(lightSRGB.alphaComponent == 1.0)
        #expect(abs(lightSRGB.redComponent - expectedLightColor.redComponent) < 0.005)
        #expect(abs(lightSRGB.greenComponent - expectedLightColor.greenComponent) < 0.005)
        #expect(abs(lightSRGB.blueComponent - expectedLightColor.blueComponent) < 0.005)
    }

    @Test func quickInputDockedBackgroundMatchesRenderedTerminalChromeAcrossWindowModes() throws {
        let darkThemeColor = Color(.sRGB, red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 46.0 / 255.0, opacity: 1)

        // 1. Translucent non-glass window matches translucent terminal chrome (NOT 100% opaque).
        let expectedTranslucent = TerminalController.chromeBackground(
            color: darkThemeColor,
            opacity: 0.72,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: true,
            linearBlending: false,
            usesWindowGlass: false
        )
        let dockedTranslucent = TerminalController.quickInputDockedBackground(
            color: darkThemeColor,
            opacity: 0.72,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: true,
            linearBlending: false,
            usesWindowGlass: false
        )
        let expectedTranslucentNS = try #require(NSColor(expectedTranslucent).usingColorSpace(.sRGB))
        let dockedTranslucentNS = try #require(NSColor(dockedTranslucent).usingColorSpace(.sRGB))
        #expect(dockedTranslucentNS.alphaComponent < 0.99)
        #expect(abs(dockedTranslucentNS.alphaComponent - expectedTranslucentNS.alphaComponent) < 0.005)
        #expect(abs(dockedTranslucentNS.redComponent - expectedTranslucentNS.redComponent) < 0.005)
        #expect(abs(dockedTranslucentNS.greenComponent - expectedTranslucentNS.greenComponent) < 0.005)
        #expect(abs(dockedTranslucentNS.blueComponent - expectedTranslucentNS.blueComponent) < 0.005)

        // 2. macOS liquid glass window stays clear so TerminalGlassView is not double-tinted.
        let dockedGlass = TerminalController.quickInputDockedBackground(
            color: darkThemeColor,
            opacity: 0.72,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: true,
            usesWindowGlass: true
        )
        #expect(dockedGlass == .clear)

        // 3. Opaque / fullscreen window paints exact quantized opaque terminal color even with glass enabled.
        let expectedOpaque = TerminalController.chromeBackground(
            color: darkThemeColor,
            opacity: 0.72,
            windowIsOpaque: true,
            colorspaceIsDisplayP3: true,
            usesWindowGlass: true
        )
        let dockedOpaque = TerminalController.quickInputDockedBackground(
            color: darkThemeColor,
            opacity: 0.72,
            windowIsOpaque: true,
            colorspaceIsDisplayP3: true,
            usesWindowGlass: true
        )
        let expectedOpaqueNS = try #require(NSColor(expectedOpaque).usingColorSpace(.sRGB))
        let dockedOpaqueNS = try #require(NSColor(dockedOpaque).usingColorSpace(.sRGB))
        #expect(dockedOpaqueNS.alphaComponent == 1.0)
        #expect(abs(dockedOpaqueNS.redComponent - expectedOpaqueNS.redComponent) < 0.005)
        #expect(abs(dockedOpaqueNS.greenComponent - expectedOpaqueNS.greenComponent) < 0.005)
        #expect(abs(dockedOpaqueNS.blueComponent - expectedOpaqueNS.blueComponent) < 0.005)
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
    func shortPaneFloatingFallbackOccludesCardRectAndPreservesMarginMouseHover() async throws {
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
        // Below minimumDockedPaneHeight (256pt) so Quick Input uses the floating overlay fallback.
        window.setContentSize(NSSize(width: 800, height: 240))
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
        let initialSurfaceFrame = surface.frame
        let cardPoint = surface.convert(NSPoint(x: 120, y: 40), to: nil)

        controller.keyWindowOverrideForTesting = true
        controller.focusFollowsMouseOverrideForTesting = true
        controller.presentQuickInput(for: surface, requestFocus: false)
        try await waitForAppKit {
            window.contentView?.layoutSubtreeIfNeeded()
            return surface.isPointOccludedByFloatingAccessory(inWindow: cardPoint)
        }

        #expect(surface.frame == initialSurfaceFrame)
        let dockHit = try #require(window.contentView?.hitTest(cardPoint))
        #expect(dockHit !== surface && !dockHit.isDescendant(of: surface))

        let externalField = NSTextField(frame: NSRect(x: 0, y: 200, width: 80, height: 24))
        window.contentView?.addSubview(externalField)
        _ = window.makeFirstResponder(externalField)
        #expect(!surface.hasCompanionQuickInputFocus)
        #expect(!surface.focused)
        #expect(window.firstResponder !== surface)

        let leftMarginPoint = surface.convert(NSPoint(x: 6, y: 40), to: nil)
        let bottomMarginPoint = surface.convert(NSPoint(x: 120, y: 6), to: nil)
        let aboveCardPoint = surface.convert(NSPoint(x: 120, y: surface.bounds.height - 20), to: nil)
        #expect(surface.isPointOccludedByFloatingAccessory(inWindow: cardPoint))
        #expect(!surface.isPointOccludedByFloatingAccessory(inWindow: leftMarginPoint))
        #expect(!surface.isPointOccludedByFloatingAccessory(inWindow: bottomMarginPoint))
        #expect(!surface.isPointOccludedByFloatingAccessory(inWindow: aboveCardPoint))
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
        surface.mouseMoved(with: try makeMouseMoveEvent(cardPoint))
        #expect(!surface.mouseOverSurface)

        surface.mouseMoved(with: try makeMouseMoveEvent(aboveCardPoint))
        #expect(surface.mouseOverSurface)
        for _ in 0..<40 {
            let data = (try? Data(contentsOf: captured)) ?? Data()
            let slice = Data(data.dropFirst(min(baselineCount, data.count)))
            if String(data: slice, encoding: .utf8)?.contains("\u{1B}[<35;") == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let afterData = try Data(contentsOf: captured)
        let text = String(data: Data(afterData.dropFirst(min(baselineCount, afterData.count))), encoding: .utf8) ?? ""
        #expect(text.contains("\u{1B}[<35;"))
    }

    @Test func presentCancelsQueueEditAcrossPaneSwitchesWithoutCorruptingTargetDraft() throws {
        let global = QuickInputGlobalPresentation()
        var currentPane = UUID()
        let paneA = currentPane
        let paneB = UUID()
        let model = AgentQuickInputModel(globalPresentation: global)
        model.bindGlobalTarget { currentPane }

        model.present(for: paneA)
        model.draft = "queued item"
        let queued = try #require(model.enqueueDraft())
        model.draft = "pane A original"

        model.present(for: paneB)
        model.draft = "pane B original"

        model.editQueuedItem(queued.id, for: paneA)
        #expect(model.isEditingQueuedItem)
        #expect(model.targetSurfaceID == paneA)
        model.draft = "unsaved queue edit"

        // Direct switch via present(for:)
        model.present(for: paneB, requestFocus: false)
        #expect(!model.isEditingQueuedItem)
        #expect(model.isPresented)
        #expect(model.targetSurfaceID == paneB)
        #expect(model.draft == "pane B original")
        #expect(model.state(for: paneA)?.draft == "pane A original")
        #expect(model.state(for: paneA)?.queue == [queued])

        // Global target switch while editing queued item on Pane A
        model.editQueuedItem(queued.id, for: paneA)
        model.draft = "another unsaved queue edit"
        currentPane = paneB
        model.bindGlobalTarget { currentPane }
        #expect(!model.isEditingQueuedItem)
        #expect(model.isPresented)
        #expect(model.targetSurfaceID == paneB)
        #expect(model.draft == "pane B original")
        #expect(model.state(for: paneA)?.draft == "pane A original")
    }

    @Test func dockHeightSyncsBidirectionallyBetweenWorkspaceStoreAndSettingsWithoutCycles() throws {
        let settings = OhMyGhosttySettings.shared
        let previousHeight = settings.quickInputHeight
        defer { settings.quickInputHeight = previousHeight }

        let defaultGlobal = QuickInputGlobalPresentation()
        #expect(defaultGlobal.height == 165)
        defaultGlobal.setHeight(50)
        #expect(defaultGlobal.height == 96)

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator = TerminalWorkspaceCoordinator(store: store)
        coordinator.finishRestoring()
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 800, height: 600))
        defer {
            window.delegate = nil
            window.close()
        }

        // 1. Divider persist updates both workspace store and OhMyGhosttySettings.shared.
        controller.updateQuickInputHeight(220, persist: true)
        #expect(controller.quickInputModel.dockHeight == 220)
        #expect(store.quickInputPresentation(for: controller.workspaceID).height == 220)
        #expect(store.presentation(for: controller.workspaceID).quickInputHeight == 220)
        #expect(settings.quickInputHeight == 220)

        // 2. Settings height change pushes into workspace store presentation and model without cycling back.
        settings.quickInputHeight = 188
        #expect(store.quickInputPresentation(for: controller.workspaceID).height == 188)
        #expect(store.presentation(for: controller.workspaceID).quickInputHeight == 188)
        #expect(controller.quickInputModel.dockHeight == 188)
        #expect(settings.quickInputHeight == 188)

        // 3. Floating vertical insets are subtracted from available height without queue lane reservation.
        let surface = try #require(controller.focusedSurface)
        controller.quickInputModel.present(for: surface.id, requestFocus: false)
        controller.quickInputModel.draft = "queued"
        _ = controller.quickInputModel.enqueueDraft()
        window.setContentSize(NSSize(width: 800, height: 420))
        let contentHeight = window.contentLayoutRect.height
        let expectedAvailable = max(
            0,
            contentHeight
                - AgentQuickInputMetrics.floatingBottomInset
                - AgentQuickInputMetrics.floatingTopMargin
        )
        #expect(abs(controller.quickInputAvailableHeight() - expectedAvailable) < 0.01)
        controller.updateQuickInputHeight(400, persist: true)
        let expectedMax = max(
            AgentQuickInputMetrics.minimumHeight,
            expectedAvailable - AgentQuickInputMetrics.minimumTerminalHeight
        )
        #expect(abs(controller.quickInputModel.dockHeight - expectedMax) < 0.01)
    }

    @Test func imeMarkedTextPreventsOptionArrowMovementInterception() throws {
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 123,
            modifiers: [.option],
            hasMarkedText: false
        ) == .wordBackward(modifySelection: false))
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 123,
            modifiers: [.option],
            hasMarkedText: true
        ) == nil)
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 124,
            modifiers: [.option, .shift],
            hasMarkedText: true
        ) == nil)
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 126,
            modifiers: [.option],
            hasMarkedText: true
        ) == nil)
        #expect(AgentQuickInputMovementCommand.resolve(
            keyCode: 125,
            modifiers: [.option],
            hasMarkedText: true
        ) == nil)

        var performedMovementSelectors: [Selector] = []
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.performMovementSelector = {
            performedMovementSelectors.append($0)
            return true
        }
        editor.string = "hello"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        let optionLeft = try #require(keyEvent(keyCode: 123, modifiers: [.option]))
        editor.keyDown(with: optionLeft)
        #expect(performedMovementSelectors.isEmpty,
                "Option+Left during IME composition must not be intercepted by ComposerTextView")

        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        editor.keyDown(with: optionLeft)
        #expect(performedMovementSelectors == [
            #selector(NSStandardKeyBindingResponding.moveWordBackward(_:)),
        ])
    }

    @Test func composerCommandsRequireExactCommandModifiers() throws {
        let editor = ComposerTextView()
        var sent = 0
        var queued = 0
        editor.onSend = { sent += 1 }
        editor.onQueue = { queued += 1 }

        let send = try #require(keyEvent(keyCode: 36, modifiers: [.command]))
        #expect(editor.performKeyEquivalent(with: send))
        #expect(sent == 1 && queued == 0)

        let keypadSend = try #require(keyEvent(keyCode: 76, modifiers: [.command, .numericPad, .capsLock]))
        #expect(editor.performKeyEquivalent(with: keypadSend))
        #expect(sent == 2 && queued == 0)

        let queue = try #require(keyEvent(keyCode: 36, modifiers: [.command, .option]))
        #expect(editor.performKeyEquivalent(with: queue))
        #expect(sent == 2 && queued == 1)

        for extraModifiers in [
            NSEvent.ModifierFlags([.command, .shift]),
            [.command, .control],
            [.command, .option, .shift],
            [.command, .option, .control],
        ] {
            let ignored = try #require(keyEvent(keyCode: 36, modifiers: extraModifiers))
            #expect(!editor.performKeyEquivalent(with: ignored))
        }
        #expect(sent == 2 && queued == 1)
    }

    @Test func programmaticHistoryAndDraftInsertionPreservesLocalUndoOnSamePaneAndResetsOnPaneSwitchOrClear() async throws {
        struct ComposerHostWrapper: View {
            @ObservedObject var model: AgentQuickInputModel
            let font: NSFont

            var body: some View {
                AgentQuickInputTextEditor(
                    text: $model.draft,
                    placeholder: "Type here…",
                    isPresented: model.isPresented,
                    focusRequestID: model.focusRequestID,
                    font: font,
                    onPasteImage: nil,
                    onSend: {},
                    onQueue: {},
                    onCancel: {},
                    companionSurfaceID: model.targetSurfaceID
                )
            }
        }

        let paneA = UUID()
        let paneB = UUID()
        let model = AgentQuickInputModel()
        model.togglePinned()
        model.present(for: paneB, requestFocus: false)
        model.draft = "pane B draft"
        model.present(for: paneA, requestFocus: false)

        let font = QuickInputTypography.font(family: "Menlo", size: 13)
        let host = NSHostingView(rootView: ComposerHostWrapper(model: model, font: font))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        func find(_ view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let editor = try #require(find(host))
        #expect(window.makeFirstResponder(editor))

        // 1. User types initial draft.
        editor.insertText("typed", replacementRange: editor.selectedRange())
        #expect(model.draft == "typed")
        #expect(editor.undoManager?.canUndo == true)

        // 2. Programmatic history/draft insertion on the SAME pane preserves undo stack.
        model.useHistoryText("from history", mode: .append)
        try await waitForAppKit {
            host.layoutSubtreeIfNeeded()
            return editor.string == "typed\nfrom history"
        }
        #expect(editor.undoManager?.canUndo == true)

        let undoEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        ))
        #expect(editor.performKeyEquivalent(with: undoEvent))
        #expect(editor.string == "typed")
        #expect(editor.performKeyEquivalent(with: undoEvent))
        #expect(editor.string.isEmpty)

        // 3. Switching panes resets localUndoManager.
        editor.insertText("pane A draft", replacementRange: editor.selectedRange())
        #expect(editor.undoManager?.canUndo == true)
        model.present(for: paneB, requestFocus: false)
        try await waitForAppKit {
            host.layoutSubtreeIfNeeded()
            return editor.string == "pane B draft"
        }
        #expect(editor.undoManager?.canUndo == false)

        // 4. Post-submit clear (empty text) resets localUndoManager.
        editor.insertText(" edited", replacementRange: editor.selectedRange())
        #expect(editor.undoManager?.canUndo == true)
        model.completeSubmittedDraft(model.draft, for: paneB)
        try await waitForAppKit {
            host.layoutSubtreeIfNeeded()
            return editor.string.isEmpty
        }
        #expect(editor.undoManager?.canUndo == false)
    }

    @Test func settleDelayAppliesOnlyToMultilineNonEditorSends() {
        #expect(!TerminalController.quickInputRequiresSettleDelay(
            text: "single line prompt",
            usesEditorReplacement: false
        ))
        #expect(!TerminalController.quickInputRequiresSettleDelay(
            text: "line1\nline2",
            usesEditorReplacement: true
        ))
        #expect(TerminalController.quickInputRequiresSettleDelay(
            text: "line1\nline2",
            usesEditorReplacement: false
        ))
        #expect(TerminalController.quickInputRequiresSettleDelay(
            text: "line1\rline2",
            usesEditorReplacement: false
        ))
    }

    @Test func surfaceScrollViewClampsPaddingNonNegativeAndSynchronizesOnShrink() throws {
        let scrollbar = Ghostty.Action.Scrollbar(
            c: ghostty_action_scrollbar_s(total: 100, offset: 70, len: 30)
        )
        // Shrunk contentHeight before .ghosttyDidUpdateScrollbar arrives:
        // padding = max(0, 451 - 30*20) = 0 -> documentHeight = 100 * 20 = 2000 (not 1851).
        #expect(SurfaceScrollView.documentHeight(
            contentHeight: 451,
            cellHeight: 20,
            scrollbar: scrollbar
        ) == 2000)
        // Taller contentHeight preserves positive alignment padding.
        #expect(SurfaceScrollView.documentHeight(
            contentHeight: 620,
            cellHeight: 20,
            scrollbar: Ghostty.Action.Scrollbar(
                c: ghostty_action_scrollbar_s(total: 30, offset: 0, len: 30)
            )
        ) == 620)

        let native = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let surface = Ghostty.SurfaceView(native, baseConfig: config)
        let lease = SurfacePresentationLease()
        surface.presentation.authorize(lease)
        let wrapper = SurfaceScrollView(
            contentSize: CGSize(width: 800, height: 600),
            surfaceView: surface,
            lease: lease
        )
        wrapper.setFrameSize(NSSize(width: 800, height: 600))
        wrapper.layoutSubtreeIfNeeded()
        surface.cellSize = CGSize(width: 10, height: 20)
        surface.scrollbar = scrollbar
        wrapper.setFrameSize(NSSize(width: 800, height: 400))
        wrapper.layoutSubtreeIfNeeded()

        let innerScroll = try #require(wrapper.subviews.first as? NSScrollView)
        let docView = try #require(innerScroll.documentView)
        #expect(docView.frame.height >= 2000)
        #expect(surface.frame.size == CGSize(width: 800, height: 400))
    }

    @Test @MainActor
    func collapsedQueuePillExpandHelperPresentsQuickInputForTargetSurface() throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        let surface = try #require(controller.surfaceTree.first)

        controller.quickInputModel.present(for: surface.id, requestFocus: false)
        controller.quickInputModel.draft = "queued prompt"
        #expect(controller.quickInputModel.enqueueDraft() != nil)
        controller.quickInputModel.dismiss()
        #expect(!controller.quickInputModel.isPresented)

        controller.presentQuickInput(forSurfaceID: surface.id)
        #expect(controller.quickInputModel.isPresented)
        #expect(controller.quickInputModel.targetSurfaceID == surface.id)
    }

    @Test @MainActor
    func perPaneQueuedEditOpensQuickInputTargetsOwningPaneAndRequestsFocus() throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }

        let paneA = try #require(controller.surfaceTree.first)
        let paneB = try #require(controller.newSplit(at: paneA, direction: .right, baseConfig: config))

        controller.quickInputModel.present(for: paneA.id, requestFocus: false)
        controller.quickInputModel.draft = "task for pane A"
        let itemA = try #require(controller.quickInputModel.enqueueDraft())

        controller.quickInputModel.present(for: paneB.id, requestFocus: false)
        controller.quickInputModel.draft = "task for pane B"
        let itemB = try #require(controller.quickInputModel.enqueueDraft())
        controller.quickInputModel.dismiss()

        #expect(controller.quickInputModel.state(for: paneA.id)?.queue == [itemA])
        #expect(controller.quickInputModel.state(for: paneB.id)?.queue == [itemB])

        let baselineFocusID = controller.quickInputModel.focusRequestID
        controller.editQueuedQuickInput(itemA.id, from: paneA.id)

        #expect(controller.quickInputModel.isPresented)
        #expect(controller.quickInputModel.targetSurfaceID == paneA.id)
        #expect(controller.quickInputModel.editingQueueItemID == itemA.id)
        #expect(controller.quickInputModel.draft == "task for pane A")
        #expect(controller.quickInputModel.focusRequestID == baselineFocusID + 1)
        #expect(controller.quickInputLastTerminalSurfaceID == paneA.id)
    }

    @Test @MainActor
    func composerQueueExpandedStateResetsAcrossLifecycleTransitions() throws {
        let model = AgentQuickInputModel(dockHeight: 148)
        let paneA = UUID()
        let paneB = UUID()

        model.present(for: paneA, requestFocus: false)
        model.draft = "queued one"
        let item1 = try #require(model.enqueueDraft())
        model.draft = "queued two"
        let item2 = try #require(model.enqueueDraft())

        // Toggling open closes History if open; toggling again closes it.
        model.toggleHistory(scope: .pane)
        #expect(model.historyPresentation.isPresented)
        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        #expect(!model.historyPresentation.isPresented)

        // Opening History closes the expanded queue stack.
        model.toggleHistory(scope: .pane)
        #expect(model.historyPresentation.isPresented)
        #expect(!model.isQueueExpanded)

        // Typing into the composer draft collapses the queue stack.
        model.toggleHistory(scope: .pane)
        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        model.draft = "typing"
        #expect(!model.isQueueExpanded)

        // Switching target pane collapses the queue stack.
        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        model.present(for: paneB, requestFocus: false)
        #expect(!model.isQueueExpanded)

        // Editing a queued item collapses the queue stack.
        model.present(for: paneA, requestFocus: false)
        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        model.editQueuedItem(item1.id, for: paneA)
        #expect(!model.isQueueExpanded)
        model.cancelQueuedItemEdit()

        // Removing/dequeuing only collapses once the target queue empties, and dismiss resets it.
        model.present(for: paneA, requestFocus: false)
        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        model.removeQueuedItem(item1.id, for: paneA)
        #expect(model.isQueueExpanded)
        _ = model.dequeue(for: paneA)
        #expect(!model.isQueueExpanded)
        _ = item2

        model.draft = "another"
        _ = try #require(model.enqueueDraft())
        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        model.dismiss()
        #expect(!model.isQueueExpanded)
    }

    @Test @MainActor
    func collapseAccessoryStacksAndTypingDraftCloseHistoryWhileRetainingQuery() throws {
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 148, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)
        model.recordSentText("first command", for: pane)
        model.draft = "pending task"
        _ = try #require(model.enqueueDraft())

        model.toggleHistory(scope: .tab)
        model.historyPresentation.beginSearch()
        model.historyPresentation.query = "first"
        #expect(model.historyPresentation.isPresented)
        #expect(!model.isQueueExpanded)

        // Typing into the composer draft collapses History while keeping its search query.
        model.draft = "hello"
        #expect(!model.historyPresentation.isPresented)
        #expect(model.historyPresentation.query == "first")
        #expect(model.historyPresentation.isSearching)

        // Reopening preserves the search query, and collapseAccessoryStacks closes either active stack.
        model.toggleHistory(scope: .tab)
        #expect(model.historyPresentation.isPresented)
        model.collapseAccessoryStacks()
        #expect(!model.historyPresentation.isPresented)
        #expect(!model.isQueueExpanded)
        #expect(model.historyPresentation.query == "first")

        model.toggleQueueExpanded()
        #expect(model.isQueueExpanded)
        model.collapseAccessoryStacks()
        #expect(!model.isQueueExpanded)
    }

    @Test func quickInputGlassRecipeScalesMonotonicallyAndOrdersSurfaceRoles() {
        #expect(AgentQuickInputMetrics.defaultOpacity == 0.70)

        let levels = [0.05, 0.25, 0.45, 0.70, 1.0]
        var previousComposer = AgentQuickInputMetrics.QuickInputGlassRecipe(backdropOpacity: -1, tintOpacity: -1)
        for level in levels {
            let composer = AgentQuickInputMetrics.glassRecipe(role: .composer, opacity: level)
            #expect(composer.backdropOpacity > previousComposer.backdropOpacity)
            #expect(composer.tintOpacity > previousComposer.tintOpacity)
            previousComposer = composer
        }

        let minimalComposer = AgentQuickInputMetrics.glassRecipe(role: .composer, opacity: 0.05)
        #expect(minimalComposer.backdropOpacity <= 0.20)
        #expect(minimalComposer.tintOpacity <= 0.05)

        let fullRoles: [AgentQuickInputMetrics.QuickInputGlassRole] = [
            .composer,
            .collapsedQueuePill(emphasized: false),
            .collapsedQueuePill(emphasized: true),
            .standaloneQueueCapsule(emphasized: false),
            .standaloneQueueCapsule(emphasized: true),
            .elevatedCapsule(emphasized: false),
            .elevatedCapsule(emphasized: true),
        ]
        for role in fullRoles {
            let full = AgentQuickInputMetrics.glassRecipe(role: role, opacity: 1.0)
            #expect(full.backdropOpacity == 1.0)
            #expect(full.tintOpacity == 1.0)
        }

        let defaultOpacity = AgentQuickInputMetrics.defaultOpacity
        let composer = AgentQuickInputMetrics.glassRecipe(role: .composer, opacity: defaultOpacity)
        let pill = AgentQuickInputMetrics.glassRecipe(
            role: .collapsedQueuePill(emphasized: false),
            opacity: defaultOpacity
        )
        let pillEmphasized = AgentQuickInputMetrics.glassRecipe(
            role: .collapsedQueuePill(emphasized: true),
            opacity: defaultOpacity
        )
        let standalone = AgentQuickInputMetrics.glassRecipe(
            role: .standaloneQueueCapsule(emphasized: false),
            opacity: defaultOpacity
        )
        let standaloneEmphasized = AgentQuickInputMetrics.glassRecipe(
            role: .standaloneQueueCapsule(emphasized: true),
            opacity: defaultOpacity
        )
        let elevated = AgentQuickInputMetrics.glassRecipe(
            role: .elevatedCapsule(emphasized: false),
            opacity: defaultOpacity
        )
        let elevatedEmphasized = AgentQuickInputMetrics.glassRecipe(
            role: .elevatedCapsule(emphasized: true),
            opacity: defaultOpacity
        )

        #expect(composer.tintOpacity < pill.tintOpacity)
        #expect(pill.tintOpacity < standalone.tintOpacity)
        #expect(standalone.tintOpacity < elevated.tintOpacity)
        #expect(pillEmphasized.backdropOpacity >= pill.backdropOpacity)
        #expect(pillEmphasized.tintOpacity > pill.tintOpacity)
        #expect(standaloneEmphasized.backdropOpacity >= standalone.backdropOpacity)
        #expect(standaloneEmphasized.tintOpacity > standalone.tintOpacity)
        #expect(elevatedEmphasized.backdropOpacity >= elevated.backdropOpacity)
        #expect(elevatedEmphasized.tintOpacity > elevated.tintOpacity)
    }
}
