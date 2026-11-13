import AppKit
import Combine
import SwiftUI
import WebKit

/// Contextual code selection emitted by Monaco's "Ask Agent / Send to Quick Input" action.
struct EditorAskAgentRequest: Equatable, Sendable {
    let path: String
    let startLine: Int?
    let endLine: Int?
    let selectedText: String
    let comment: String

    func formattedPrompt(workingDirectory: String?) -> String {
        let displayPath = Self.relativeOrFullPath(path, workingDirectory: workingDirectory)
        let lineSuffix: String
        if let startLine, startLine > 0 {
            if let endLine, endLine > startLine {
                lineSuffix = "#L\(startLine)-L\(endLine)"
            } else {
                lineSuffix = "#L\(startLine)"
            }
        } else {
            lineSuffix = ""
        }

        var parts: [String] = []
        let header = displayPath.isEmpty ? "" : "@\(displayPath)\(lineSuffix)"
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty && !trimmedComment.isEmpty {
            parts.append("\(header) \(trimmedComment)")
        } else if !header.isEmpty {
            parts.append(header)
        } else if !trimmedComment.isEmpty {
            parts.append(trimmedComment)
        }

        let trimmedSelection = selectedText.trimmingCharacters(in: .newlines)
        if !trimmedSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lang = EditorLanguageMapping.fenceLanguage(forPath: path)
            parts.append("```\(lang)\n\(trimmedSelection)\n```")
        }
        return parts.joined(separator: "\n")
    }

    static func relativeOrFullPath(_ path: String, workingDirectory: String?) -> String {
        guard !path.isEmpty else { return "" }
        guard let workingDirectory, !workingDirectory.isEmpty else { return path }
        let normalizedRoot = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalizedPath == normalizedRoot {
            return (normalizedPath as NSString).lastPathComponent
        }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        if normalizedPath.hasPrefix(prefix) {
            return String(normalizedPath.dropFirst(prefix.count))
        }
        return path
    }
}

/// Maps file paths and content prefixes to canonical Monaco / Pierre language identifiers.
enum EditorLanguageMapping {
    static func languageHint(forPath path: String?, textPrefix: String = "") -> String {
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()

            switch name {
            case "dockerfile", "containerfile": return "dockerfile"
            case "makefile", "gnumakefile": return "makefile"
            case "cmakelists.txt": return "cmake"
            case "flake.lock", "deno.lock", "bun.lock", ".prettierrc", ".eslintrc": return "json"
            case "pixi.lock", ".clang-format", ".clangd": return "yaml"
            case "cargo.lock": return "toml"
            case ".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile": return "shell"
            default: break
            }

            if name.hasPrefix("dockerfile.") { return "dockerfile" }
            if name.hasSuffix(".d.ts") { return "typescript" }

            if let mapped = extensionMap[ext] {
                return mapped
            }
        }

