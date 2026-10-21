import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct EditorAppearanceTests {
    @Test func translucentBackdropCannotPaintAcrossPaneBoundariesAfterMoving() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        let terminal = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = NSColor.white.cgColor
        container.addSubview(terminal)
        let backdrop = EditorBackdrop.BackdropView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        backdrop.fillColor = NSColor.black.withAlphaComponent(0.5)
        container.addSubview(backdrop)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }

        // Repeated swaps and resizes must not accumulate alpha or tint the
        // neighbouring terminal, even when damage extends outside this pane.
        for origin in [0.0, 200.0, 0.0, 200.0] {
            backdrop.frame = NSRect(x: origin, y: 0, width: 200, height: 200)
            backdrop.setNeedsDisplay(NSRect(x: -400, y: -200, width: 1200, height: 600))
            container.layoutSubtreeIfNeeded()
            let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / container.bounds.width
            let neighbourX = origin == 0 ? 300.0 : 100.0
            let neighbour = try #require(bitmap.colorAt(x: Int(neighbourX * scale), y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB))
            let editor = try #require(bitmap.colorAt(x: Int((origin + 100) * scale), y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB))
            #expect(neighbour.redComponent > 0.95)
            #expect(editor.redComponent > 0.4 && editor.redComponent < 0.8)
        }
    }

    @Test func nativePythonEditorPaintsFunctionAndTypeColors() async throws {
        let source = "from .quantize import QuantizedWeights\n\ndef grouped_expert_linear(x: QuantizedWeights, enabled: bool = False):\n    return str(x)\n# bool\nlabel = \"False\"\n"
        let host = NSHostingController(rootView: CodeEditorView(
            text: .constant(source), fileURL: URL(fileURLWithPath: "/moe.py"), terminalTheme: .oneDark
        ).frame(width: 700, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        defer { window.close() }
        func findTextView(_ view: NSView) -> TextView? {
            if let text = view as? TextView { return text }
            return view.subviews.lazy.compactMap { findTextView($0) }.first
        }
        let textView = try #require(findTextView(host.view))
        try await Task.sleep(for: .milliseconds(300))
        func color(_ word: String) -> NSColor? {
            textView.textStorage.attribute(.foregroundColor, at: (source as NSString).range(of: word).location,
                                           effectiveRange: nil) as? NSColor
        }
        // EditorTheme stores text styles as `Attribute`; compare resolved colors.
        #expect(color("grouped_expert_linear") == EditorTheme.oneDark.commands.color)
        #expect(color("QuantizedWeights") == EditorTheme.oneDark.types.color)
        #expect(color("bool") == EditorTheme.oneDark.commands.color)
        #expect(color("False") == EditorTheme.oneDark.numbers.color)
        let quoted = (source as NSString).range(of: "\"False\"")
        #expect(textView.textStorage.attribute(.foregroundColor, at: quoted.location + 1,
                                               effectiveRange: nil) as? NSColor == EditorTheme.oneDark.strings.color)
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/omg-python-highlight-acceptance.png")
        )
    }

    @Test func pythonHighlightSeparatesFunctionsTypesAndVariables() async throws {
        let source = "class TinyCache:\n    def update(self, value: int):\n        self.key = value\n"
        let textView = TextView(string: source)
        let provider = EditorSyntaxHighlightProvider()
        provider.setUp(textView: textView, codeLanguage: .python)
        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: source.utf16.count)) {
                continuation.resume(with: $0)
            }
        }
        func captures(_ word: String) -> [CaptureName?] {
            let range = (source as NSString).range(of: word)
            return highlights.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.capture)
        }
        #expect(captures("update").contains(.typeAlternate))
        #expect(captures("TinyCache").contains(.type))
        let theme = EditorSyntaxHighlightProvider.renderTheme(.oneDark)
        #expect(theme.attributes == EditorTheme.oneDark.commands)
        #expect(theme.variables == theme.text)
        #expect(theme.attributes != theme.variables)
        #expect(theme.types != theme.attributes)
    }

    @Test func appearanceSettingsPersistIndependentValuesWithoutChangingOMG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: file)
        #expect(settings.editorSettings.followsOMG)
        #expect(settings.editorAutoClosePairs)
        settings.editorAutoClosePairs = false
        settings.editorThemeName = "Catppuccin Mocha"
        #expect(!settings.editorSettings.followsOMG)
        settings.editorThemeName = nil
        settings.editorSyntaxTheme = .dracula
        settings.editorOpacity = 0.6
        settings.editorBlur = .macosGlassClear
        #expect(settings.backgroundOpacityOverride == nil)
        settings.editorSyntaxTheme = .followTerminal
        let restored = OhMyGhosttySettings(fileURL: file)
        #expect(restored.editorSettings.followsOMG)
        #expect(!restored.editorAutoClosePairs)
        #expect(restored.editorOpacity == 0.6)
        #expect(restored.editorBlur == .macosGlassClear)
    }

    @Test func editorPaletteUsesResolvedGhosttyColors() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("editor-colors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try "background = 123456\nforeground = abcdef\npalette = 5=#aabbcc\n".write(to: file, atomically: true, encoding: .utf8)
        let config = Ghostty.Config(at: file.path)
        let theme = config.editorTheme(background: NSColor(config.backgroundColor))
        let text = try #require(theme.text.color.usingColorSpace(.deviceRGB))
        let keyword = try #require(theme.keywords.color.usingColorSpace(.deviceRGB))
        #expect(abs(text.redComponent - 171.0 / 255) < 0.01)
        #expect(abs(keyword.blueComponent - 204.0 / 255) < 0.01)
    }

    @Test func namedCatalogThemeIncludesSyntaxAndBackground() throws {
        let themes = GhosttyThemeCatalog.availableThemes()
        #expect(themes.count > 50)
        let theme = try #require(EditorCatalogThemes.shared.theme(named: "Catppuccin Mocha"))
        #expect(theme.background.alphaComponent == 1)
        #expect(theme.strings != theme.keywords)
        #expect(theme.text.color != theme.background)
    }

    @Test func settingsWindowHandlesCommandW() throws {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
        #expect(!window.isVisible)
    }

    @Test func followingOMGReusesWindowBlurInsteadOfAddingSystemMaterial() {
        let following = EditorBackdrop(color: .blue, opacity: 0.85, blur: .enabled, usesWindowBlur: true)
        #expect(following.localEffect == .disabled)
        let independent = EditorBackdrop(color: .blue, opacity: 0.85, blur: .enabled)
        #expect(independent.localEffect == .enabled)
        let glass = EditorBackdrop(color: .blue, opacity: 0.85, blur: .macosGlassRegular, usesWindowBlur: true)
        #expect(glass.localEffect == .macosGlassRegular)
    }

    @Test func nativeEditorRendersOneSharedBackdrop() async throws {
        let color = NSColor(red: 0.12, green: 0.24, blue: 0.36, alpha: 1)
        var theme = EditorTheme.adaptive(background: color, foreground: .white)
        theme.background = EditorTheme.transparentBackground
        let coordinator = EditorCoordinator()
        let editor = EditorTestSupport.editor(
            text: .constant("from pathlib import Path\n\nprint(\"Hello\")\n"),
            language: .python,
            configuration: EditorTestSupport.configuration(theme: theme, fontSize: 14),
            coordinators: [coordinator]
        )
        let host = NSHostingController(rootView: editor.background(EditorBackdrop(color: color, opacity: 1, blur: .disabled)).frame(width: 860, height: 520))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        // cacheDisplay can produce Display P3 pixels, while colorAt labels its
        // components NSCalibratedRGB. Converting that mislabeled color to deviceRGB
        // changes valid P3 values a second time. Compare in the bitmap's actual ICC space.
        let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh / 2))
        let expected = try #require(color.usingColorSpace(bitmap.colorSpace))
        #expect(abs(pixel.redComponent - expected.redComponent) < 0.04)
        #expect(abs(pixel.greenComponent - expected.greenComponent) < 0.04)
        #expect(abs(pixel.blueComponent - expected.blueComponent) < 0.04)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/omg-editor-theme.png"))
        coordinator.destroy()
        window.close()
    }

    @Test func renderAppearanceAndEditorSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        for tab in [OhMyGhosttySettingsTab.appearance, .editor] {
            let host = NSHostingController(rootView: SettingsView(settings: settings, initialSelection: tab).frame(width: 1000, height: 920))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 920),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            host.view.setFrameSize(NSSize(width: 1000, height: 920))
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/omg-settings-\(tab.rawValue).png"))
            #expect(bitmap.pixelsWide > 0)
            window.close()
        }
    }

    private struct PasteEditorHost: View {
        @State var text: String

        var body: some View {
            CodeEditorView(text: $text, fileURL: URL(fileURLWithPath: "/models.json"), terminalTheme: .oneDark)
        }
    }

    @Test func multilinePasteRecoversViewportAfterSuppressedScrollNotification() async throws {
        let lines = (0..<400).map { "  \"model_\($0)\": { \"contextWindow\": 1050000 }," }
        let host = NSHostingView(rootView: PasteEditorHost(text: "{\n" + lines.joined(separator: "\n") + "\n}"))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        func find(_ view: NSView) -> TextView? { (view as? TextView) ?? view.subviews.lazy.compactMap(find).first }
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(find(host))
        let clip = try #require(editor.enclosingScrollView?.contentView)
        let selection = (editor.string as NSString).range(of: "model_28")
        editor.selectionManager.setSelectedRange(NSRange(location: selection.location, length: 0))
        // CodeEdit's paste(_:) forwards clipboard text to insertText(_:replacementRange:).
        editor.insertText("\"copied\": 1,\n\"pasted\": 2,\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let oldPosts = clip.postsBoundsChangedNotifications
        clip.postsBoundsChangedNotifications = false
        clip.scroll(to: .init(x: 0, y: 4000))
        editor.enclosingScrollView?.reflectScrolledClipView(clip)
        clip.postsBoundsChangedNotifications = oldPosts
        try await Task.sleep(for: .milliseconds(80))

        #expect(editor.string.contains("\"pasted\": 2"))
        #expect(editor.layoutManager.textLineForOffset(editor.textStorage.length - 1) != nil)
        #expect(!editor.subviews.filter { String(describing: type(of: $0)) == "LineFragmentView" && editor.visibleRect.intersects($0.frame) }.isEmpty,
                "A paste must reconcile visible line fragments after a suppressed clip-view scroll")
    }

    @Test func editorScrollingMaintainsVisibleContent() async throws {
        OhMyGhosttySettings.shared.editorWordWrap = true
        defer { OhMyGhosttySettings.shared.editorWordWrap = false }
        let lines = (0..<400).map { i in
            "  \"model_\(i)\": { \"name\": \"Model Number \(i) with some extra long description to test wrapping behaviour in the editor view\", \"id\": \"model-\(i)\" },"
        }
        let text = "{\n" + lines.joined(separator: "\n") + "\n}"
        let host = NSHostingView(rootView: CodeEditorView(
            text: .constant(text),
            fileURL: URL(fileURLWithPath: "/models.json"),
            isEditable: true,
            isActive: true,
            terminalTheme: .oneDark
        ))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        func find(_ view: NSView) -> TextView? { (view as? TextView) ?? view.subviews.lazy.compactMap(find).first }
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(find(host))
        let clip = try #require(editor.enclosingScrollView?.contentView)

        for y in stride(from: CGFloat(0), through: CGFloat(4000), by: CGFloat(150)) {
            clip.scroll(to: .init(x: 0, y: y))
            editor.enclosingScrollView?.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(20))
            let visible = editor.subviews.filter { editor.visibleRect.intersects($0.frame) }
            #expect(!visible.isEmpty, "Editor must show content while scrolling down at y=\(y)")
        }

        #expect(editor.frame.height >= editor.layoutManager.estimatedHeight())

        for y in stride(from: CGFloat(4000), through: CGFloat(0), by: CGFloat(-150)) {
            clip.scroll(to: .init(x: 0, y: y))
            editor.enclosingScrollView?.reflectScrolledClipView(clip)
            try await Task.sleep(for: .milliseconds(20))
            let visible = editor.subviews.filter { editor.visibleRect.intersects($0.frame) }
            #expect(!visible.isEmpty, "Editor must show content while scrolling back up at y=\(y)")
        }

        try await Task.sleep(for: .milliseconds(50))
        let visibleFragments = editor.subviews.filter { editor.visibleRect.intersects($0.frame) }
        #expect(!visibleFragments.isEmpty, "Editor content area must not become empty after scrolling")
    }

    /// Keys in JSON and YAML must be visually distinct from values. The stock
    /// grammars collapse both into the same slot in OMG's theme; the JSON/YAML
    /// provider should separate them.
    @Test func jsonAndYamlKeysPaintDifferentlyFromValues() async throws {
        let json = """
        {
          "id": "gpt-6-sol",
          "name": "GPT-6 Sol (duck-codex-sale)",
          "reasoning": true,
          "contextWindow": 1050000,
          "empty": null
        }
        """
        let yaml = """
        id: gpt-6-sol
        name: GPT-6 Sol (duck-codex-sale)
        reasoning: true
        contextWindow: 1050000
        empty: null
        nested:
          - minimal
          - effort
        """

        for (language, source) in [("json", json), ("yaml", yaml)] {
            let coordinator = EditorCoordinator()
            let capture = CompletionTestCapture()
            let view = EditorTestSupport.editor(
                text: .constant(source),
                language: language == "json" ? .json : .yaml,
                highlightProviders: coordinator.highlightProviders,
                coordinators: [coordinator, capture]
            )
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            // The editor only highlights its visible text, so the window has to
            // be laid out at a real size; a zero-height host yields visibleRect
            // height 0 and the highlighter queries a two-character range.
            window.setContentSize(NSSize(width: 700, height: 400))
            window.makeKeyAndOrderFront(nil)
            host.view.layoutSubtreeIfNeeded()
            defer {
                coordinator.destroy()
                EditorTestSupport.unmount((host, window))
            }
            let controller = try #require(capture.controller)
            let textView = try #require(controller.textView)
            // Highlighting is asynchronous and coalesced per provider; give the
            // style container time to apply every run before sampling colors.
            try await Task.sleep(for: .milliseconds(800))

            func color(_ word: String) -> NSColor? {
                let range = (source as NSString).range(of: word)
                guard range.location != NSNotFound else { return nil }
                return textView.textStorage.attribute(.foregroundColor,
                                                      at: range.location,
                                                      effectiveRange: nil) as? NSColor
            }

            // Keys must differ from every literal kind, and literals must differ
            // from plain text. The grammars report booleans and nulls through
            // captures this editor cannot name, so they used to render unstyled.
            let keyColor = color("contextWindow")?.usingColorSpace(.deviceRGB)
            let valueColor = color("gpt-6-sol")?.usingColorSpace(.deviceRGB)
            let numberColor = color("1050000")?.usingColorSpace(.deviceRGB)
            let booleanColor = color("true")?.usingColorSpace(.deviceRGB)
            #expect(keyColor != nil, "key has no highlight for \(language)")
            #expect(valueColor != nil, "value has no highlight for \(language)")
            #expect(numberColor != nil, "number has no highlight for \(language)")
            #expect(booleanColor != nil, "boolean has no highlight for \(language)")
            if let keyColor, let valueColor, let numberColor, let booleanColor {
                #expect(keyColor != valueColor,
                        "key and value share a color for \(language): key=\(keyColor) value=\(valueColor)")
                #expect(keyColor != numberColor, "key and number share a color for \(language)")
                #expect(keyColor != booleanColor, "key and boolean share a color for \(language)")
                #expect(booleanColor != valueColor, "boolean and value share a color for \(language)")
            }
        }
    }

    /// The bundled JSON and YAML grammars must produce non-empty highlights for
    /// plain objects. If this returns empty, the tree-sitter query failed to
    /// load or the grammar cannot parse the document — surface that as a
    /// readable failure instead of silently dropping syntax coloring.
    @Test(arguments: ["json", "yaml"])
    @MainActor func structuredGrammarProducesHighlights(_ language: String) async throws {
        let source = language == "json"
            ? "{\n  \"id\": \"gpt-6-sol\",\n  \"n\": 42,\n  \"ok\": true,\n  \"none\": null\n}\n"
            : "id: gpt-6-sol\nn: 42\nok: true\nnone: null\n"
        let textView = TextView(string: source)
        let provider = EditorSyntaxHighlightProvider()
        let codeLanguage: CodeLanguage = language == "json" ? .json : .yaml
        provider.setUp(textView: textView, codeLanguage: codeLanguage)
        let highlights: [HighlightRange] = try await withCheckedThrowingContinuation { continuation in
            provider.queryHighlightsFor(textView: textView,
                                        range: NSRange(location: 0, length: source.utf16.count)) {
                continuation.resume(with: $0)
            }
        }
        #expect(!highlights.isEmpty, "grammar produced no highlights for \(language)")
        func captures(_ word: String) -> [CaptureName?] {
            let range = (source as NSString).range(of: word)
            return highlights.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.capture)
        }
        #expect(captures("id").contains(.type), "json/yaml key must map to type slot for \(language)")
        #expect(captures("42").contains(.number), "number must map to number slot for \(language)")
        // Booleans and nulls arrive as captures this enum cannot name, so the
        // provider has to recover them structurally.
        #expect(captures("true").contains(.boolean), "boolean must map to boolean slot for \(language)")
        #expect(!captures("null").isEmpty, "null must not render as plain text for \(language)")
    }
}
