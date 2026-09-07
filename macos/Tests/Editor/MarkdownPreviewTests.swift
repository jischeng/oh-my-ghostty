import AppKit
import Foundation
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct MarkdownPreviewTests {
    @Test func bundledRendererIncludesOfflineDependencies() throws {
        let root = try #require(Bundle.main.url(forResource: "MarkdownPreview", withExtension: nil))
        for name in [
            "template.html", "render.js", "style.css", "markdown-it.min.js",
            "markdown-it-task-lists.min.js", "markdownItAnchor.umd.js", "highlight.min.js",
            "katex.min.js", "katex.min.css", "texmath.min.js", "purify.min.js", "mermaid.min.js",
            "github.min.css", "github-dark.min.css", "fonts/KaTeX_Main-Regular.woff2",
        ] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "Missing \(name)")
        }
    }

    @Test(arguments: ["/Users/test/本地 # 笔记", "/home/test/远程 # 笔记"])
    func imageBaseURLPreservesLocalAndSSHPaths(directory: String) throws {
        let base = MarkdownPreviewResources.imageBaseURL(directory: URL(fileURLWithPath: directory))
        #expect(base.scheme == "omg-markdown-image")
        #expect(base.host == "document")
        #expect(base.fragment == nil)
        #expect(base.query == nil)
        let image = try #require(URL(string: "assets/%E5%9B%BE%20%23.svg", relativeTo: base)?.absoluteURL)
        #expect(image.path == directory + "/assets/图 #.svg")
        #expect(image.fragment == nil)
        #expect(MarkdownPreviewResources.imageMIMEType(for: image) == "image/svg+xml")
    }

    @Test func imageResourceBoundaryRejectsScriptsAndOtherOrigins() throws {
        for path in [
            "omg-markdown-image://document/file.html", "omg-markdown-image://document/file.js",
            "omg-markdown-image://document/file.txt", "omg-markdown-image://document/file.svg.js",
            "omg-markdown-image://other/file.svg", "file:///tmp/file.svg", "https://example.com/file.svg",
        ] {
            #expect(MarkdownPreviewResources.imageMIMEType(for: try #require(URL(string: path))) == nil)
        }
        for (extensionName, mimeType) in [("PNG", "image/png"), ("svg", "image/svg+xml"), ("jpg", "image/jpeg")] {
            let url = try #require(URL(string: "omg-markdown-image://document/image.\(extensionName)"))
            #expect(MarkdownPreviewResources.imageMIMEType(for: url) == mimeType)
        }
    }

    @Test func webKitRendersBundledMarkdownAndLocalSVG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-markdown-\(UUID().uuidString)/中文 # 笔记", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\"><rect width=\"12\" height=\"12\" fill=\"red\"/></svg>"
        try Data(svg.utf8).write(to: directory.appendingPathComponent("图 #.svg"))

        let resources = MarkdownPreviewResources()
        resources.filesystem = LocalWorkspaceFilesystem(workingDirectory: directory.path)
        let messages = MarkdownPreviewMessageProbe()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(resources, forURLScheme: "omg-markdown")
        configuration.setURLSchemeHandler(resources, forURLScheme: "omg-markdown-image")
        configuration.userContentController.add(messages, name: "markdownPreview")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        defer {
            webView.stopLoading()
            resources.cancelAll()
            configuration.userContentController.removeScriptMessageHandler(forName: "markdownPreview")
        }
        webView.load(URLRequest(url: try #require(URL(string: "omg-markdown://bundle/template.html"))))
        try await messages.wait(for: "ready")
        let markdown = """
        ![local](%E5%9B%BE%20%23.svg)

        | Name | Value |
        | --- | --- |
        | 中文 | 1 |

        > [!Tips]
        > colored alert

        - [x] completed
        - outer
          - nested

        ```swift
        let answer = 42
        ```

        $x^2$

        ```mermaid
        graph LR
          A --> B
        ```

        ---

        <script>window.markdownUnsafe = true</script>
        <img src="x" onerror="window.markdownUnsafe = true">
        """
        let payload = try JSONSerialization.data(withJSONObject: [
            "text": markdown,
            "options": ["baseURL": MarkdownPreviewResources.imageBaseURL(directory: directory).absoluteString],
        ])
        let json = try #require(String(data: payload, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("{ const p = \(json); window.renderMarkdown(p.text, p.options); } true;")
        try await messages.wait(for: "rendered")
        let result = try #require(try await webView.evaluateJavaScript("""
        (() => {
            const count = selector => document.querySelectorAll('#content ' + selector).length;
            document.querySelector('#content img').loading = 'eager';
            return {
                table: count('table tbody tr'), alert: count('.markdown-alert-tip'),
                todo: count('input[type=checkbox]:checked:disabled'), nested: count('ul ul'),
                highlight: count('.hljs-keyword'), math: count('.katex'), diagram: count('.mermaid svg'),
                rule: count('hr'), errors: count('.render-error'),
                unsafe: Boolean(window.markdownUnsafe || count('script') || count('[onerror]'))
            };
        })()
        """) as? [String: Any])
        for key in ["table", "alert", "todo", "nested", "highlight", "math", "diagram", "rule"] {
            #expect((result[key] as? Int ?? 0) > 0, "Missing rendered \(key)")
        }
        #expect(result["errors"] as? Int == 0)
        #expect(result["unsafe"] as? Bool == false)
        var loaded = false
        for _ in 0..<100 {
            loaded = (try await webView.evaluateJavaScript("document.querySelector('#content img').naturalWidth > 0")) as? Bool == true
            if loaded { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(loaded, "Local SVG should load through the document filesystem scheme")
    }
}

@MainActor
private final class MarkdownPreviewMessageProbe: NSObject, WKScriptMessageHandler {
    private var received: Set<String> = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: String], let type = body["type"] { received.insert(type) }
    }

    func wait(for type: String) async throws {
        for _ in 0..<150 {
            if received.contains(type) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MarkdownPreviewProbeError.missingMessage(type)
    }
}

private enum MarkdownPreviewProbeError: Error {
    case missingMessage(String)
}
