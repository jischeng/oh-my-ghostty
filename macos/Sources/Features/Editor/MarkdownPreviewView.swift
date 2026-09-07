import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The bundled renderer shares one filesystem boundary with the native editor.
struct MarkdownPreviewView: NSViewRepresentable {
    let text: String
    let fileURL: URL?
    var isRemote: Bool = false
    var filesystem: (any WorkspaceFilesystem)?
    let terminalBackground: NSColor
    let foregroundColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: "omg-markdown")
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: "omg-markdown-image")
        configuration.userContentController.add(context.coordinator, name: "markdownPreview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.wantsLayer = true
        view.layer?.backgroundColor = terminalBackground.cgColor
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.update(self)
        view.load(URLRequest(url: URL(string: "omg-markdown://bundle/template.html")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.renderTask?.cancel()
        coordinator.resources.cancelAll()
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdownPreview")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let resources = MarkdownPreviewResources()
        weak var webView: WKWebView?
        var renderTask: Task<Void, Never>?
        private var ready = false
        private var payload: String?

        func update(_ preview: MarkdownPreviewView) {
            let directory = preview.fileURL?.deletingLastPathComponent()
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            // Never fall back to the local host for a disconnected SSH document.
            resources.filesystem = preview.filesystem ?? (preview.isRemote
                ? nil : LocalWorkspaceFilesystem(workingDirectory: directory.path))
            let background = preview.terminalBackground.usingColorSpace(.deviceRGB) ?? .black
            let luminance = 0.2126 * background.redComponent
                + 0.7152 * background.greenComponent + 0.0722 * background.blueComponent
            let value: [String: Any] = [
                "text": preview.text,
                "options": [
                    "baseURL": MarkdownPreviewResources.imageBaseURL(directory: directory).absoluteString,
                    "theme": luminance < 0.5 ? "dark" : "light",
                    // The host already paints the shared terminal backdrop.
                    "background": "transparent",
                    "foreground": Self.cssColor(preview.foregroundColor),
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let nextPayload = String(data: data, encoding: .utf8), nextPayload != payload else { return }
            payload = nextPayload
            scheduleRender()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: String], body["type"] == "ready" else { return }
            ready = true
            scheduleRender()
        }

        private func scheduleRender() {
            renderTask?.cancel()
            guard ready, let payload else { return }
            renderTask = Task { [weak self] in
                // Coalesce autosave/editor updates while typing.
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { return }
                self.webView?.evaluateJavaScript(
                    "(() => { const p = \(payload); window.renderMarkdown(p.text, p.options); })();",
                    completionHandler: nil
                )
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "omg-markdown", url.host == "bundle", url.path == "/template.html" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }

        private static func cssColor(_ color: NSColor, alpha: Double? = nil) -> String {
            let rgb = color.usingColorSpace(.deviceRGB) ?? .white
            return "rgba(\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),"
                + "\(Int(rgb.blueComponent * 255)),\(alpha ?? Double(rgb.alphaComponent)))"
        }
    }
}

/// Web content can request bundled assets and images, never arbitrary document scripts.
@MainActor
final class MarkdownPreviewResources: NSObject, WKURLSchemeHandler {
    var filesystem: (any WorkspaceFilesystem)?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func imageBaseURL(directory: URL) -> URL {
        var components = URLComponents()
        components.scheme = "omg-markdown-image"
        components.host = "document"
        components.path = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return components.url!
    }

    static func imageMIMEType(for url: URL) -> String? {
        guard url.scheme == "omg-markdown-image", url.host == "document",
              let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        return type.preferredMIMEType
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let filesystem = filesystem
        tasks[id] = Task { [weak self] in
            do {
                guard let url = urlSchemeTask.request.url else { throw URLError(.badURL) }
                let data: Data
                let mimeType: String
                if url.scheme == "omg-markdown", url.host == "bundle" {
                    guard let root = Bundle.main.url(forResource: "MarkdownPreview", withExtension: nil) else {
                        throw URLError(.fileDoesNotExist)
                    }
                    let file = root.appendingPathComponent(url.path).standardizedFileURL
                    guard file.path.hasPrefix(root.path + "/") else { throw URLError(.noPermissionsToReadFile) }
                    data = try await Task.detached(priority: .utility) { try Data(contentsOf: file) }.value
                    mimeType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                } else {
                    guard let imageType = Self.imageMIMEType(for: url), let filesystem else {
                        throw URLError(.unsupportedURL)
                    }
                    mimeType = imageType
                    data = try await filesystem.readFile(at: url.path)
                }
                guard !Task.isCancelled else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType,
                    expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
            self?.tasks.removeValue(forKey: id)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
