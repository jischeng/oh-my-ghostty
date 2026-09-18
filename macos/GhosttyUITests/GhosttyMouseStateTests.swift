//
//  GhosttyMouseStateTests.swift
//  Ghostty
//
//  Created by Lukas on 19.03.2026.
//

import XCTest

final class GhosttyMouseStateTests: GhosttyCustomConfigCase {
    // https://github.com/ghostty-org/ghostty/pull/11276
    @MainActor func testSelectionFocusChange() async throws {
        let app = XCUIApplication()
        app.activate()
        // Write dummy text to a temp file, cat it into the terminal, then clean up
        let lines = (1...200).map { "Line \($0): The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet, consectetur adipiscing elit." }
        let text = lines.joined(separator: "\n") + "\n"
        let tmpFile = NSTemporaryDirectory() + "ghostty_test_dummy.txt"
        try text.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        app.typeText("cat \(tmpFile)\r")
        app.menuItems["Command Palette"].firstMatch.click()

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()

        app.activate()

        app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Clear Screen'"))
            .firstMatch
            .click()
        let surface = app.groups["Terminal pane"]
        surface
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: 20, dy: 10))
            .click()

        surface
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: 20, dy: surface.frame.height * 0.5))
            .hover()

        NSPasteboard.general.clearContents()
        app.typeKey("c", modifierFlags: .command)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), nil, "Moving mouse shouldn't select any texts")
    }

    /// The search field is a real text editor, so it must support the standard
    /// editing keys that the text system handles directly.
    ///
    /// Option+Arrow and Option+Delete are deliberately not asserted here: XCUITest's
    /// injected Option-modified key events do not resolve the standard word-movement
    /// bindings in *any* application (the same injection fails in TextEdit), so they
    /// cannot be verified from an automated UI test.
    @MainActor func testSearchFieldEditingKeys() async throws {
        // The search field is seeded from the find pasteboard, which is shared
        // with previous runs.
        NSPasteboard(name: .find).clearContents()

        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")
        app.typeKey("f", modifierFlags: .command)

        let textfield = app.textFields.firstMatch
        XCTAssertTrue(textfield.waitForExistence(timeout: 5), "Search field should appear")

        // Plain arrows move by character.
        app.typeText("foo bar")
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        app.typeText("1")
        XCTAssertEqual(textfield.stringValue, "foo b1ar", "arrow keys move by character")

        // Horizontal scrolling instead of wrapping keeps it a single line.
        app.typeKey("a", modifierFlags: .command)
        app.typeText(String(repeating: "x", count: 120))
        XCTAssertEqual(textfield.stringValue?.count, 120)

        // Command+Left jumps to the start of the line.
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: .command)
        app.typeText("y")
        XCTAssertEqual(textfield.stringValue?.first, "y", "Command+Left moves to the line start")

        // Escape returns focus to the terminal, and a second Escape closes the bar.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(textfield.waitForNonExistence(timeout: 5), "Search field should disappear")
    }

    @MainActor func testSearchFocusState() async throws {
        let app = try ghosttyApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")
        app.typeKey("f", modifierFlags: .command)

        let textfield = app.textFields.firstMatch
        XCTAssertTrue(textfield.waitForExistence(timeout: 5), "Search field should appear")
        app.typeText("abc")
        XCTAssertEqual(textfield.stringValue, "abc")

        NSPasteboard.general.clearContents()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "abc")

        app.typeKey("x", modifierFlags: .command)
        XCTAssertEqual(textfield.stringValue, "")

        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(textfield.stringValue, "abc")

        app.typeText("d")
        XCTAssertEqual(textfield.stringValue, "abcd")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(textfield.stringValue, "abc")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(textfield.stringValue, "abcd")

        // resign
        app.typeKey(.escape, modifierFlags: [])

        // dismiss
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(textfield.waitForNonExistence(timeout: 5), "Search field should disappear")
    }
}

private extension XCUIElement {
    var stringValue: String? {
        (value as? String)
    }
}
