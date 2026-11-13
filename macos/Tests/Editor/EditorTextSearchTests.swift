import AppKit
import Foundation
import Testing
@testable import Ghostty

struct EditorTextSearchTests {
    @Test func searchUsesUTF16RangesAndCaseOption() {
        let text = "😀Foo foo"
        #expect(EditorTextSearch.matches(in: text, query: "foo", caseSensitive: true) == [
            NSRange(location: 6, length: 3)
        ])
        #expect(EditorTextSearch.matches(in: text, query: "foo", caseSensitive: false) == [
            NSRange(location: 2, length: 3),
            NSRange(location: 6, length: 3)
        ])
    }

    @Test func emptyQueryHasNoMatches() {
        #expect(EditorTextSearch.matches(in: "text", query: "", caseSensitive: false).isEmpty)
    }

    @Test func replaceAllOrdersUTF16RangesFromEnd() {
        let matches = EditorTextSearch.matches(in: "😀 a a", query: "a", caseSensitive: true)
        #expect(EditorTextSearch.rangesForReplacement(matches) == [
            NSRange(location: 5, length: 1),
            NSRange(location: 3, length: 1)
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
        #expect(EditorTextSearch.lineRange(
            containing: NSRange(location: 4, length: 0), in: "one\n"
        ) == NSRange(location: 4, length: 0))
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

    @Test func keymapProfilesMapQuickOpenDocumentSymbolsAndNavigation() {
        let idea = EditorKeymap.idea
        let vscode = EditorKeymap.vscode

        // Quick Open (`⌘P` and `⌘O`) and Go to Symbol (`⇧⌘O`) work in both profiles.
        #expect(idea.actions[EditorKeyStroke(key: "p", modifiers: .command)] == .open)
        #expect(idea.actions[EditorKeyStroke(key: "o", modifiers: .command)] == .open)
        #expect(idea.actions[EditorKeyStroke(key: "o", modifiers: [.command, .shift])] == .documentSymbols)
        #expect(vscode.actions[EditorKeyStroke(key: "p", modifiers: .command)] == .open)
        #expect(vscode.actions[EditorKeyStroke(key: "o", modifiers: .command)] == .open)
        #expect(vscode.actions[EditorKeyStroke(key: "o", modifiers: [.command, .shift])] == .documentSymbols)

        // Profile-specific bindings remain distinct.
        #expect(idea.actions[EditorKeyStroke(key: "l", modifiers: .command)] == .goToLine)
        #expect(vscode.actions[EditorKeyStroke(key: "g", modifiers: .control)] == .goToLine)
        #expect(idea.actions[EditorKeyStroke(key: "d", modifiers: .command)] == .duplicateLine)
        #expect(vscode.actions[EditorKeyStroke(key: "k", modifiers: [.command, .shift])] == .deleteLine)
    }
}
