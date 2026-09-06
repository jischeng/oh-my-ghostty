import AppKit
import CodeEditSourceEditor
import Foundation
import Testing
@testable import Ghostty

struct EditorCompletionTests {
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
        let engine = EditorCompletionEngine.shared
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

        let engine = EditorCompletionEngine.shared
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