        let firstLine = textPrefix.prefix(256).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return "python" }
            if firstLine.contains("node") || firstLine.contains("deno") || firstLine.contains("bun") { return "javascript" }
            if firstLine.contains("nu") { return "shell" }
            if firstLine.contains("ruby") { return "ruby" }
            if firstLine.contains("sh") || firstLine.contains("bash") || firstLine.contains("zsh") { return "shell" }
        }
        return inferContentLanguage(from: textPrefix)
    }

    private static func inferContentLanguage(from textPrefix: String) -> String {
        let trimmed = textPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "plaintext" }
        if trimmed.hasPrefix("<?xml") || (trimmed.hasPrefix("<") && trimmed.contains("xmlns")) {
            return "xml"
        }
        let looksLikeJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if looksLikeJSON,
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "json"
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let first = lines.first,
           first.hasPrefix("["), first.hasSuffix("]"),
           lines.dropFirst().contains(where: { $0.contains("=") }) {
            return "toml"
        }
        let yamlKeyCount = lines.prefix(6).filter { line in
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return false }
            let key = line[..<colon]
            return !key.isEmpty && !key.contains(" ") && (colon == line.index(before: line.endIndex)
                || line[line.index(after: colon)] == " ")
        }.count
        if yamlKeyCount >= 2 || (lines.first == "---" && yamlKeyCount >= 1) {
            return "yaml"
        }
        return "plaintext"
    }

    static func fenceLanguage(forPath path: String?) -> String {
        let hint = languageHint(forPath: path)
        return hint == "plaintext" ? "" : hint
    }

    static func usesHardTabs(forPath path: String?) -> Bool {
        guard let path else { return false }
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        return name == "makefile" || name == "gnumakefile" || ext == "mk" || ext == "go"
    }

    private static let extensionMap: [String: String] = [
        "swift": "swift",
        "zig": "zig",
        "zon": "zig",
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "tsx",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "jsx",
        "py": "python",
        "pyi": "python",
        "rs": "rust",
        "go": "go",
        "c": "c",
        "h": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "m": "objective-c",
        "mm": "objective-cpp",
        "json": "json",
        "jsonc": "json",
        "geojson": "json",
        "yml": "yaml",
        "yaml": "yaml",
        "toml": "toml",
        "md": "markdown",
        "markdown": "markdown",
        "mdx": "markdown",
        "html": "html",
        "htm": "html",
        "xml": "xml",
        "xsd": "xml",
        "svg": "xml",
        "plist": "xml",
        "xib": "xml",
        "storyboard": "xml",
        "xcscheme": "xml",
        "entitlements": "xml",
        "css": "css",
        "scss": "scss",
        "less": "less",
        "sh": "shell",
        "bash": "shell",
        "zsh": "shell",
        "fish": "shell",
        "nu": "shell",
        "sql": "sql",
        "rb": "ruby",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "lua": "lua",
        "cs": "csharp",
        "php": "php",
        "r": "r",
        "dart": "dart",
        "scala": "scala",
        "graphql": "graphql",
        "gql": "graphql",
        "proto": "protobuf",
        "ini": "ini",
        "conf": "ini",
        "cfg": "ini",
        "ghostty": "ini",
        "diff": "diff",
        "patch": "diff"
    ]
}

extension EditorFontFamily {
    var monacoCSSFontStack: String {
        switch self {
        case .jetbrainsMono:
            return "'JetBrains Mono', 'JetBrainsMono-Regular', ui-monospace, SFMono-Regular, Menlo, monospace"
        case .sfMono:
            return "'SF Mono', SFMono-Regular, ui-monospace, Menlo, monospace"
        case .menlo:
            return "Menlo, 'Menlo-Regular', ui-monospace, monospace"
        case .firaCode:
            return "'Fira Code', 'FiraCode-Regular', ui-monospace, Menlo, monospace"
        case .system:
            return "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace"
        }
    }

    var prefersLigatures: Bool {
        switch self {
        case .jetbrainsMono, .firaCode: true
        case .sfMono, .menlo, .system: false
        }
    }
}

/// Custom URL scheme handler serving bundled Monaco + Pierre offline assets with zero network access.
final class MonacoEditorResources: NSObject, WKURLSchemeHandler {
    static let scheme = "omg-editor"
    static let entryURL = URL(string: "omg-editor://bundle/index.html")!

    private let customRootURL: URL?

    init(customRootURL: URL? = nil) {
        self.customRootURL = customRootURL
        super.init()
    }

