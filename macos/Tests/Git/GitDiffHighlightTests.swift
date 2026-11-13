import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct GitDiffHighlightTests {
    @Test func sidebarWidthChangesKeepWrappedEditorAlive() async throws {
        let text = (0..<420).map { "\($0) 每行还包含 `trip_completed`、`trip_end_time_us`、`trip_end_time_cn`。" }.joined(separator: "\n")
        let workbench = MonacoWorkbenchController()
        defer { workbench.tearDown() }
        let host = NSHostingView(rootView: CodeEditorView(
            text: .constant(text),
            fileURL: URL(fileURLWithPath: "/file.md"),
            diffLines: [324: true, 325: true],
            isEditable: false,
            isActive: true,
            terminalTheme: .oneDark,
            externalController: workbench
        ))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 780, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func find(_ view: NSView) -> MonacoEditorWebView? {
            (view as? MonacoEditorWebView) ?? view.subviews.lazy.compactMap(find).first
        }
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(find(host))
        #expect(!editor.isOpaque)
        #expect(editor.underPageBackgroundColor == .clear)
        for _ in 0..<3 {
            for width: CGFloat in [315.5, 780, 360, 780] {
                window.setContentSize(.init(width: width, height: 650))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
                let activeURI = try #require(workbench.activeURI)
                #expect(workbench.openModels[activeURI]?.text == text)
                #expect(workbench.openModels[activeURI]?.readOnly == true)
                #expect(find(host) === editor)
            }
        }
    }

    @Test(arguments: [false, true]) func changedLinesRemainHighlightedAfterScrolling(realCase: Bool) async throws {
        let lines = (0..<420).map {
            "\($0) Each record contains trip_completed, trip_end_time_us and trip_end_time_cn, with additional metadata for wrapping."
        }
        var text = lines.joined(separator: "\n")
        if realCase {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/omg-real-diff-case.json")) else { return }
            let values = try JSONDecoder().decode([String: String].self, from: data)
            text = try #require(values["after"])
            let presentation = GitDiffPresentation(
                before: values["before"] ?? "",
                after: text,
                patch: values["patch"] ?? ""
            )
            #expect(presentation.isConsistent && presentation.afterHighlights[324] == true && presentation.afterHighlights[325] == true)
        }
        let workbench = MonacoWorkbenchController()
        defer { workbench.tearDown() }
        let host = NSHostingView(rootView: CodeEditorView(
            text: .constant(text),
            fileURL: URL(fileURLWithPath: "/api-reference.md"),
            diffLines: [324: true, 325: false],
            isEditable: false,
            isActive: true,
            terminalTheme: .oneDark,
            externalController: workbench
        ))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 540, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<80 {
            if workbench.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let activeURI = try #require(workbench.activeURI)
        #expect(workbench.openModels[activeURI]?.text == text)
        workbench.revealRange(uri: activeURI, startLine: 325, startColumn: 1)
        host.layoutSubtreeIfNeeded()
        #expect(workbench.webView?.isOpaque == false)
    }
}
