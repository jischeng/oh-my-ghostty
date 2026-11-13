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
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("live-editor.js").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("live-editor.css").path))
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
        _ = try await webView.evaluateJavaScript("{ const p = \(json); window.renderMarkdownReadonly(p.text, p.options); } true;")
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

    @Test func templateCSPRemovesExternalHTTPAndHTTPSFromImageSources() throws {
        let root = try #require(Bundle.main.url(forResource: "MarkdownPreview", withExtension: nil))
        let html = try String(contentsOf: root.appendingPathComponent("template.html"), encoding: .utf8)
        let directives = html.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let imgSrc = try #require(directives.first(where: { $0.hasPrefix("img-src ") }))
        #expect(imgSrc.contains("'self'"))
        #expect(imgSrc.contains("omg-markdown:"))
        #expect(imgSrc.contains("omg-markdown-image:"))
        #expect(imgSrc.contains("data:"))
        #expect(imgSrc.contains("blob:"))
        #expect(!imgSrc.contains("http:"))
        #expect(!imgSrc.contains("https:"))
    }

    @Test func imageSchemeEnforcesAllowedRootAndRejectsTraversalAndSymlinkEscapesWith403() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-md-boundary-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = sandbox.appendingPathComponent("workspace", isDirectory: true)
        let docsDir = workspaceRoot.appendingPathComponent("docs", isDirectory: true)
        let assetsDir = workspaceRoot.appendingPathComponent("assets", isDirectory: true)
        let outsideDir = sandbox.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let validSVG = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"/>".utf8)
        let secretPNG = Data([0x89, 0x50, 0x4E, 0x47])
        let validAsset = assetsDir.appendingPathComponent("ok.svg")
        let outsideSecret = outsideDir.appendingPathComponent("secret.png")
        try validSVG.write(to: validAsset)
        try secretPNG.write(to: outsideSecret)

        let symlinkFile = docsDir.appendingPathComponent("leak.png")
        let symlinkDir = docsDir.appendingPathComponent("symdir")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: outsideSecret)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: outsideDir)

        let canonicalValidAsset = try #require(MarkdownPreviewResources.canonicalLocalPath(validAsset.path))
        let localSpy = SpyWorkspaceFilesystem(
            descriptor: .init(
                kind: .local,
                id: "local",
                displayName: "workspace",
                workingDirectory: workspaceRoot.path
            ),
            files: [canonicalValidAsset: validSVG]
        )
        let resources = MarkdownPreviewResources()
        resources.filesystem = localSpy
        resources.documentDirectory = docsDir.path
        let webView = WKWebView(frame: .zero)
        let base = MarkdownPreviewResources.imageBaseURL(directory: docsDir)

        // 1. Valid intra-workspace relative image (`../assets/ok.svg`) is allowed (HTTP 200).
        let allowedURL = try #require(URL(string: "../assets/ok.svg", relativeTo: base)?.absoluteURL)
        let allowedOutcome = await runSchemeTask(resources: resources, webView: webView, url: allowedURL)
        #expect(allowedOutcome.statusCode == 200)
        #expect(allowedOutcome.data == validSVG)
        #expect(localSpy.readPaths.count == 1)

        // 2. Out-of-bounds traversal (`../../../../etc/passwd.png`), outside directory, and symlink escapes return HTTP 403.
        let escapedURLs: [URL] = [
            try #require(URL(string: "../../../../etc/passwd.png", relativeTo: base)?.absoluteURL),
            try #require(URL(string: "../../outside/secret.png", relativeTo: base)?.absoluteURL),
            try #require(URL(string: "leak.png", relativeTo: base)?.absoluteURL),
            try #require(URL(string: "symdir/secret.png", relativeTo: base)?.absoluteURL),
            try #require(URL(string: "omg-markdown-image://document/etc/passwd.png")),
            try #require(URL(string: "omg-markdown-image://document\(docsDir.path)/../../outside/secret.png")),
            try #require(URL(string: "omg-markdown-image://document\(docsDir.path)/bad%00.png")),
        ]
        for badURL in escapedURLs {
            let outcome = await runSchemeTask(resources: resources, webView: webView, url: badURL)
            #expect(outcome.statusCode == 403, "Expected HTTP 403 for \(badURL.absoluteString)")
            #expect(outcome.data.isEmpty)
        }
        #expect(localSpy.readPaths.count == 1, "Rejected requests must never reach filesystem.readFile")

        // 3. Remote SSH workspace boundary rejects `../` escapes with HTTP 403 without reading remote files.
        let sshSpy = SpyWorkspaceFilesystem(
            descriptor: .init(
                kind: .ssh,
                id: "ssh:prod",
                displayName: "prod",
                workingDirectory: "/home/alice/project"
            ),
            files: ["/home/alice/project/assets/remote.png": secretPNG]
        )
        resources.filesystem = sshSpy
        resources.documentDirectory = "/home/alice/project/docs"
        let sshBase = MarkdownPreviewResources.imageBaseURL(directory: URL(fileURLWithPath: "/home/alice/project/docs"))

        let sshEscape = try #require(URL(string: "../../.ssh/id_ed25519.png", relativeTo: sshBase)?.absoluteURL)
        let sshEscapeOutcome = await runSchemeTask(resources: resources, webView: webView, url: sshEscape)
        #expect(sshEscapeOutcome.statusCode == 403)
        #expect(sshSpy.readPaths.isEmpty)

        let sshRawTraversal = try #require(URL(string: "omg-markdown-image://document/home/alice/project/docs/../../../etc/shadow.png"))
        let sshRawOutcome = await runSchemeTask(resources: resources, webView: webView, url: sshRawTraversal)
        #expect(sshRawOutcome.statusCode == 403)
        #expect(sshSpy.readPaths.isEmpty)

        let sshValid = try #require(URL(string: "../assets/remote.png", relativeTo: sshBase)?.absoluteURL)
        let sshValidOutcome = await runSchemeTask(resources: resources, webView: webView, url: sshValid)
        #expect(sshValidOutcome.statusCode == 200)
        #expect(sshValidOutcome.data == secretPNG)
        #expect(sshSpy.readPaths == ["/home/alice/project/assets/remote.png"])

        // 4. Standalone `.md` file when workspace root falls back to "/" scopes strictly to document parent directory.
        let standaloneSpy = SpyWorkspaceFilesystem(
            descriptor: .init(
                kind: .local,
                id: "local",
                displayName: "/",
                workingDirectory: "/"
            ),
            files: [validAsset.resolvingSymlinksInPath().path: validSVG]
        )
        resources.filesystem = standaloneSpy
        resources.documentDirectory = docsDir.path
        let siblingOutsideDocParent = try #require(URL(string: "../assets/ok.svg", relativeTo: base)?.absoluteURL)
        let standaloneEscape = await runSchemeTask(resources: resources, webView: webView, url: siblingOutsideDocParent)
        #expect(standaloneEscape.statusCode == 403)
        #expect(standaloneSpy.readPaths.isEmpty)
    }

    private func runSchemeTask(
        resources: MarkdownPreviewResources,
        webView: WKWebView,
        url: URL
    ) async -> (statusCode: Int?, data: Data, error: Error?) {
        await withCheckedContinuation { continuation in
            let task = RecordingURLSchemeTask(request: URLRequest(url: url)) { statusCode, data, error in
                continuation.resume(returning: (statusCode, data, error))
            }
            resources.webView(webView, start: task)
        }
    }
}

