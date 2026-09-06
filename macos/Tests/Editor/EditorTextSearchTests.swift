import AppKit
import Foundation
import Testing
import CodeEditTextView
import CodeEditSourceEditor
import CodeEditLanguages
@testable import Ghostty

struct EditorTextSearchTests {
    @Test func searchUsesUTF16RangesAndCaseOption() {
        let text = "😀Foo foo"
        #expect(EditorTextSearch.matches(in: text, query: "foo", caseSensitive: true) == [
            NSRange(location: 6, length: 3),
        ])
        #expect(EditorTextSearch.matches(in: text, query: "foo", caseSensitive: false) == [
            NSRange(location: 2, length: 3),
            NSRange(location: 6, length: 3),
        ])
    }

    @Test func emptyQueryHasNoMatches() {
        #expect(EditorTextSearch.matches(in: "text", query: "", caseSensitive: false).isEmpty)
    }

    @Test func replaceAllOrdersUTF16RangesFromEnd() {
        let matches = EditorTextSearch.matches(in: "😀 a a", query: "a", caseSensitive: true)
        #expect(EditorTextSearch.rangesForReplacement(matches) == [
            NSRange(location: 5, length: 1),
            NSRange(location: 3, length: 1),
        ])
    }

    @Test func lineJumpUsesLFAndUTF16Columns() {
        let text = "one\n😀two\nthree"
        #expect(EditorTextSearch.range(forLine: 2, column: 3, in: text) == NSRange(location: 6, length: 0))
        #expect(EditorTextSearch.range(forLine: 2, column: 2, in: text) == NSRange(location: 4, length: 0))
        #expect(EditorTextSearch.range(forLine: 2, column: 99, in: text) == NSRange(location: 9, length: 0))
        #expect(EditorTextSearch.range(forLine: 4, column: 1, in: text) == nil)
        #expect(EditorTextSearch.lineAndColumn(from: "2:3")?.line == 2)
        #expect(EditorTextSearch.lineAndColumn(from: "2:3")?.column == 3)
        #expect(EditorTextSearch.lineAndColumn(from: "") == nil)
        #expect(EditorTextSearch.lineAndColumn(from: "2:0") == nil)
    }

    @Test func nextAndPreviousMatchesWrap() {
        let matches = [NSRange(location: 1, length: 2), NSRange(location: 5, length: 2)]
        #expect(EditorTextSearch.matchIndex(
            in: matches, selection: matches[1], searchingForward: true
        ) == 0)
        #expect(EditorTextSearch.matchIndex(
            in: matches, selection: matches[0], searchingForward: false
        ) == 1)
    }

    @Test func selectedLineRangeIncludesWholeTouchedLines() {
        let text = "one\ntwo\nthree"
        #expect(EditorTextSearch.lineRange(
            containing: NSRange(location: 5, length: 0), in: text
        ) == NSRange(location: 4, length: 4))
        #expect(EditorTextSearch.lineRange(
            containing: NSRange(location: 5, length: 5), in: text
        ) == NSRange(location: 4, length: 9))
    }

    @Test @MainActor func nativeSelectionCopyCutPasteAndUndoUseTheEditorTextView() {
        let textView = TextView(string: "alpha beta")
        #expect(EditorNativeTextActions.select(NSRange(location: 0, length: 5), on: textView))
        #expect(textView.selectionManager.textSelections.first?.range == NSRange(location: 0, length: 5))

        #expect(EditorNativeTextActions.perform(.copy, on: textView))
        #expect(NSPasteboard.general.string(forType: .string) == "alpha")
        #expect(EditorNativeTextActions.perform(.cut, on: textView))
        #expect(textView.string == " beta")
        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "alpha beta")

        textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 4))
        #expect(EditorNativeTextActions.perform(.paste, on: textView))
        #expect(textView.string == "alpha alpha")
    }

    @Test @MainActor func nativeLineActionsUpdateTextSelectionAndUndoStack() {
        let textView = TextView(string: "one\ntwo\nthree")
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))

        #expect(EditorNativeTextActions.perform(.duplicateLine, on: textView))
        #expect(textView.string == "one\ntwo\ntwo\nthree")
        #expect(textView.selectionManager.textSelections.first?.range.location == 9)
        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "one\ntwo\nthree")

        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorNativeTextActions.perform(.deleteLine, on: textView))
        #expect(textView.string == "one\nthree")
        #expect(textView.selectionManager.textSelections.first?.range == NSRange(location: 4, length: 0))

        #expect(EditorNativeTextActions.perform(.undo, on: textView))
        #expect(textView.string == "one\ntwo\nthree")

        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorNativeTextActions.perform(.moveLineUp, on: textView))
        #expect(textView.string == "two\none\nthree")
        #expect(EditorNativeTextActions.perform(.moveLineDown, on: textView))
        #expect(textView.string == "one\ntwo\nthree")

        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorNativeTextActions.perform(.copy, on: textView))
        #expect(NSPasteboard.general.string(forType: .string) == "two\n")
    }

    @Test @MainActor func commandRouterKeepsMultipleWeakOwnersIndependent() throws {
        final class Owner {}
        let first = Owner()
        let second = Owner()
        let router = EditorCommandRouter()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ))
        var calls: [String] = []
        router.register(owner: first) { _ in
            calls.append("first")
            return false
        }
        router.register(owner: second) { _ in
            calls.append("second")
            return true
        }

        #expect(router.handle(event))
        #expect(calls == ["first", "second"])
        calls.removeAll()
        router.unregister(owner: second)
        #expect(!router.handle(event))
        #expect(calls == ["first"])
    }

    @Test @MainActor func replaceAllIsOneNativeUndoAndRedoOperation() {
        let textView = TextView(string: "a a")
        textView.replaceCharacters(in: NSRange(location: 3, length: 0), with: "!")
        let ranges = EditorTextSearch.matches(in: textView.string, query: "a", caseSensitive: true)

        #expect(EditorTextEditing.replace(on: textView, ranges: ranges, with: "long"))
        #expect(textView.string == "long long!")
        textView.undoManager?.undo()
        #expect(textView.string == "a a!")
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.redo()
        #expect(textView.string == "long long!")
    }

    @Test @MainActor func replacementDoesNotEditReadOnlyTextView() {
        let textView = TextView(string: "a a", isEditable: false)
        let ranges = EditorTextSearch.matches(in: textView.string, query: "a", caseSensitive: true)

        #expect(!EditorTextEditing.replace(on: textView, ranges: ranges, with: "b"))
        #expect(textView.string == "a a")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test @MainActor func markdownHighlightProviderRecognizesHeadingsCodeAndLinks() async throws {
        let text = "# Title\n\n> quote\n\n```swift\nlet x = 1\n```\n\n[link](https://example.com)"
        let textView = TextView(string: text)
        let provider = MarkdownHighlightProvider()
        provider.setUp(textView: textView, codeLanguage: .markdown)

        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: (text as NSString).length)) { result in
                continuation.resume(with: result)
            }
        }

        #expect(!highlights.isEmpty)
        #expect(highlights.contains { $0.capture == .keyword })
        #expect(highlights.contains { $0.capture == .comment })
        #expect(highlights.contains { $0.capture == .string })
    }
}