    static func resolveRootDirectory() -> URL? {
        if let bundled = Bundle.main.url(forResource: "CodeEditor", withExtension: nil) {
            return bundled
        }
        if let testBundled = Bundle(for: MonacoEditorResources.self).url(forResource: "CodeEditor", withExtension: nil) {
            return testBundled
        }
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CodeEditor", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceFallback.path) {
            return sourceFallback
        }
        return nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == Self.scheme else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        if url.host == "bundle" {
            serveBundledAsset(url: url, task: urlSchemeTask)
            return
        }
        urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func serveBundledAsset(url: URL, task: any WKURLSchemeTask) {
        let relativePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetSubpath = relativePath.isEmpty ? "index.html" : relativePath

        guard let rawRoot = customRootURL ?? Self.resolveRootDirectory() else {
            if targetSubpath == "index.html" {
                serveFallbackShell(url: url, task: task)
                return
            }
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(targetSubpath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(forExtension: file.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func serveFallbackShell(url: URL, task: any WKURLSchemeTask) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:transparent;}
        </style></head><body><script>
        window.omgEditor={
          models:{},activeUri:null,
          openOrUpdateModel(p){this.models[p.uri]=p;},
          activateModel(p){this.activeUri=p.uri;},
          closeModel(p){delete this.models[p.uri];},
          revealRange(){},activateDiff(){},navigateDiff(){},
          setTheme(){},setFont(){},setGitDiffLines(){},setDiagnostics(){},
          performAction(){},resolveRequest(){}
        };
        window.webkit?.messageHandlers?.codeEditor?.postMessage({type:'ready'});
        </script></body></html>
        """
        let data = Data(html.utf8)
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "ttf": "font/ttf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "wasm": "application/wasm"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}

/// Weak wrapper avoiding the `WKUserContentController` -> `WKScriptMessageHandler` retain cycle.
private final class WeakEditorScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Transparent `WKWebView` surface layered directly over `EditorBackdrop`.
final class MonacoEditorWebView: WKWebView {
    var onFocus: (() -> Void)?
    var interceptsKeystrokeForEditor: ((NSEvent) -> Bool)?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        wantsLayer = true
        clearBackgrounds()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let responder = window?.firstResponder
        let isFocused = responder === self || (responder as? NSView)?.isDescendant(of: self) == true
        if isFocused, super.performKeyEquivalent(with: event) {
            return true
        }
        if isFocused, interceptsKeystrokeForEditor?(event) == true {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearBackgrounds()
    }

    override func layout() {
        super.layout()
        clearBackgrounds()
    }

    override func updateLayer() {
        super.updateLayer()
        clearBackgrounds()
    }

    /// WebKit recreates internal `NSScrollView` and `NSClipView` children across page loads
    /// and appearance transitions; keep every layer clear over `EditorBackdrop`.
    func clearBackgrounds() {
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        layer?.backgroundColor = NSColor.clear.cgColor
        Self.clearSubviewBackgrounds(in: self)
    }

    private static func clearSubviewBackgrounds(in root: NSView) {
        for child in root.subviews {
            if let scrollView = child as? NSScrollView {
                scrollView.drawsBackground = false
                scrollView.backgroundColor = .clear
            }
            if let clipView = child as? NSClipView {
                clipView.drawsBackground = false
                clipView.backgroundColor = .clear
            }
            clearSubviewBackgrounds(in: child)
        }
    }
}

/// Shared Monaco + Pierre workbench controller.
///
/// One `MonacoWorkbenchController` is owned per `EditorWorkspace` so switching between
/// open tabs swaps Monaco `ITextModel`s in <1ms inside a single pooled `WKWebView`.
@MainActor
final class MonacoWorkbenchController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let messageHandlerName = "codeEditor"

    struct ModelSnapshot: Equatable {
        var uri: String
        var path: String
        var text: String
        var languageHint: String
        var readOnly: Bool
    }

    struct ActiveDiffSnapshot: Equatable {
        var id: String
        var path: String
        var originalText: String
        var modifiedText: String
        var inline: Bool
        var wordWrap: Bool
        var readOnly: Bool
    }

    @Published private(set) var isReady = false
    private(set) var webView: MonacoEditorWebView?
    private(set) var activeURI: String?
    private(set) var activeDiff: ActiveDiffSnapshot?
    private(set) var openModels: [String: ModelSnapshot] = [:]

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updateCommandRegistration()
        }
    }
    var isPreview = false
    var keymap = EditorKeymap.idea
    var isSurfaceFocused: () -> Bool = { true }

    var onFocus: (() -> Void)?
    var onTextChange: ((String, String) -> Void)?
    var onCommand: ((EditorAction) -> Bool)?
    var onAskAgent: ((EditorAskAgentRequest) -> Void)?
    var onNavigateDefinition: ((String, EditorTextLocation) -> Void)?
    var onOpenExternalURL: ((URL) -> Void)?
    var onLSPRequest: ((
        _ method: String,
        _ uri: String,
        _ path: String,
        _ line: Int,
        _ column: Int,
        _ triggerCharacter: String?
    ) async -> Any?)?

    private var pendingCalls: [String] = []
    private var suppressEchoURIs: Set<String> = []
    private var lastThemePayloadJSON: String?
    private var lastFontPayloadJSON: String?
    private var cachedGitDiffLines: [String: [String: String]] = [:]
    private var cachedDiagnostics: [String: [[String: Any]]] = [:]
    private var isTornDown = false
    private let customResourceRootURL: URL?

    init(customResourceRootURL: URL? = nil) {
        self.customResourceRootURL = customResourceRootURL
        super.init()
    }

    deinit {
        let view = webView
        MainActor.assumeIsolated {
            EditorCommandRouter.shared.unregister(owner: self)
            view?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        }
    }

    @discardableResult
    func ensureWebView() -> MonacoEditorWebView {
        if let webView {
            return webView
        }
        isTornDown = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            MonacoEditorResources(customRootURL: customResourceRootURL),
            forURLScheme: MonacoEditorResources.scheme
        )
        let contentController = WKUserContentController()
        contentController.add(
            WeakEditorScriptMessageHandler(target: self),
            name: Self.messageHandlerName
        )
        configuration.userContentController = contentController

        let created = MonacoEditorWebView(frame: .zero, configuration: configuration)
        created.navigationDelegate = self
        created.onFocus = { [weak self] in
            self?.onFocus?()
        }
        created.interceptsKeystrokeForEditor = { [weak self] event in
            guard let self else { return false }
            return self.shouldKeepKeystrokeInMonaco(event)
        }
        created.clearBackgrounds()
        self.webView = created
        updateCommandRegistration()
        created.load(URLRequest(url: MonacoEditorResources.entryURL))
        return created
    }

    func preloadIfNeeded() {
        guard webView == nil, !isTornDown else { return }
        _ = ensureWebView()
    }

    func tearDown() {
        isTornDown = true
        isReady = false
        pendingCalls.removeAll()
        openModels.removeAll()
        cachedGitDiffLines.removeAll()
        cachedDiagnostics.removeAll()
        activeURI = nil
        activeDiff = nil
        lastThemePayloadJSON = nil
        lastFontPayloadJSON = nil
        EditorCommandRouter.shared.unregister(owner: self)
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.onFocus = nil
            webView.interceptsKeystrokeForEditor = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
            webView.removeFromSuperview()
            self.webView = nil
        }
    }

    func focus() {
        guard let webView, let window = webView.window else { return }
        _ = window.makeFirstResponder(webView)
        enqueueOrEvaluate("window.omgEditor?._internal?.editor?.focus?.();")
    }

    // MARK: - Inbound JS Bridge (`window.omgEditor`)

    func openOrUpdateModel(
        uri: String,
        path: String,
        text: String,
        languageHint: String? = nil,
        readOnly: Bool = false,
        preserveView: Bool = true
    ) {
        let resolvedLanguage = languageHint ?? EditorLanguageMapping.languageHint(
            forPath: path,
            textPrefix: String(text.prefix(512))
        )
        let snapshot = ModelSnapshot(
            uri: uri,
            path: path,
            text: text,
            languageHint: resolvedLanguage,
            readOnly: readOnly
        )
        if suppressEchoURIs.contains(uri), openModels[uri]?.text == text {
            return
        }
        if openModels[uri] == snapshot, isReady {
            return
        }
        openModels[uri] = snapshot
        sendCall("openOrUpdateModel", payload: [
            "uri": uri,
            "path": path,
            "text": text,
            "languageHint": resolvedLanguage,
            "readOnly": readOnly,
            "preserveView": preserveView
        ])
    }

    func activateModel(
        uri: String,
        readOnly: Bool,
        wordWrap: Bool,
        tabSize: Int,
        insertSpaces: Bool,
        keymapProfile: EditorKeymap.Profile
    ) {
        activeDiff = nil
        activeURI = uri
        sendCall("activateModel", payload: [
            "uri": uri,
            "readOnly": readOnly,
            "wordWrap": wordWrap,
            "tabSize": max(1, tabSize),
            "insertSpaces": insertSpaces,
            "keymapProfile": keymapProfile.rawValue
        ])
        if let lines = cachedGitDiffLines[uri] {
            sendCall("setGitDiffLines", payload: ["uri": uri, "lines": lines])
        }
        if let markers = cachedDiagnostics[uri] {
            sendCall("setDiagnostics", payload: ["uri": uri, "markers": markers])
        }
    }

    func closeModel(uri: String) {
        openModels.removeValue(forKey: uri)
        cachedGitDiffLines.removeValue(forKey: uri)
        cachedDiagnostics.removeValue(forKey: uri)
        if activeURI == uri {
            activeURI = nil
        }
        sendCall("closeModel", payload: ["uri": uri])
    }

    func revealRange(
        uri: String,
        startLine: Int,
        startColumn: Int = 1,
        endLine: Int? = nil,
        endColumn: Int? = nil
    ) {
        var payload: [String: Any] = [
            "uri": uri,
            "startLine": max(1, startLine),
            "startColumn": max(1, startColumn)
        ]
        if let endLine {
            payload["endLine"] = max(1, endLine)
        }
        if let endColumn {
            payload["endColumn"] = max(1, endColumn)
        }
        sendCall("revealRange", payload: payload)
    }

    func revealLocation(_ location: EditorTextLocation, in uri: String) {
        revealRange(
            uri: uri,
            startLine: location.startLine,
            startColumn: location.column ?? 1,
            endLine: location.endLine
        )
    }

    func activateDiff(
        id: String,
        path: String,
        originalText: String,
        modifiedText: String,
        inline: Bool,
        wordWrap: Bool,
        readOnly: Bool = true
    ) {
        let snapshot = ActiveDiffSnapshot(
            id: id,
            path: path,
            originalText: originalText,
            modifiedText: modifiedText,
            inline: inline,
            wordWrap: wordWrap,
            readOnly: readOnly
        )
        activeURI = nil
        activeDiff = snapshot
        sendCall("activateDiff", payload: [
            "id": id,
            "path": path,
            "originalText": originalText,
            "modifiedText": modifiedText,
            "inline": inline,
            "wordWrap": wordWrap,
            "readOnly": readOnly
        ])
    }

    func navigateDiff(direction: String) {
        sendCall("navigateDiff", payload: ["direction": direction])
    }

    func setTheme(_ theme: EditorTheme, isDark: Bool) {
        let payload = theme.monacoThemePayload(isDark: isDark)
        guard let json = Self.encodeJSON(payload), json != lastThemePayloadJSON else { return }
        lastThemePayloadJSON = json
        enqueueOrEvaluate("window.omgEditor?.setTheme?.(\(json));")
    }

    func setFont(family: EditorFontFamily, size: Double, ligatures: Bool? = nil) {
        let payload: [String: Any] = [
            "family": family.monacoCSSFontStack,
            "size": size,
            "ligatures": ligatures ?? family.prefersLigatures
        ]
        guard let json = Self.encodeJSON(payload), json != lastFontPayloadJSON else { return }
        lastFontPayloadJSON = json
        enqueueOrEvaluate("window.omgEditor?.setFont?.(\(json));")
    }

    func setGitDiffLines(uri: String, lines: [String: String]) {
        if cachedGitDiffLines[uri] == lines, isReady {
            return
        }
        cachedGitDiffLines[uri] = lines
        sendCall("setGitDiffLines", payload: [
            "uri": uri,
            "lines": lines
        ])
    }

    func setDiffHighlightMap(uri: String, zeroBasedHighlights: [Int: Bool]) {
        var mapped: [String: String] = [:]
        mapped.reserveCapacity(zeroBasedHighlights.count)
        for (zeroIndex, isAdded) in zeroBasedHighlights where zeroIndex >= 0 {
            mapped[String(zeroIndex + 1)] = isAdded ? "added" : "deleted"
        }
        setGitDiffLines(uri: uri, lines: mapped)
    }

    func setDiagnostics(uri: String, markers: [[String: Any]]) {
        cachedDiagnostics[uri] = markers
        sendCall("setDiagnostics", payload: [
            "uri": uri,
            "markers": markers
        ])
    }

    func performEditorAction(_ action: String) {
        sendCall("performAction", payload: ["action": action])
    }

    func resolveRequest(requestId: Any, payload: Any?) {
        let idJSON: String
        if let stringID = requestId as? String {
            idJSON = Self.encodeJSONStringLiteral(stringID)
        } else if let numberID = requestId as? NSNumber {
            idJSON = numberID.stringValue
        } else {
            return
        }
        let payloadJSON: String
        if let payload, JSONSerialization.isValidJSONObject(["v": payload]),
           let wrapped = Self.encodeJSON(["v": payload]) {
            // Unwrap `"v"` on the JS side so primitives, arrays, and objects serialize safely.
            payloadJSON = "(\(wrapped)).v"
        } else {
            payloadJSON = "null"
        }
        enqueueOrEvaluate("window.omgEditor?.resolveRequest?.(\(idJSON), \(payloadJSON));")
    }

    func evaluateJavaScriptForTesting(_ script: String) async throws -> Any? {
        let view = ensureWebView()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            view.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == MonacoEditorResources.scheme {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            handleExternalLink(url.absoluteString)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        (webView as? MonacoEditorWebView)?.clearBackgrounds()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        handleOutboundMessage(type: type, body: body)
    }

    func handleOutboundMessage(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            isReady = true
            webView?.clearBackgrounds()
            let queued = pendingCalls
            pendingCalls.removeAll()
            for script in queued {
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }

        case "focus":
            onFocus?()

        case "didChangeContent":
            guard let rawURI = body["uri"] as? String,
                  let text = body["text"] as? String else { return }
            let uri = canonicalModelURI(uri: rawURI, path: body["path"] as? String)
            if openModels[uri] != nil {
                openModels[uri]?.text = text
            }
            suppressEchoURIs.insert(uri)
            onTextChange?(uri, text)
            suppressEchoURIs.remove(uri)

        case "hostCommand":
            guard let raw = body["command"] as? String,
                  let action = Self.hostAction(forCommand: raw) else { return }
            _ = onCommand?(action)

        case "openLink":
            guard let href = body["href"] as? String else { return }
            handleExternalLink(href)

        case "askAgent":
            let rawURI = (body["uri"] as? String) ?? ""
            let uri = canonicalModelURI(uri: rawURI, path: body["path"] as? String)
            let path = (body["path"] as? String) ?? openModels[uri]?.path ?? ""
            let startLine = body["startLine"] as? Int
            let endLine = body["endLine"] as? Int
            let selectedText = (body["selectedText"] as? String) ?? ""
            let comment = (body["comment"] as? String) ?? ""
            onAskAgent?(EditorAskAgentRequest(
                path: path,
                startLine: startLine,
                endLine: endLine,
                selectedText: selectedText,
                comment: comment
            ))

        case "lspRequest":
            guard let requestId = body["requestId"],
                  let method = body["method"] as? String else { return }
            let rawURI = (body["uri"] as? String) ?? activeURI ?? ""
            let uri = canonicalModelURI(uri: rawURI, path: body["path"] as? String)
            let path = (body["path"] as? String) ?? openModels[uri]?.path ?? ""
            let line = (body["line"] as? Int) ?? 1
            let column = (body["column"] as? Int) ?? 1
            let triggerCharacter = body["triggerCharacter"] as? String
            guard let onLSPRequest else {
                resolveRequest(requestId: requestId, payload: nil)
                return
            }
            Task { @MainActor [weak self] in
                let response = await onLSPRequest(method, uri, path, line, column, triggerCharacter)
                self?.resolveRequest(requestId: requestId, payload: response)
            }

        case "navigateDefinition":
            guard let target = body["target"] as? [String: Any],
                  let path = target["path"] as? String, !path.isEmpty else { return }
            let startLine = max(1, (target["startLine"] as? Int) ?? 1)
            let startColumn = (target["startColumn"] as? Int) ?? 1
            let endLine = target["endLine"] as? Int
            onNavigateDefinition?(
                path,
                EditorTextLocation(startLine: startLine, column: startColumn, endLine: endLine)
            )

        default:
            break
        }
    }

    // MARK: - Command Routing

    private func updateCommandRegistration() {
        if isActive {
            EditorCommandRouter.shared.register(owner: self) { [weak self] event in
                self?.handleKeyEvent(event) ?? false
            }
        } else {
            EditorCommandRouter.shared.unregister(owner: self)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isActive, let webView, webView.window != nil, event.window === webView.window else {
            return false
        }

        if isPreview {
            guard isSurfaceFocused(), let action = keymap.action(for: event) else { return false }
            switch action {
            case .close, .open, .nextDocument, .previousDocument, .hide:
                return onCommand?(action) ?? false
            default:
                return false
            }
        }

        let responder = webView.window?.firstResponder
        let isFocusedInWebView = responder === webView
            || (responder as? NSView)?.isDescendant(of: webView) == true
        guard isFocusedInWebView else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 53, modifiers == .shift {
            return onCommand?(.hide) ?? false
        }

        guard let action = keymap.action(for: event) else { return false }
        switch action {
        case .save, .saveAll, .close, .open, .nextDocument, .previousDocument, .hide:
            return onCommand?(action) ?? false
        case .find:
            performEditorAction("find")
            return true
        case .replace:
            performEditorAction("replace")
            return true
        case .goToLine:
            performEditorAction("goToLine")
            return true
        case .findNext:
            performEditorAction("findNext")
            return true
        case .findPrevious:
            performEditorAction("findPrev")
            return true
        case .documentSymbols:
            performEditorAction("documentSymbols")
            return true
        case .cut:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: webView)
        case .copy:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: webView)
        case .paste:
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: webView)
        case .selectAll:
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: webView)
        default:
            return false
        }
    }

    private func shouldKeepKeystrokeInMonaco(_ event: NSEvent) -> Bool {
        // Prevent terminal menu items (e.g. Cmd+D Split Right) from stealing editor keystrokes.
        guard keymap.action(for: event) != nil else { return false }
        return true
    }

    private func handleExternalLink(_ href: String) {
        if href.hasPrefix("/"), let onNavigateDefinition {
            onNavigateDefinition(href, EditorTextLocation(startLine: 1))
            return
        }
        guard let url = URL(string: href),
              let scheme = url.scheme?.lowercased() else { return }
        if scheme == "file" {
            onNavigateDefinition?(url.path, EditorTextLocation(startLine: 1))
            return
        }
        guard ["http", "https", "mailto"].contains(scheme) else { return }
        if let onOpenExternalURL {
            onOpenExternalURL(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func canonicalModelURI(uri: String, path: String?) -> String {
        if openModels[uri] != nil {
            return uri
        }
        if let path, !path.isEmpty,
           let match = openModels.values.first(where: { $0.path == path }) {
            return match.uri
        }
        return uri
    }

    private static func hostAction(forCommand command: String) -> EditorAction? {
        switch command {
        case "save": .save
        case "saveAll": .saveAll
        case "close": .close
        case "open": .open
        case "nextDocument": .nextDocument
        case "previousDocument": .previousDocument
        case "hide": .hide
        default: nil
        }
    }

    // MARK: - Script Queueing & JSON Serialization

    private func sendCall(_ method: String, payload: [String: Any]) {
        guard let json = Self.encodeJSON(payload) else { return }
        enqueueOrEvaluate("window.omgEditor?.\(method)?.(\(json));")
    }

    private func enqueueOrEvaluate(_ script: String) {
        _ = ensureWebView()
        if isReady {
            webView?.evaluateJavaScript(script, completionHandler: nil)
        } else {
            pendingCalls.append(script)
        }
    }

    private static func encodeJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeJSONStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayJSON = String(data: data, encoding: .utf8),
              arrayJSON.count >= 2 else {
            return "\"\""
        }
        return String(arrayJSON.dropFirst().dropLast())
    }
}

/// Hosts a `MonacoWorkbenchController`'s single `MonacoEditorWebView` inside SwiftUI
/// without recreating the underlying `WKWebView` across tab or document switches.
struct MonacoWorkbenchSurface: NSViewRepresentable {
    @ObservedObject var controller: MonacoWorkbenchController

    final class ContainerView: NSView {
        override var isOpaque: Bool { false }

        func mount(_ webView: MonacoEditorWebView) {
            guard webView.superview !== self else {
                webView.clearBackgrounds()
                return
            }
            webView.removeFromSuperview()
            subviews.forEach { $0.removeFromSuperview() }
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            webView.clearBackgrounds()
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.mount(controller.ensureWebView())
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.mount(controller.ensureWebView())
    }
}
