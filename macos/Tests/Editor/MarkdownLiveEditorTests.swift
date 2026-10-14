import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct MarkdownLiveEditorTests {
    @Test func editsRejectStaleDocumentsAndInvalidContent() {
        #expect(MarkdownPreviewEdit.canApply(current: "old", base: "old", updated: "# new"))
        #expect(!MarkdownPreviewEdit.canApply(current: "newer", base: "old", updated: "stale"))
        #expect(!MarkdownPreviewEdit.canApply(current: "old", base: "old", updated: "bad\0text"))
    }

    @Test func liveMarkdownInputUpdatesBindingCopiesAndSaves() async throws {
        var text = ""
        var saved: String?
        let binding = Binding(get: { text }, set: { text = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MarkdownPreviewView(
            text: binding, fileURL: URL(fileURLWithPath: "/tmp/live.md"),
            terminalBackground: .black, foregroundColor: .white, onSave: { saved = text }
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        var found: MarkdownPreviewWebView?
        for _ in 0..<150 {
            found = findWebView(window.contentView)
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let web = try #require(found)
        var ready = false
        for _ in 0..<150 {
            ready = (try? await web.evaluateJavaScript("!!window.omgLiveEditorView && !!document.querySelector('.cm-editor .cm-content')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready, "The offline live editor must load in the actual WKWebView")
        window.makeFirstResponder(web)
        let converted = try await web.evaluateJavaScript("""
        (() => {
            const view = window.omgLiveEditorView();
            view.focus();
            view.dispatch({changes: {from: 0, insert: '# '}, selection: {anchor: 2}, userEvent: 'input'});
            view.dispatch({changes: {from: 2, insert: 'Hello 中文'}, selection: {anchor: 10}, userEvent: 'input'});
            return Boolean(document.querySelector('.cm-md-h1') && view.state.doc.toString() === '# Hello 中文');
        })()
        """)
        #expect(converted as? Bool == true)
        for _ in 0..<100 {
            if text.contains("# Hello 中文") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.contains("# Hello 中文"))
        _ = try await web.evaluateJavaScript("""
        (() => {
            const view = window.omgLiveEditorView(); view.focus();
            view.dispatch({selection: {anchor: 2, head: view.state.doc.length}});
        })()
        """)
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8))
        #expect(EditorCommandRouter.shared.handle(copy))
        for _ in 0..<100 {
            if NSPasteboard.general.string(forType: .string) == "Hello 中文" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(NSPasteboard.general.string(forType: .string) == "Hello 中文")
        let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 1))
        #expect(EditorCommandRouter.shared.handle(save))
        for _ in 0..<100 {
            if saved != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(saved == text)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = try String(contentsOf: root.appendingPathComponent("dist/tests/fixtures/markdown-preview.md"), encoding: .utf8)
        text = sample
        _ = try await callJavaScript(web, body: "return await window.renderMarkdown(markdown, options);", arguments: [
            "markdown": sample,
            "options": ["theme": "dark", "background": "#202020", "foreground": "#eeeeee", "editable": true],
        ])
        let positionsJSON = try #require(try await web.evaluateJavaScript("""
        JSON.stringify(window.omgMarkdownModel.parseBlocks(window.getMarkdown())
            .filter(block => block.kind === 'code' && block.language === 'mermaid').map(block => block.from))
        """) as? String)
        let positions = try JSONDecoder().decode([Int].self, from: Data(positionsJSON.utf8))
        #expect(positions.count == 2)
        for position in positions {
            _ = try await web.evaluateJavaScript("window.scrollMarkdownTo(\(position))")
            var rendered = false
            for _ in 0..<100 {
                rendered = try await web.evaluateJavaScript("!!document.querySelector('.omg-block-widget[data-source-from=\"\(position)\"] .mermaid svg')") as? Bool == true
                if rendered { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if !rendered {
                let diagnostics = try? await web.evaluateJavaScript("""
                JSON.stringify({
                    visibility: document.visibilityState, focused: document.hasFocus(),
                    activeElement: document.activeElement?.className,
                    position: \(position), innerHeight: window.innerHeight,
                    selection: window.omgLiveEditorView?.()?.state.selection.main.head,
                    viewport: window.omgLiveEditorView?.()?.viewport,
                    visibleRanges: window.omgLiveEditorView?.()?.visibleRanges,
                    mermaidLoaded: !!window.mermaid,
                    widgets: Array.from(document.querySelectorAll('.omg-block-widget')).map(e => ({
                        from: e.dataset.sourceFrom, kind: e.className,
                        y: e.getBoundingClientRect().y, height: e.getBoundingClientRect().height,
                        svg: !!e.querySelector('.mermaid svg'),
                        error: e.querySelector('.render-error')?.textContent?.slice(0, 300),
                        hasMermaidSource: !!e.querySelector('code.language-mermaid')
                    })),
                    scroll: Array.from(document.querySelectorAll('.cm-scroller')).map(e => ({
                        top: e.scrollTop, height: e.clientHeight, scrollHeight: e.scrollHeight
                    }))
                })
                """)
                print("Mermaid timeout diagnostic: key=\(window.isKeyWindow) visible=\(window.isVisible) "
                      + "occluded=\(!window.occlusionState.contains(.visible)) js=\(diagnostics ?? "unavailable")")
            }
            #expect(rendered, "A visible Mermaid block should render its diagram")
        }
        _ = try await web.evaluateJavaScript("window.scrollMarkdownTo(window.getMarkdown().indexOf('| Feature'))")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await web.evaluateJavaScript("!!document.querySelector('.cm-editor table')") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.scrollMarkdownTo(window.getMarkdown().indexOf('## LaTeX'))")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.cm-editor .katex').length >= 1") as? Bool == true)
        if let html = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String {
            try html.write(toFile: "/tmp/omg-live-editor-dom.html", atomically: true, encoding: .utf8)
        }
        _ = try await web.evaluateJavaScript("document.activeElement.blur()")
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = try await web.takeSnapshot(configuration: nil)
        if let data = snapshot.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/omg-live-markdown-preview.png"))
        }
        for (theme, width) in [("light", 900), ("dark", 900), ("dark", 380)] {
            window.setContentSize(NSSize(width: width, height: 650))
            _ = try await callJavaScript(web, body: "return await window.renderMarkdown(markdown, options);", arguments: [
                "markdown": sample,
                "options": ["theme": theme, "background": theme == "dark" ? "#202020" : "#ffffff",
                            "foreground": theme == "dark" ? "#eeeeee" : "#1f2328", "editable": true],
            ])
            _ = try await web.evaluateJavaScript("window.scrollMarkdownTo(0)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await web.evaluateJavaScript("document.documentElement.scrollWidth <= window.innerWidth") as? Bool == true)
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/omg-live-markdown-\(theme)-\(width).png"))
            }
        }
    }

    @Test func liveMermaidConstructedWhileDetachedRendersAfterMount() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MarkdownPreviewView(
            text: .constant("# Warmup"), fileURL: URL(fileURLWithPath: "/tmp/delayed-mermaid.md"),
            terminalBackground: .black, foregroundColor: .white
        ))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        var web: MarkdownPreviewWebView?
        var ready = false
        for _ in 0..<150 {
            web = findWebView(window.contentView)
            if let web {
                ready = (try? await web.evaluateJavaScript("!!window.omgLiveEditorView?.()")) as? Bool == true
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready)
        let preview = try #require(web)
        let state = try await callJavaScript(preview, body: """
        const view = window.omgLiveEditorView();
        view.dom.remove();
        await window.renderMarkdown(markdown, options);
        // Let construction-time render tasks run while the DOM is detached.
        await new Promise(resolve => setTimeout(resolve, 0));
        const widget = view.dom.querySelector('.omg-block-widget');
        const state = { constructedDetached: !!widget && !widget.isConnected,
                        renderedDetached: !!widget?.querySelector('.mermaid svg') };
        document.getElementById('content').append(view.dom);
        return state;
        """, arguments: [
            "markdown": "# Delayed mount\n\n```mermaid\ngraph LR; A-->B\n```",
            "options": ["theme": "dark", "background": "#202020", "foreground": "#eeeeee", "editable": true],
        ])
        let result = try #require(state as? [String: Bool])
        #expect(result["constructedDetached"] == true)
        #expect(result["renderedDetached"] == false)
        var rendered = false
        for _ in 0..<100 {
            rendered = try await preview.evaluateJavaScript("!!document.querySelector('.omg-block-widget .mermaid svg')") as? Bool == true
            if rendered { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(rendered, "A Mermaid widget mounted after its construction task must still render")
    }

    private func callJavaScript(_ web: WKWebView, body: String, arguments: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func findWebView(_ view: NSView?) -> MarkdownPreviewWebView? {
        if let view = view as? MarkdownPreviewWebView { return view }
        for child in view?.subviews ?? [] {
            if let found = findWebView(child) { return found }
        }
        return nil
    }
}