private final class SpyWorkspaceFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    let descriptor: WorkspaceDescriptor
    private let files: [String: Data]
    private let lock = NSLock()
    private(set) var readPaths: [String] = []

    init(descriptor: WorkspaceDescriptor, files: [String: Data]) {
        self.descriptor = descriptor
        self.files = files
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}

    func readFile(at path: String) async throws -> Data {
        lock.lock()
        readPaths.append(path)
        lock.unlock()
        guard let data = files[path] else {
            throw WorkspaceFilesystemError.unavailable
        }
        return data
    }
}

private final class RecordingURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let onComplete: (Int?, Data, Error?) -> Void
    private var statusCode: Int?
    private var received = Data()
    private var finished = false

    init(request: URLRequest, onComplete: @escaping (Int?, Data, Error?) -> Void) {
        self.request = request
        self.onComplete = onComplete
    }

    func didReceive(_ response: URLResponse) {
        statusCode = (response as? HTTPURLResponse)?.statusCode
    }

    func didReceive(_ data: Data) {
        received.append(data)
    }

    func didFinish() {
        guard !finished else { return }
        finished = true
        onComplete(statusCode, received, nil)
    }

    func didFailWithError(_ error: Error) {
        guard !finished else { return }
        finished = true
        onComplete(statusCode, received, error)
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
