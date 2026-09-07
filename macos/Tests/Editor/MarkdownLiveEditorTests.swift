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
            ready = (try? await web.evaluateJavaScript("!!window.omgLiveEditorView && !!document.querySelector('.ProseMirror')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready, "The offline live editor must load in the actual WKWebView")
        window.makeFirstResponder(web)
        let converted = try await web.evaluateJavaScript("""
        (() => {
            const view = window.omgLiveEditorView();
            view.dom.focus();
            view.dispatch(view.state.tr.insertText('#'));
            const {from, to} = view.state.selection;
            const handled = view.someProp('handleTextInput', handler => handler(view, from, to, ' '));
            view.dispatch(view.state.tr.insertText('Hello 中文'));
            return Boolean(handled && view.state.doc.firstChild.type.name === 'heading');
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
            document.querySelector('.ProseMirror').focus();
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('.ProseMirror h1'));
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
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
        _ = try await web.callAsyncJavaScript("return await window.renderMarkdown(markdown, options);", arguments: [
            "markdown": sample,
            "options": ["theme": "dark", "background": "#202020", "foreground": "#eeeeee", "editable": true],
        ], in: nil, in: .page)
        let positionsJSON = try #require(try await web.evaluateJavaScript("""
        (() => { const positions = []; window.omgLiveEditorView().state.doc.descendants((node, pos) => {
            if (node.type.name === 'code_block' && node.attrs.language === 'mermaid') positions.push(pos);
        }); return JSON.stringify(positions); })()
        """) as? String)
        let positions = try JSONDecoder().decode([Int].self, from: Data(positionsJSON.utf8))
        #expect(positions.count == 2)
        for position in positions {
            _ = try await web.evaluateJavaScript("window.omgLiveEditorView().nodeDOM(\(position)).scrollIntoView({block:'center'})")
            var rendered = false
            for _ in 0..<100 {
                rendered = try await web.evaluateJavaScript("!!window.omgLiveEditorView().nodeDOM(\(position)).querySelector('.mermaid svg')") as? Bool == true
                if rendered { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(rendered, "A visible Mermaid block should render its diagram")
        }
        #expect(try await web.evaluateJavaScript("!!document.querySelector('.ProseMirror table')") as? Bool == true)
        _ = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('h2')).find(h => h.textContent.includes('LaTeX'))?.scrollIntoView()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.ProseMirror .katex').length >= 3") as? Bool == true)
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
    }

    private func findWebView(_ view: NSView?) -> MarkdownPreviewWebView? {
        if let view = view as? MarkdownPreviewWebView { return view }
        for child in view?.subviews ?? [] {
            if let found = findWebView(child) { return found }
        }
        return nil
    }
}
