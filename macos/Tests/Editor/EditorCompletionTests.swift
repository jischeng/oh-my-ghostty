import AppKit
import Combine
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
import SwiftUI
import Foundation
import Testing
@testable import Ghostty

struct EditorCompletionTests {
    @Test @MainActor func dismissingInactiveCompletionDoesNotPublishUpdates() {
        let state = CompletionState()
        var updates = 0
        let subscription = state.objectWillChange.sink { updates += 1 }
        for _ in 0..<100 { state.dismiss() }
        #expect(updates == 0)
        state.update(candidates: [CompletionItem(label: "hello")], prefix: "he",
                     prefixRange: NSRange(location: 0, length: 2), at: .zero)
        state.dismiss()
        let settledUpdates = updates
        for _ in 0..<100 { state.dismiss() }
        #expect(updates == settledUpdates)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func xmlMarkupProducesNativeHighlights() async throws {
        let text = "<?xml version=\"1.0\"?><root name=\"value\"><child>text</child><!-- note --></root>"
        let textView = TextView(string: text)
        let provider = TreeSitterClient()
        provider.setUp(textView: textView, codeLanguage: .html)
        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: text.utf16.count)) {
                continuation.resume(with: $0)
            }
        }
        #expect(!highlights.isEmpty)
        #expect(highlights.contains { $0.capture == .string })
        #expect(highlights.contains { $0.capture == .comment })
    }

    @Test @MainActor func xmlFamilyFilesUseMarkupGrammar() {
        for name in ["pom.xml", "IMAGE.SVG", "Info.plist", "schema.xsd", "App.storyboard"] {
            let coordinator = EditorCoordinator()
            let language = coordinator.language(fileURL: URL(fileURLWithPath: "/tmp/" + name),
                                                text: "<?xml version=\"1.0\"?><root key=\"value\"/>")
            #expect(language.id == .html)
        }
    }

    @Test func bufferWordProviderExtractsMatchingPrefixes() async {
        let text = """
        function calculateTotal(items) {
            let calculator = new Calculator();
            let calculationResult = calculator.run();
            return calculationResult;
        }
        """
        let context = CompletionContext(
            documentText: text,
            cursorOffset: 50,
            prefix: "calc",
            lineText: "let calc",
            language: "javascript",
            fileURL: nil
        )
        let provider = BufferWordCompletionProvider()
        let items = await provider.provideCompletions(context: context)

        #expect(!items.isEmpty)
        let labels = items.map(\.label)
        #expect(labels.contains("calculateTotal"))
        #expect(labels.contains("calculator"))
        #expect(labels.contains("calculationResult"))
    }

    @Test func languageKeywordProviderSuppliesSwiftKeywords() async {
        let context = CompletionContext(
            documentText: "gu",
            cursorOffset: 2,
            prefix: "gu",
            lineText: "gu",
            language: "swift",
            fileURL: nil
        )
        let provider = LanguageKeywordCompletionProvider()
        let items = await provider.provideCompletions(context: context)

        let labels = items.map(\.label)
        #expect(labels.contains("guard"))
    }

    @Test func languageKeywordProviderSuppliesPythonKeywords() async {
        let context = CompletionContext(
            documentText: "im",
            cursorOffset: 2,
            prefix: "im",
            lineText: "im",
            language: "python",
            fileURL: nil
        )
        let provider = LanguageKeywordCompletionProvider()
        let items = await provider.provideCompletions(context: context)

        let labels = items.map(\.label)
        #expect(labels.contains("import"))
    }

    @Test @MainActor func completionEngineMergesAndRanksProviders() async {
        let engine = EditorCompletionEngine()
        let text = """
        guard let customGuard = guardValue else { return }
        """
        let context = CompletionContext(
            documentText: text,
            cursorOffset: 10,
            prefix: "gu",
            lineText: "gu",
            language: "swift",
            fileURL: nil
        )
        let completions = await engine.completions(for: context)

        #expect(!completions.isEmpty)
        #expect(completions.count <= 15)
        let labels = completions.map(\.label)
        #expect(labels.contains("guard"))
    }

    @Test @MainActor func customProviderRegistrationLifecycle() async {
        struct MockProvider: CompletionProvider {
            let id = "test.mock"
            let name = "Mock Source"
            let priority = 999

            func provideCompletions(context: CompletionContext) async -> [CompletionItem] {
                [CompletionItem(label: "mockSpecialCandidate", kind: .snippet, detail: "mock", score: 999)]
            }
        }

        let engine = EditorCompletionEngine()
        engine.register(provider: MockProvider())

        let context = CompletionContext(
            documentText: "",
            cursorOffset: 0,
            prefix: "mo",
            lineText: "mo",
            language: "swift",
            fileURL: nil
        )
        let items = await engine.completions(for: context)
        #expect(items.contains(where: { $0.label == "mockSpecialCandidate" }))

        engine.unregister(providerID: "test.mock")
        let afterItems = await engine.completions(for: context)
        #expect(!afterItems.contains(where: { $0.label == "mockSpecialCandidate" }))
    }

    @Test func keywordLookupDoesNotConfuseCWithOtherLanguages() async {
        let provider = LanguageKeywordCompletionProvider()
        for (language, prefix, expected) in [
            ("javascript", "fun", "function"), ("cpp", "cla", "class"),
            ("tsx", "rea", "readonly"), ("c", "uns", "unsigned")
        ] {
            let items = await provider.provideCompletions(context: context(prefix, language: language))
            #expect(items.contains { $0.label == expected })
        }
        for language in ["markdown", "yaml", "unknown"] {
            #expect(await provider.provideCompletions(context: context("gu", language: language)).isEmpty)
        }
    }

    @Test func bufferRankingUsesNearestOccurrence() async throws {
        let text = "calculate " + String(repeating: " ", count: 1000) + "calculate cal"
        let items = await BufferWordCompletionProvider().provideCompletions(context: CompletionContext(
            documentText: text, cursorOffset: text.utf16.count, prefix: "cal", lineText: text,
            language: nil, fileURL: nil
        ))
        let item = try #require(items.first { $0.label == "calculate" })
        #expect(item.score > 110)
    }

    @Test @MainActor func filteringRemovesStaleSuggestionsAndPreservesSelectedCandidate() {
        let state = CompletionState()
        state.update(candidates: [CompletionItem(label: "alpha"), CompletionItem(label: "beta")],
                     prefix: "", prefixRange: NSRange(location: 0, length: 0), at: .zero)
        state.selectNext()
        state.filter(prefix: "bet", prefixRange: NSRange(location: 0, length: 3), at: .zero)
        #expect(state.currentSelection?.label == "beta")
        state.filter(prefix: "zzz", prefixRange: NSRange(location: 0, length: 3), at: .zero)
        #expect(state.candidates.isEmpty)
        #expect(!state.isPresented)
        #expect(state.currentSelection == nil)
    }

    @Test @MainActor func equalScoreCompletionsHaveStableOrder() async {
        struct Provider: CompletionProvider {
            let id = "test.ties"
            let name = "Ties"
            let priority = 1000
            func provideCompletions(context: CompletionContext) async -> [CompletionItem] {
                [CompletionItem(label: "zulu"), CompletionItem(label: "alpha")]
            }
        }
        let engine = EditorCompletionEngine()
        engine.unregister(providerID: "builtin.buffer")
        engine.unregister(providerID: "builtin.keywords")
        engine.register(provider: Provider())
        #expect(await engine.completions(for: context("a")).map(\.label) == ["alpha", "zulu"])
    }

    @Test @MainActor func nativeTypingKeepsCompletionPrefixAndMultiCaretUndoTogether() async throws {
        let coordinator = EditorCoordinator()
        let capture = CompletionTestCapture()
        let state = CompletionState()
        coordinator.setCompletionState(state)
        _ = coordinator.language(fileURL: URL(fileURLWithPath: "/test.py"), text: "")
        let view = CodeEditSourceEditor(
            .constant(""), language: .python, theme: .oneDark,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
            lineHeight: 1.2, wrapLines: false, cursorPositions: .constant([]),
            highlightProviders: [], coordinators: [coordinator, capture]
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        defer { coordinator.destroy(); window.close() }
        let controller = try #require(capture.controller)
        let textView = try #require(controller.textView)
        coordinator.setActive(true)
        coordinator.select(NSRange(location: 0, length: 0))
        for character in "from" {
            textView.insertText(String(character))
            try await Task.sleep(for: .milliseconds(60))
            #expect(state.prefix == textView.string)
            #expect(state.candidates.contains { $0.label == "from" })
            #expect(state.candidates.allSatisfy { $0.label.lowercased().hasPrefix(textView.string.lowercased()) })
        }
        textView.insertText(" ")
        try await Task.sleep(for: .milliseconds(60))
        #expect(!state.isPresented)

        textView.setText("a\nb")
        textView._undoManager?.clearStack()
        textView.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        textView.insertText("x")
        #expect(textView.string == "ax\nbx")
        textView.insertText("y")
        #expect(textView.string == "axy\nbxy")
        textView.undoManager?.undo()
        #expect(textView.string == "ax\nbx")
        textView.undoManager?.undo()
        #expect(textView.string == "a\nb")
        textView.undoManager?.redo()
        #expect(textView.string == "ax\nbx")
        #expect(textView.selectionManager.textSelections.count == 2)
        textView.setText("a\nb")
        textView._undoManager?.clearStack()
        textView.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        textView.insertText("(")
        #expect(textView.string == "a(\nb(")
        textView.undoManager?.undo()
        #expect(textView.string == "a\nb")
        textView.undoManager?.redo()
        #expect(textView.string == "a(\nb(")
    }

    @Test @MainActor func nativeCompletionCancelsStaleWorkAndRespectsFocus() async throws {
        let coordinator = EditorCoordinator()
        let capture = CompletionTestCapture()
        let state = CompletionState()
        coordinator.setCompletionState(state)
        _ = coordinator.language(fileURL: URL(fileURLWithPath: "/test.swift"), text: "gu")
        let view = CodeEditSourceEditor(
            .constant("gu"), language: .swift, theme: .oneDark,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), tabWidth: 4,
            lineHeight: 1.2, wrapLines: false, cursorPositions: .constant([]),
            highlightProviders: [], coordinators: [coordinator, capture]
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        defer {
            coordinator.destroy()
            window.close()
        }
        let controller = try #require(capture.controller)
        let textView = try #require(controller.textView)
        let scrollView = try #require(textView.enclosingScrollView)
        #expect(scrollView.backgroundColor == .clear)
        coordinator.setActive(true)
        window.makeFirstResponder(textView)
        coordinator.select(NSRange(location: 2, length: 0))
        coordinator.textViewDidChangeText(controller: controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.candidates.contains { $0.label == "guard" })

        // Starting work and then inserting whitespace must not resurrect the old popup.
        coordinator.textViewDidChangeText(controller: controller)
        textView.replaceCharacters(in: NSRange(location: 2, length: 0), with: " ")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!state.isPresented)

        textView.replaceCharacters(in: NSRange(location: 2, length: 1), with: "")
        coordinator.select(NSRange(location: 2, length: 0))
        coordinator.textViewDidChangeText(controller: controller)
        coordinator.select(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!state.isPresented)

        coordinator.select(NSRange(location: 2, length: 0))
        coordinator.textViewDidChangeText(controller: controller)
        _ = EditorCommandRouter.shared.handle(try keyEvent(53, window: window))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!state.isPresented)

        state.update(candidates: [CompletionItem(label: "guard")], prefix: "gu",
                     prefixRange: NSRange(location: 0, length: 2), at: .zero)
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true
        host.view.addSubview(fieldEditor)
        window.makeFirstResponder(fieldEditor)
        #expect(!EditorCommandRouter.shared.handle(try keyEvent(36, window: window)))
        #expect(textView.string == "gu")
        #expect(!state.isPresented)

        window.makeFirstResponder(textView)
        state.update(candidates: [CompletionItem(label: "guard")], prefix: "gu",
                     prefixRange: NSRange(location: 0, length: 2), at: .zero)
        #expect(!EditorCommandRouter.shared.handle(try keyEvent(36, window: window, modifiers: .command)))
        #expect(textView.string == "gu")
        coordinator.commit(completion: CompletionItem(label: "guard"))
        #expect(textView.string == "guard")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!state.isPresented)
        textView.undoManager?.undo()
        #expect(textView.string == "gu")

        state.update(candidates: [CompletionItem(label: "guard")], prefix: "stale",
                     prefixRange: NSRange(location: 0, length: 2), at: .zero)
        coordinator.commit(completion: CompletionItem(label: "guard"))
        #expect(textView.string == "gu")

        textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())
        let markedText = textView.string
        state.update(candidates: [CompletionItem(label: "guard")], prefix: "gu",
                     prefixRange: NSRange(location: 0, length: 2), at: .zero)
        #expect(!EditorCommandRouter.shared.handle(try keyEvent(36, window: window)))
        #expect(textView.string == markedText)
        #expect(textView.hasMarkedText())
        #expect(!state.isPresented)
        textView.unmarkText()
        coordinator.setActive(false)
    }

    private func context(_ prefix: String, language: String? = nil) -> CompletionContext {
        CompletionContext(documentText: prefix, cursorOffset: prefix.utf16.count,
                          prefix: prefix, lineText: prefix, language: language, fileURL: nil)
    }

    @MainActor private func keyEvent(
        _ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @Test func themeDefinitionDecodesJSONAndProducesTheme() throws {
        let json = """
        {
            "name": "Tokyo Night",
            "isDark": true,
            "text": "#a9b1d6",
            "keywords": "#bb9af7",
            "commands": "#7aa2f7",
            "strings": "#9ece6a",
            "comments": "#565f89"
        }
        """
        let data = Data(json.utf8)
        let def = try JSONDecoder().decode(EditorThemeDefinition.self, from: data)
        #expect(def.name == "Tokyo Night")
        let theme = def.toEditorTheme()
        #expect(theme.background == .clear)
    }
}

@MainActor
private final class CompletionTestCapture: @preconcurrency TextViewCoordinator {
    weak var controller: TextViewController?
    func prepareCoordinator(controller: TextViewController) { self.controller = controller }
}
