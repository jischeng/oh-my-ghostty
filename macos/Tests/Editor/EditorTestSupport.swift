import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
@testable import Ghostty

/// Shared host setup for tests that need a real `SourceEditor`.
///
/// `SourceEditor` takes its presentation as one `SourceEditorConfiguration`
/// value, so tests build it here instead of repeating the parameter list.
@MainActor
enum EditorTestSupport {
    static func configuration(
        theme: EditorTheme? = nil,
        fontSize: CGFloat = 13,
        tabWidth: Int = 4,
        wrapLines: Bool = false
    ) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme ?? .oneDark,
                useThemeBackground: true,
                font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                lineHeightMultiple: 1.2,
                wrapLines: wrapLines,
                tabWidth: tabWidth
            )
        )
    }

    static func editor(
        text: Binding<String>,
        language: CodeLanguage,
        configuration config: SourceEditorConfiguration? = nil,
        highlightProviders: [any HighlightProviding] = [],
        coordinators: [any TextViewCoordinator] = [],
        state: Binding<SourceEditorState> = .constant(SourceEditorState())
    ) -> SourceEditor {
        SourceEditor(
            text,
            language: language,
            configuration: config ?? configuration(),
            state: state,
            highlightProviders: highlightProviders,
            coordinators: coordinators
        )
    }

    /// Mounts an editor in an offscreen window and returns the hosting controller
    /// plus the window so callers can keep both alive for the test's duration.
    static func host<Content: View>(_ view: Content, size: NSSize = NSSize(width: 600, height: 400))
        -> (NSHostingController<Content>, NSWindow) {
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// Tears a mounted editor down completely.
    ///
    /// Closing the window alone leaves the hosting controller in AppKit's layout
    /// queue. A later test that mounts another editor can then run layout against
    /// the detached text view, whose line storage no longer matches its storage,
    /// which traps inside the text view. Detaching the content view controller and
    /// draining the run loop first keeps editors from bleeding across tests.
    static func unmount<Content: View>(_ mounted: (NSHostingController<Content>, NSWindow)) {
        mounted.1.contentViewController = nil
        mounted.1.orderOut(nil)
        mounted.1.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// Lightweight mount for tests that only need the native text view laid out.
    ///
    /// Several windowed editors in one process destabilize AppKit layout, so
    /// storage-level assertions use a bare hosting view with an explicit frame.
    static func hostedView<Content: View>(_ view: Content, size: NSSize = NSSize(width: 720, height: 480))
        -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        return host
    }
}

/// Captures the `TextViewController` so tests can reach the native editor.
@MainActor
final class CompletionTestCapture: @preconcurrency TextViewCoordinator {
    weak var controller: TextViewController?
    func prepareCoordinator(controller: TextViewController) { self.controller = controller }
}
