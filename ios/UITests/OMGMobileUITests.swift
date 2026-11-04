import XCTest
import UIKit

final class OMGMobileUITests: XCTestCase {
    func testAttachTakeoverTypeAndMacReclaim() {
        // The isolated host fixture uses a public synthetic test token, never
        // a user's saved pairing key or existing terminal session.
        let app = XCUIApplication()
        let server = Bundle(for: Self.self).object(forInfoDictionaryKey: "OMGTestServer") as? String ?? "127.0.0.1:18790"
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
        let session = app.cells["session.77777777-1111-2222-3333-444444444444"]
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
        app.typeText("printf '\\115\\117\\102\\111\\114\\105\\137\\125\\111\\137\\105\\130\\105\\103\\125\\124\\105\\104\\n'\n")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "输入权已交给"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        let viewport = app.scrollViews["terminal.viewport"]
        XCTAssertGreaterThan(brightSamples(viewport.screenshot().image), 16,
            "The shared terminal must remain visible after keyboard changes and writer transfer.")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Shared terminal after mobile input and Mac reclaim"
        image.lifetime = .keepAlways
        add(image)
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
