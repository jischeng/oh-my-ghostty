import AppKit
import CodeEditTextView
import Testing
@testable import Ghostty

@MainActor
struct EditorPairedInputTests {
    @Test func pairsInsertImmediatelyAndPlaceCaretInside() {
        for (opening, closing) in [("\"", "\""), ("'", "'"), ("(", ")"), ("[", "]"), ("{", "}")] {
            let view = TextView(string: "")
            view.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(EditorPairedInput.apply(opening, enabled: true, on: view))
            #expect(view.string == opening + closing)
            #expect(view.selectionManager.textSelections.first?.range.location == 1)
            #expect(EditorPairedInput.apply(closing, enabled: true, on: view))
            #expect(view.string == opening + closing)
            #expect(view.selectionManager.textSelections.first?.range.location == 2)
            view.undoManager?.undo()
            #expect(view.string.isEmpty)
            view.undoManager?.redo()
            #expect(view.string == opening + closing)
        }
    }

    @Test func disabledPairsInsertOnlyTypedCharacter() {
        let view = TextView(string: "")
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(EditorPairedInput.apply("(", enabled: false, on: view))
        #expect(view.string == "(")
        #expect(view.selectionManager.textSelections.first?.range.location == 1)
    }

    @Test func multiCaretPairsAndBackspaceAreSingleUndoOperations() {
        let view = TextView(string: "a\nb")
        view.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        #expect(EditorPairedInput.apply("(", enabled: true, on: view))
        #expect(view.string == "a()\nb()")
        #expect(view.selectionManager.textSelections.map(\.range.location).sorted() == [2, 6])
        #expect(EditorPairedInput.apply("", backspace: true, enabled: true, on: view))
        #expect(view.string == "a\nb")
        view.undoManager?.undo()
        #expect(view.string == "a()\nb()")
        view.undoManager?.undo()
        #expect(view.string == "a\nb")
    }

    @Test func selectionIsWrappedAndApostropheInWordIsLiteral() {
        let view = TextView(string: "hello")
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(EditorPairedInput.apply("\"", enabled: true, on: view))
        #expect(view.string == "\"hello\"")
        view.undoManager?.undo()
        #expect(view.string == "hello")
        view.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(EditorPairedInput.apply("'", enabled: true, on: view))
        #expect(view.string == "hello'")
    }
}
