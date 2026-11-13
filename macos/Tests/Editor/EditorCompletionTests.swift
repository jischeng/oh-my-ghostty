import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct EditorCompletionTests {
    @Test func incompleteSelfMemberFallsBackToFileWords() async {
        let source = "def __init__(self, w_router: QuantizedWeights, w_gate: QuantizedWeights):\n    self.w_r"
        let context = CompletionContext(
            documentText: source,
            cursorOffset: source.utf16.count,
            prefix: "w_r",
            lineText: "    self.w_r",
            language: "python",
            fileURL: nil
        )
        #expect(await BufferWordCompletionProvider().provideCompletions(context: context).map(\.label) == ["w_router"])
        let dotSource = String(source.dropLast(3))
        let dot = CompletionContext(
            documentText: dotSource,
            cursorOffset: dotSource.utf16.count,
            prefix: "",
            lineText: "    self.",
            language: "python",
            fileURL: nil
        )
        #expect(await BufferWordCompletionProvider().provideCompletions(context: dot).contains { $0.label == "w_router" })
    }

    @Test func dotCompletionUsesOnlyMembersOfTheReceiver() async {
        let source = "self.key\nself.value\nother.unrelated\nself."
        let dot = CompletionContext(
            documentText: source,
            cursorOffset: source.utf16.count,
            prefix: "",
            lineText: "self.",
            language: "python",
            fileURL: nil
        )
        let provider = BufferWordCompletionProvider()
        #expect(await provider.provideCompletions(context: dot).map(\.label) == ["key", "value"])
        let typed = source + "va"
        let member = CompletionContext(
            documentText: typed,
            cursorOffset: typed.utf16.count,
            prefix: "va",
            lineText: "self.va",
            language: "python",
            fileURL: nil
        )
        #expect(await provider.provideCompletions(context: member).map(\.label) == ["value"])
        #expect(await LanguageKeywordCompletionProvider().provideCompletions(context: member).isEmpty)
        #expect(CompletionContext.memberReceiver(in: "3." as NSString, prefixStart: 2) == nil)
    }

    @Test func xmlFamilyFilesMapToXmlLanguageHint() {
        for name in ["pom.xml", "IMAGE.SVG", "Info.plist", "schema.xsd", "App.storyboard"] {
            let hint = EditorLanguageMapping.languageHint(
                forPath: "/tmp/" + name,
                textPrefix: "<?xml version=\"1.0\"?><root key=\"value\"/>"
            )
            #expect(hint == "xml")
        }
    }

    @Test func structuredLanguageUsesKnownSuffixesAndContentFallback() {
        struct Case {
            let path: String
            let text: String
            let expected: String
        }
        let cases = [
            Case(path: "/tmp/flake.lock", text: "{\n  \"nodes\": {}\n}\n", expected: "json"),
            Case(path: "/tmp/build.zig.zon.json", text: "{\n  \"name\": \"demo\"\n}\n", expected: "json"),
            Case(path: "/tmp/.prettierrc", text: "{\n  \"tabWidth\": 2\n}\n", expected: "json"),
            Case(path: "/tmp/.clang-format", text: "BasedOnStyle: LLVM\nIndentWidth: 2\n", expected: "yaml"),
            Case(path: "/tmp/pixi.lock", text: "package:\n  name: demo\n", expected: "yaml"),
            Case(path: "/tmp/lockfile.unknown", text: "{\n  \"nodes\": {}\n}\n", expected: "json"),
            Case(path: "/tmp/lockfile.unknown", text: "provider: openai\nmodel: gpt-6\n", expected: "yaml"),
            Case(path: "/tmp/no-extension", text: "[package]\nname = \"demo\"\n", expected: "toml"),
            Case(path: "/tmp/no-extension", text: "#!/usr/bin/env python3\nprint('hi')\n", expected: "python"),
            Case(path: "/tmp/no-extension", text: "<?xml version=\"1.0\"?><root/>", expected: "xml"),
            Case(path: "/tmp/Dockerfile.dev", text: "FROM alpine:3.20\n", expected: "dockerfile"),
            Case(path: "/tmp/GNUmakefile", text: "all:\n\techo ok\n", expected: "makefile"),
            Case(path: "/tmp/config.ghostty", text: "font-size = 13\n", expected: "ini")
        ]
        for testCase in cases {
            let actual = EditorLanguageMapping.languageHint(forPath: testCase.path, textPrefix: testCase.text)
            #expect(actual == testCase.expected, "\(testCase.path) got \(actual), expected \(testCase.expected)")
        }

        // Preserve a language already determined from a supported source file extension.
        #expect(
            EditorLanguageMapping.languageHint(
                forPath: "/tmp/Config.swift",
                textPrefix: "let config = [\"key\": \"value\"]"
            ) == "swift"
        )
        #expect(
            EditorLanguageMapping.languageHint(
                forPath: nil,
                textPrefix: "This is an ordinary sentence."
            ) == "plaintext"
        )
    }

    @Test func completionItemBridgeDictionaryMapsKindsAndSnippets() {
        let fn = CompletionItem(label: "calculate", kind: .function, detail: "() -> Int", score: 100)
        let fnDict = fn.bridgeDictionary
        #expect(fnDict["label"] as? String == "calculate")
        #expect(fnDict["monacoKind"] as? Int == 1)
        #expect(fnDict["detail"] as? String == "() -> Int")
        #expect(fnDict["isSnippet"] as? Bool == false)

        let snippet = CompletionItem(
            label: "guard let",
            insertText: "guard let ${1:val} else { return }",
            kind: .snippet
        )
        let snippetDict = snippet.bridgeDictionary
        #expect(snippetDict["monacoKind"] as? Int == 27)
        #expect(snippetDict["isSnippet"] as? Bool == true)
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

    @Test func bufferWordsIncludeShortAndDistantIdentifiers() async {
        let text = String(repeating: " ", count: 110_000) + "id = 1\nidx = id\ni"
        let items = await BufferWordCompletionProvider().provideCompletions(context: CompletionContext(
            documentText: text,
            cursorOffset: text.utf16.count,
            prefix: "i",
            lineText: "i",
            language: "python",
            fileURL: nil
        ))
        #expect(items.contains { $0.label == "id" })
        #expect(items.contains { $0.label == "idx" })
        #expect(!items.contains { $0.label == "i" })
    }

    @Test func languageKeywordProviderSuppliesSwiftAndPythonKeywords() async {
        let swiftContext = CompletionContext(
            documentText: "gu",
            cursorOffset: 2,
            prefix: "gu",
            lineText: "gu",
            language: "swift",
            fileURL: nil
        )
        let swiftItems = await LanguageKeywordCompletionProvider().provideCompletions(context: swiftContext)
        #expect(swiftItems.map(\.label).contains("guard"))

        let pyContext = CompletionContext(
            documentText: "im",
            cursorOffset: 2,
            prefix: "im",
            lineText: "im",
            language: "python",
            fileURL: nil
        )
        let pyItems = await LanguageKeywordCompletionProvider().provideCompletions(context: pyContext)
        #expect(pyItems.map(\.label).contains("import"))
    }

    @Test @MainActor func completionEngineMergesAndRanksProviders() async {
        let engine = EditorCompletionEngine()
        let text = "guard let customGuard = guardValue else { return }"
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
        #expect(completions.map(\.label).contains("guard"))
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
            ("javascript", "fun", "function"),
            ("cpp", "cla", "class"),
            ("tsx", "rea", "readonly"),
            ("c", "uns", "unsigned")
        ] {
            let items = await provider.provideCompletions(context: context(prefix, language: language))
            #expect(items.contains { $0.label == expected })
        }
        for language in ["markdown", "yaml", "unknown"] {
            #expect(await provider.provideCompletions(context: context("gu", language: language)).isEmpty)
        }
    }

    @Test func bufferRankingUsesNearestOccurrence() async throws {
        let text = "calculate " + String(repeating: " ", count: 1_000) + "calculate cal"
        let items = await BufferWordCompletionProvider().provideCompletions(context: CompletionContext(
            documentText: text,
            cursorOffset: text.utf16.count,
            prefix: "cal",
            lineText: text,
            language: nil,
            fileURL: nil
        ))
        let item = try #require(items.first { $0.label == "calculate" })
        #expect(item.score > 110)
    }

    @Test @MainActor func equalScoreCompletionsHaveStableOrder() async {
        struct Provider: CompletionProvider {
            let id = "test.ties"
            let name = "Ties"
            let priority = 1_000

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
        #expect(theme.background.alphaComponent == 0)
    }

    private func context(_ prefix: String, language: String? = nil) -> CompletionContext {
        CompletionContext(
            documentText: prefix,
            cursorOffset: prefix.utf16.count,
            prefix: prefix,
            lineText: prefix,
            language: language,
            fileURL: nil
        )
    }
}
