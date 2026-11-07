import XCTest
import UIKit

final class OMGMobileUITests: XCTestCase {
    func testAttachTakeoverTypeAndMacReclaim() {
        // The isolated host fixture uses a public synthetic test token, never
        // a user's saved pairing key or existing terminal session.
        let app = XCUIApplication()
        let server = Bundle(for: Self.self).object(forInfoDictionaryKey: "OMGTestServer") as? String ?? "127.0.0.1:18790"
        let sessionID = Bundle(for: Self.self).object(forInfoDictionaryKey: "OMGTestSession") as? String
            ?? "77777777-1111-2222-3333-444444444444"
        let usingVM = Bundle(for: Self.self).object(forInfoDictionaryKey: "OMGTestVM") as? String == "YES"
        app.launchArguments = ["--ui-test-server", server,
                               "--ui-test-token", String(repeating: "t", count: 64)]
        app.launch()
        app.buttons["connection.connect"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3),
           alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "OMG Mobile")).firstMatch.exists {
            for title in ["允许", "Allow", "好", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                break
            }
        }
        let session = app.cells["session.\(sessionID)"]
        guard session.waitForExistence(timeout: 15) else {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.lifetime = .keepAlways
            add(image)
            XCTFail("The paired host did not provide the fixture session.")
            return
        }
        session.tap()
        let status = app.staticTexts["terminal.status"]
        let viewing = NSPredicate(format: "label CONTAINS %@", "正在查看")
        expectation(for: viewing, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        if usingVM { assertAgent(app, name: "Codex", state: "正在处理") }
        app.buttons["接管"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "正在操作"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        // A newly installed Simulator can show the system's QuickPath tutorial
        // over the keyboard. Complete it before checking the accessory bar.
        for title in ["Continue", "继续"] where app.buttons[title].exists {
            app.buttons[title].tap()
        }
        XCTAssertTrue(app.buttons["ctrl"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab"].exists)
        // The command contains octal escapes; only its actual execution emits
        // the marker the Mac fixture waits for, so echo cannot fake success.
        let mobileMarker = "\\115\\117\\102\\111\\114\\105\\137\\125\\111\\137\\105\\130\\105\\103\\125\\124\\105\\104"
        let claudeStatus = usingVM
            ? "\\033]7501;state=blocked:app=claude:id=mobile-agent-fixture:kind=permission\\007" : ""
        app.typeText("printf '\(mobileMarker) pid=%s\\n\(claudeStatus)' \"$$\"\n")
        if usingVM {
            assertAgent(app, name: "Claude Code", state: "等待授权")
            // Notify the guest only after the phone rendered the waiting state.
            app.typeText("printf '\\115\\117\\102\\111\\114\\105\\137\\122\\105\\101\\104\\131\\137\\106\\117\\122\\137\\115\\101\\103\\n'\n")
        }
        expectation(for: NSPredicate(format: "label CONTAINS %@", "输入权已交给"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        if usingVM { assertAgent(app, name: "Pi", state: "已完成") }
        let viewport = app.scrollViews["terminal.viewport"]
        XCTAssertGreaterThan(brightSamples(viewport.screenshot().image), 16,
            "The shared terminal must remain visible after keyboard changes and writer transfer.")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Shared terminal after mobile input and Mac reclaim"
        image.lifetime = .keepAlways
        add(image)
        if usingVM {
            app.terminate()
            app.launch()
            app.buttons["connection.connect"].tap()
            let reconnected = app.cells["session.\(sessionID)"]
            XCTAssertTrue(reconnected.waitForExistence(timeout: 15))
            reconnected.tap()
            expectation(for: viewing, evaluatedWith: app.staticTexts["terminal.status"])
            waitForExpectations(timeout: 10)
            assertAgent(app, name: "Pi", state: "已完成")
            app.buttons["接管"].tap()
            expectation(for: NSPredicate(format: "label CONTAINS %@", "正在操作"),
                        evaluatedWith: app.staticTexts["terminal.status"])
            waitForExpectations(timeout: 10)
            let reconnectMarker = "\\115\\117\\102\\111\\114\\105\\137\\122\\105\\103\\117\\116\\116\\105\\103\\124\\105\\104"
            let agyStatus = "\\033]7501;state=working:app=antigravity:id=mobile-agent-fixture\\007"
            app.typeText("printf '\(reconnectMarker) pid=%s\\n\(agyStatus)' \"$$\"\n")
            assertAgent(app, name: "Antigravity", state: "正在处理")
            let reconnectedImage = XCTAttachment(screenshot: app.screenshot())
            reconnectedImage.name = "Reattached to the same VM session"
            reconnectedImage.lifetime = .keepAlways
            add(reconnectedImage)
        }
    }

    private func assertAgent(_ app: XCUIApplication, name: String, state: String) {
        let activity = app.descendants(matching: .any).matching(identifier: "agent.activity").firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, state),
                    evaluatedWith: activity)
        waitForExpectations(timeout: 10)
    }

    private func brightSamples(_ image: UIImage) -> Int {
        guard let image = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return stride(from: 0, to: bytes.count, by: 4).filter {
                Int(bytes[$0]) + Int(bytes[$0 + 1]) + Int(bytes[$0 + 2]) > 180
            }.count
        }
    }
}
