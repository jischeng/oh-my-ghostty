import Foundation
import Testing
import CodeEditTextView
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
}
