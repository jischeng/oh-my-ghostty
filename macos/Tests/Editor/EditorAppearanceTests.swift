import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
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
        #expect(color("grouped_expert_linear") == EditorTheme.oneDark.commands)
        #expect(color("QuantizedWeights") == EditorTheme.oneDark.types)
        #expect(color("bool") == EditorTheme.oneDark.commands)
        #expect(color("False") == EditorTheme.oneDark.numbers)
        let quoted = (source as NSString).range(of: "\"False\"")
        #expect(textView.textStorage.attribute(.foregroundColor, at: quoted.location + 1,
                                               effectiveRange: nil) as? NSColor == EditorTheme.oneDark.strings)
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
        let text = try #require(theme.text.usingColorSpace(.deviceRGB))
        let keyword = try #require(theme.keywords.usingColorSpace(.deviceRGB))
        #expect(abs(text.redComponent - 171.0 / 255) < 0.01)
        #expect(abs(keyword.blueComponent - 204.0 / 255) < 0.01)
    }

    @Test func namedCatalogThemeIncludesSyntaxAndBackground() throws {
        let themes = GhosttyThemeCatalog.availableThemes()
        #expect(themes.count > 50)
        let theme = try #require(EditorCatalogThemes.shared.theme(named: "Catppuccin Mocha"))
        #expect(theme.background.alphaComponent == 1)
        #expect(theme.strings != theme.keywords)
        #expect(theme.text != theme.background)
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
        theme.background = .clear
        let coordinator = EditorCoordinator()
        let editor = CodeEditSourceEditor(
            .constant("from pathlib import Path\n\nprint(\"Hello\")\n"), language: .python,
            theme: theme, font: .monospacedSystemFont(ofSize: 14, weight: .regular), tabWidth: 4,
            lineHeight: 1.2, wrapLines: false, cursorPositions: .constant([]),
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
        let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(abs(pixel.redComponent - color.redComponent) < 0.04)
        #expect(abs(pixel.blueComponent - color.blueComponent) < 0.04)
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
}
