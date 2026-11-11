import XCTest
import UIKit

final class OMGMobileUITests: XCTestCase {
    private var info: Bundle { Bundle(for: Self.self) }
    private var usingVM: Bool { info.object(forInfoDictionaryKey: "OMGTestVM") as? String == "YES" }
    private var sessionID: String {
        info.object(forInfoDictionaryKey: "OMGTestSession") as? String
            ?? "77777777-1111-2222-3333-444444444444"
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let server = info.object(forInfoDictionaryKey: "OMGTestServer") as? String ?? "127.0.0.1:18790"
        app.launchArguments = ["--ui-test-server", server, "--ui-test-token", String(repeating: "t", count: 64),
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3),
           alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "OMG Mobile")).firstMatch.exists {
            for title in ["Allow", "允许", "OK", "好"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                break
            }
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openProject(_ app: XCUIApplication) {
        if row(app).exists && row(app).isHittable { return }
        let path = info.object(forInfoDictionaryKey: "OMGTestProject") as? String ?? ""
        let project = path.isEmpty
            ? app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "project.")).firstMatch
            : element(app, "project.\(path)")
        XCTAssertTrue(project.waitForExistence(timeout: 30), "The real omgd roster must populate the upstream project list.")
        project.tap()
    }

    private func row(_ app: XCUIApplication) -> XCUIElement { element(app, "session.\(sessionID)") }

    private func assertRow(_ app: XCUIApplication, agent: String, state: String) {
        expectation(for: NSPredicate(format: "label CONTAINS %@ AND value == %@", agent, state),
                    evaluatedWith: row(app))
        waitForExpectations(timeout: 10)
    }

    private func waitConnected(_ app: XCUIApplication) {
        expectation(for: NSPredicate(format: "value == %@", "Connected"),
                    evaluatedWith: app.staticTexts["terminal.title"])
        waitForExpectations(timeout: 15)
        for label in ["Continue", "继续"] where app.buttons[label].exists { app.buttons[label].tap() }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func openSessionTerminal(_ app: XCUIApplication) {
        row(app).tap()
        waitConnected(app)
        capture(app, "Agent TUI reflowed to the phone viewport")
    }

    func testAttachTakeoverTypeAndMacReclaim() {
        var app = launch()
        XCTAssertTrue(app.buttons["home.tab.projects"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["home.tab.chats"].label, "Agent")
        capture(app, "Upstream Termio home connected to omgd")
        openProject(app)
        XCTAssertTrue(row(app).waitForExistence(timeout: 15))
        if usingVM { assertRow(app, agent: "Codex", state: "Working") }
        openSessionTerminal(app)
        XCTAssertTrue(app.buttons["tab"].waitForExistence(timeout: 5))
        let marker = "\\115\\117\\102\\111\\114\\105\\137\\125\\111\\137\\105\\130\\105\\103\\125\\124\\105\\104"
        let status = usingVM ? "\\033]7501;state=blocked:app=claude:id=mobile-agent-fixture:kind=permission\\007" : ""
        app.typeText("printf '\(marker) pid=%s\\n\(status)' \"$$\"\n")
        if usingVM {
            app.buttons["terminal.back"].tap()
            assertRow(app, agent: "Claude Code", state: "Needs You")
            if app.buttons["project.back"].exists { app.buttons["project.back"].tap() }
            XCTAssertTrue(app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Needs You")).firstMatch.waitForExistence(timeout: 10))
            capture(app, "Upstream Needs You populated by the omgd holder facts")
            openSessionTerminal(app)
            app.typeText("printf '\\115\\117\\102\\111\\114\\105\\137\\122\\105\\101\\104\\131\\137\\106\\117\\122\\137\\115\\101\\103\\n'\n")
        }
        expectation(for: NSPredicate(format: "value == %@", "Read Only"),
                    evaluatedWith: app.staticTexts["terminal.title"])
        waitForExpectations(timeout: 15)
        let screenshot = app.screenshot()
        let viewport = element(app, "terminal.viewport").frame
        let scale = CGFloat(screenshot.image.cgImage?.width ?? 0) / app.frame.width
        let rect = CGRect(x: viewport.minX * scale, y: viewport.minY * scale,
                          width: viewport.width * scale, height: viewport.height * scale)
        let terminalImage = screenshot.image.cgImage?.cropping(to: rect)
        if let terminalImage {
            let attachment = XCTAttachment(image: UIImage(cgImage: terminalImage))
            attachment.name = "Shared terminal viewport"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(terminalImage.map { hasVisibleText(UIImage(cgImage: $0)) } == true,
                      "The native shared VT must remain visible.")
        capture(app, "Upstream terminal after mobile input and real Mac reclaim")
        if usingVM {
            app.buttons["terminal.back"].tap()
            app.buttons["home.tab.projects"].tap()
            openProject(app)
            assertRow(app, agent: "Pi", state: "Done")
            app.terminate()
            app = launch()
            openProject(app)
            assertRow(app, agent: "Pi", state: "Done")
            openSessionTerminal(app)
            app.buttons["terminal.back"].tap()
            assertRow(app, agent: "Pi", state: "Idle")
            openSessionTerminal(app)
            let reconnect = "\\115\\117\\102\\111\\114\\105\\137\\122\\105\\103\\117\\116\\116\\105\\103\\124\\105\\104"
            app.typeText("printf '\(reconnect) pid=%s\\n\\033]7501;state=working:app=antigravity:id=mobile-agent-fixture\\007' \"$$\"\n")
            app.buttons["terminal.back"].tap()
            assertRow(app, agent: "Antigravity", state: "Working")
            capture(app, "Upstream project sessions after restoring and updating agent state")
        }
    }

    func testUpstreamPanelsReadDiffEditFilesAndSettings() throws {
        guard usingVM else { throw XCTSkip("The file/edit fixture is provided by the VM runner.") }
        let app = launch()
        openProject(app)
        openSessionTerminal(app)
        let viewport = element(app, "terminal.viewport")
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.35))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: end)
        let changes = app.segmentedControls.buttons["Changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: changes)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["README.md"].waitForExistence(timeout: 10))
        capture(app, "Upstream changes drawer backed by real git status")
        app.staticTexts["README.md"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "shared session"),
                    evaluatedWith: app.textViews.firstMatch)
        waitForExpectations(timeout: 10)
        capture(app, "Upstream diff reader backed by real git diff")
        app.buttons["diff.close"].tap()
        app.segmentedControls.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["README.md"].waitForExistence(timeout: 10))
        app.staticTexts["README.md"].tap()
        let contents = element(app, "file.contents")
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        XCTAssertTrue((contents.value as? String)?.contains("shared session") == true)
        app.buttons["file.edit"].tap()
        contents.tap()
        contents.typeText("\nmobile-editor-proof\n")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "saved"),
                    evaluatedWith: app.staticTexts["file.state"])
        waitForExpectations(timeout: 10)
        capture(app, "Upstream file editor after a real versioned save")
        app.buttons["file.close"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.4)).tap()
        app.buttons["terminal.back"].tap()
        if app.buttons["project.back"].exists { app.buttons["project.back"].tap() }
        XCTAssertTrue(app.buttons["projects.add"].exists)
        XCTAssertTrue(app.buttons["home.workspaceRail"].exists)
        app.buttons["projects.add"].tap()
        XCTAssertTrue(app.navigationBars["Add Project"].waitForExistence(timeout: 10))
        capture(app, "Add Project starts from the paired desktop")
        app.navigationBars["Add Project"].buttons.element(boundBy: 0).tap()
        app.buttons["home.workspaceRail"].tap()
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 5))
        capture(app, "Workspace picker mirrors the desktop catalog")
        app.navigationBars["Workspaces"].buttons.element(boundBy: 0).tap()
        for id in ["home.tab.chats", "home.tab.terminals", "home.tab.settings", "home.tab.projects"] {
            XCTAssertTrue(app.buttons[id].exists)
            app.buttons[id].tap()
        }
        app.buttons["home.tab.settings"].tap()
        let acknowledgements = app.staticTexts["Acknowledgements"]
        XCTAssertTrue(acknowledgements.waitForExistence(timeout: 10))
        acknowledgements.tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5))
        capture(app, "Open source acknowledgements")
        app.navigationBars["Acknowledgements"].buttons.element(boundBy: 0).tap()
        capture(app, "Upstream settings and device connection")
    }

    func testUpstreamTerminalCreationAndExplicitClose() throws {
        guard usingVM else { throw XCTSkip("The VM records created-session execution and close receipts.") }
        let app = launch()
        XCTAssertTrue(app.buttons["home.tab.terminals"].waitForExistence(timeout: 15))
        app.buttons["home.tab.terminals"].tap()
        let add = app.buttons["terminals.new"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let create = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
            "New Terminal", "terminals.new")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        waitConnected(app)
        let container = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "terminal.session.")).firstMatch
        let route = String(container.identifier.dropFirst("terminal.session.".count))
        let parts = route.split(separator: "/")
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3 else { return }
        let createdID = String(parts[1])
        XCTAssertNotEqual(createdID, sessionID)
        let directory = info.object(forInfoDictionaryKey: "OMGTestDirectory") as? String ?? ""
        XCTAssertTrue(directory.hasPrefix("/tmp/omg-mobile-vm-"))
        app.typeText("printf '%s' \"$$\" > \(directory)/new-terminal.pid\n")
        capture(app, "Upstream new terminal created through omgd")
        app.buttons["terminal.back"].tap()
        let created = element(app, "session.\(createdID)")
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        created.swipeLeft()
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(created.waitForNonExistence(timeout: 15))
    }

    private func hasVisibleText(_ image: UIImage) -> Bool {
        guard let image = image.cgImage else { return false }
        let size = 256
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            var dark = 0, bright = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let sum = Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
                // Downsampled small glyphs retain gray edges rather than pure black.
                if sum < 400 { dark += 1 }
                if sum > 600 { bright += 1 }
            }
            return dark > 16 && bright > 16
        }
    }
}
