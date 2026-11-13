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

    @Test func previewTaskToggleCodeCopyFileLinkSelectionAndSave() async throws {
        var text = """
        # Hello 中文

        - [ ] Ship responsive preview
        - [x] Keep offline security

        | 场景编号 | 核心代码入口 |
        | --- | --- |
        | S0 | [lance_metadata.py](file:///workspace/server/lance_metadata.py#L35-L101) |

        ```python
        def answer():
            return 42
        ```

        ````carousel
        ### Slide One
        First slide body
        <!-- slide -->
        ### Slide Two
        Second slide body
        ````
        """
        var saved: String?
        var openedLink: String?
        let binding = Binding(get: { text }, set: { text = $0 })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MarkdownPreviewView(
            text: binding,
            fileURL: URL(fileURLWithPath: "/tmp/preview-interactive.md"),
            terminalBackground: .black,
            foregroundColor: .white,
            onSave: { saved = text },
            onOpenLink: { openedLink = $0 }
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        let web = try await waitForWebView(in: window)
        try await waitUntil {
            (try? await web.evaluateJavaScript("!!document.querySelector('#content h1') && !!document.querySelector('.omg-carousel')")) as? Bool == true
        }
        window.makeFirstResponder(web)

        // 1. Interactive task-list checkbox toggles exact character in Markdown source
        _ = try await web.evaluateJavaScript("""
        (() => {
            const box = document.querySelector('#content input.task-list-item-checkbox:not(:checked)');
            box.checked = true;
            box.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
        })()
        """)
        try await waitUntil { text.contains("- [x] Ship responsive preview") }
        #expect(text.contains("- [x] Ship responsive preview"))

        // 2. Code block Copy button writes raw code to NSPasteboard
        NSPasteboard.general.clearContents()
        _ = try await web.evaluateJavaScript("""
        (() => {
            document.querySelector('#content .omg-code-copy').click();
            return true;
        })()
        """)
        try await waitUntil {
            NSPasteboard.general.string(forType: .string)?.contains("def answer():") == true
        }
        #expect(NSPasteboard.general.string(forType: .string)?.contains("return 42") == true)

        // 3. file://#L35-L101 capsule renders line badge and forwards click to native opener
        let fileCapsuleRendered = try await web.evaluateJavaScript("""
        (() => {
            const link = document.querySelector('#content a.omg-file-link');
            if (!link) return false;
            const hasLine = link.querySelector('.omg-file-line')?.textContent === ':L35-L101';
            link.click();
            return hasLine;
        })()
        """) as? Bool
        #expect(fileCapsuleRendered == true)
        try await waitUntil { openedLink != nil }
        #expect(openedLink == "file:///workspace/server/lance_metadata.py#L35-L101")

        // 4. Carousel switches slides interactively
        let switchedSlide = try await web.evaluateJavaScript("""
        (() => {
            const next = document.querySelector('#content .omg-carousel-btn[data-dir="1"]');
            next.click();
            const active = document.querySelector('#content .omg-carousel-slide.active');
            return active?.textContent?.includes('Second slide body') ?? false;
        })()
        """) as? Bool
        #expect(switchedSlide == true)

        // 5. Cmd+C copies selected rendered heading and Cmd+S saves
        _ = try await web.evaluateJavaScript("""
        (() => {
            const h1 = document.querySelector('#content h1');
            const range = document.createRange();
            range.selectNodeContents(h1);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return sel.toString();
        })()
        """)
        let copy = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        #expect(EditorCommandRouter.shared.handle(copy))
        try await waitUntil { NSPasteboard.general.string(forType: .string) == "Hello 中文" }
        #expect(NSPasteboard.general.string(forType: .string) == "Hello 中文")

        let save = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
        ))
        #expect(EditorCommandRouter.shared.handle(save))
        try await waitUntil { saved != nil }
        #expect(saved == text)
    }

    @Test func previewReflowsFluidlyAcrossWindowResizesAndRendersWideTablesAndMermaid() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try String(
            contentsOf: root.appendingPathComponent("dist/tests/fixtures/markdown-preview.md"),
            encoding: .utf8
        )
        let wideTableSection = """

        ## Wide CJK Production Table

        | 场景编号 | 场景名称与代表策略 | 近 14 天任务数 | 线上 Spark 耗时 (P50 / P90) | 核心代码入口 | 输入源与核心算子特征 | 结果写出目标 (Sink) |
        | --- | --- | --- | --- | --- | --- | --- |
        | S0 | 元数据 / Schema 探测 | 高频同步 | `< 0.2s` | [lance_metadata.py](file:///workspace/lake_search/lance_metadata.py#L35-L101) | 直调 LakeForge HTTP + 本地 `sqlglot` | 同步 HTTP JSON |
        """
        let sample = fixture + wideTableSection

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MarkdownPreviewView(
            text: .constant(sample),
            fileURL: URL(fileURLWithPath: "/tmp/reflow.md"),
            terminalBackground: .black,
            foregroundColor: .white
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        let web = try await waitForWebView(in: window)
        try await waitUntil(attempts: 150) {
            (try? await web.evaluateJavaScript("document.querySelectorAll('#content .mermaid svg').length === 2")) as? Bool == true
        }

        let widthAt1280 = try #require(
            try await web.evaluateJavaScript("document.getElementById('content').getBoundingClientRect().width") as? Double
        )
        #expect(widthAt1280 > 960, "Fluid preview container must expand with wide panes instead of freezing at 960px")

        for (theme, width) in [("light", 900), ("dark", 900), ("dark", 380)] {
            window.setContentSize(NSSize(width: width, height: 700))
            _ = try await callJavaScript(web, body: "return await window.renderMarkdown(markdown, options);", arguments: [
                "markdown": sample,
                "options": [
                    "theme": theme,
                    "background": "transparent",
                    "foreground": theme == "dark" ? "#eeeeee" : "#1f2328",
                    "editable": true,
                ],
            ])
            try await Task.sleep(for: .milliseconds(120))
            let metrics = try #require(try await web.evaluateJavaScript("""
            (() => {
                const headers = Array.from(document.querySelectorAll('#content .omg-table-wrap:last-of-type th'));
                const minHeaderWidth = headers.reduce((acc, th) => Math.min(acc, th.getBoundingClientRect().width), Infinity);
                return {
                    noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth + 1,
                    contentWidth: document.getElementById('content').getBoundingClientRect().width,
                    minHeaderWidth,
                    katexCount: document.querySelectorAll('#content .katex').length,
                };
            })()
            """) as? [String: Any])
            #expect(metrics["noPageOverflow"] as? Bool == true)
            #expect((metrics["minHeaderWidth"] as? Double ?? 0) > 40, "CJK table headers must never crush into 1-char vertical strips")
            #expect((metrics["katexCount"] as? Int ?? 0) >= 1)
            if width == 380 {
                #expect((metrics["contentWidth"] as? Double ?? 999) <= 381)
            }
        }
    }

    @Test func codeEditorWordWrapReflowsOnResizeAndNavigationSwitchesMarkdownToEdit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-md-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("notes.md")
        let longParagraph = String(repeating: "这是一段用于验证窗口缩放后自动折行重排的 Markdown 源码内容 AutomaticWordWrapReflowCheck ", count: 8)
        try Data((longParagraph + "\n# Second Line\n").utf8).write(to: file)

        let filesystem = LocalWorkspaceFilesystem(workingDirectory: dir.path)
        let document = try await EditorDocument.open(path: file.path, filesystem: filesystem)
        #expect(document.isMarkdown)
        #expect(document.isPreviewMode)

        document.requestNavigation(EditorTextLocation(startLine: 2, column: 1, endLine: nil))
        #expect(!document.isPreviewMode, "Navigating to a line in a Markdown document must switch from Preview to Edit")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CodeEditorView(
            text: .constant(longParagraph),
            fileURL: file,
            wordWrapOverride: true
        ))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        let monacoWeb = try await EditorTestSupport.waitForMonacoReady(in: window.contentView)
        try await waitUntil {
            let count = (try? await monacoWeb.evaluateJavaScript(
                "window.omgEditor?._internal?.editor?.getModel?.()?.getLineCount?.() ?? 0"
            )) as? Int
            return (count ?? 0) >= 1
        }
        _ = try await monacoWeb.evaluateJavaScript("window.omgEditor._internal.editor.layout({ width: 960, height: 520 });")
        try await Task.sleep(for: .milliseconds(80))
        let wideHeight = try #require(
            try await monacoWeb.evaluateJavaScript("window.omgEditor._internal.editor.getContentHeight()") as? Double
        )

        window.setContentSize(NSSize(width: 320, height: 520))
        _ = try await monacoWeb.evaluateJavaScript("window.omgEditor._internal.editor.layout({ width: 320, height: 520 });")
        try await Task.sleep(for: .milliseconds(100))
        let narrowHeight = try #require(
            try await monacoWeb.evaluateJavaScript("window.omgEditor._internal.editor.getContentHeight()") as? Double
        )
        #expect(narrowHeight > wideHeight * 1.4, "Narrowing a word-wrapped editor must reflow lines and increase wrapped height")

        window.setContentSize(NSSize(width: 960, height: 520))
        _ = try await monacoWeb.evaluateJavaScript("window.omgEditor._internal.editor.layout({ width: 960, height: 520 });")
        try await Task.sleep(for: .milliseconds(100))
        let restoredHeight = try #require(
            try await monacoWeb.evaluateJavaScript("window.omgEditor._internal.editor.getContentHeight()") as? Double
        )
        #expect(restoredHeight < narrowHeight, "Widening a word-wrapped editor back must unwrap lines cleanly")
    }

    @Test func previewRemainsTransparentAcrossInitialLoadModeSwitchAndUpdates() async throws {
        var text = "# Translucent Backdrop Check\n\nParagraph text."
        var isActive = true
        var background = NSColor.black
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        func makeRoot() -> some View {
            ZStack {
                Color.green
                MarkdownPreviewView(
                    text: .constant(text),
                    fileURL: URL(fileURLWithPath: "/tmp/translucent.md"),
                    terminalBackground: background,
                    foregroundColor: .white,
                    isActive: isActive
                )
            }
        }
        let host = NSHostingView(rootView: AnyView(makeRoot()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        let web = try await waitForWebView(in: window)
        try await waitUntil {
            (try? await web.evaluateJavaScript("!!document.querySelector('#content h1')")) as? Bool == true
        }

        func assertTransparentWebView(_ stage: String) async throws {
            #expect(!web.isOpaque, "WebView must report isOpaque == false (\(stage))")
            #expect((web.value(forKey: "drawsBackground") as? Bool) == false, "drawsBackground must stay false (\(stage))")
            #expect((web.underPageBackgroundColor?.alphaComponent ?? 0) == 0, "underPageBackgroundColor must stay clear (\(stage))")
            let alpha = web.layer?.backgroundColor?.alpha ?? 0
            #expect(alpha == 0, "WebView layer must never paint an opaque terminalBackground (\(stage)), found alpha=\(alpha)")
            let domTransparent = try await web.evaluateJavaScript("""
            (() => {
                const htmlBg = getComputedStyle(document.documentElement).backgroundColor;
                const bodyBg = getComputedStyle(document.body).backgroundColor;
                const isClear = v => v === 'rgba(0, 0, 0, 0)' || v === 'transparent';
                return isClear(htmlBg) && isClear(bodyBg);
            })()
            """) as? Bool
            #expect(domTransparent == true, "HTML/body computed background must remain transparent (\(stage))")
        }

        // 1. Initial load must already be transparent (never start opaque)
        try await assertTransparentWebView("initial load")

        // 2. Toggle inactive -> active (Edit <-> Preview) and re-update
        isActive = false
        host.rootView = AnyView(makeRoot())
        try await Task.sleep(for: .milliseconds(80))
        try await assertTransparentWebView("after deactivating")

        // 3. Subsequent SwiftUI updates (simulating periodic terminal/workspace state ticks)
        isActive = true
        text = "# Translucent Backdrop Check\n\nUpdated paragraph."
        background = NSColor(deviceRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        host.rootView = AnyView(makeRoot())
        try await waitUntil {
            (try? await web.evaluateJavaScript("document.querySelector('#content')?.innerText.includes('Updated paragraph.')")) as? Bool == true
        }
        try await assertTransparentWebView("after subsequent SwiftUI updates")
    }

    private func waitForWebView(in window: NSWindow) async throws -> MarkdownPreviewWebView {
        for _ in 0..<150 {
            if let found = findWebView(window.contentView) {
                return found
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MarkdownLiveTestError.timeout
    }

    private func waitUntil(attempts: Int = 100, condition: () async -> Bool) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw MarkdownLiveTestError.timeout
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

private enum MarkdownLiveTestError: Error {
    case timeout
}
