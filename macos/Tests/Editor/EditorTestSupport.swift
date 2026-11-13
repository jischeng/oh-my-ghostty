import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

/// Shared host setup for tests mounting SwiftUI editor views and `MonacoEditorWebView`.
@MainActor
enum EditorTestSupport {
    /// Mounts a view in an offscreen window and returns the hosting controller
    /// plus the window so callers can keep both alive for the test's duration.
    static func host<Content: View>(
        _ view: Content,
        size: NSSize = NSSize(width: 600, height: 400)
    ) -> (NSHostingController<Content>, NSWindow) {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(size)
        host.view.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// Tears a mounted editor window down cleanly.
    static func unmount<Content: View>(_ mounted: (NSHostingController<Content>, NSWindow)) {
        mounted.1.contentViewController = nil
        mounted.1.orderOut(nil)
        mounted.1.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// Lightweight mount for tests that only need a bare hosting view with an explicit frame.
    static func hostedView<Content: View>(
        _ view: Content,
        size: NSSize = NSSize(width: 720, height: 480)
    ) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        return host
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let found = find(type, in: child) {
                return found
            }
        }
        return nil
    }

    static func findAll<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var matches: [T] = []
        if let match = view as? T {
            matches.append(match)
        }
        for child in view.subviews {
            matches.append(contentsOf: findAll(type, in: child))
        }
        return matches
    }

    static func waitForMonacoReady(
        in rootView: NSView?,
        attempts: Int = 200
    ) async throws -> MonacoEditorWebView {
        for _ in 0..<attempts {
            if let webView = find(MonacoEditorWebView.self, in: rootView) {
                let ready = (try? await webView.evaluateJavaScript("Boolean(window.omgEditor)")) as? Bool
                if ready == true {
                    return webView
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for MonacoEditorWebView window.omgEditor to become ready")
        throw CancellationError()
    }
}
