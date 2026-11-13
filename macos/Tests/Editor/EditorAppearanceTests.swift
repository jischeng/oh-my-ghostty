import AppKit
import SwiftUI
import Testing
import WebKit
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
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }

        for origin in [0.0, 200.0, 0.0, 200.0] {
            backdrop.frame = NSRect(x: origin, y: 0, width: 200, height: 200)
            backdrop.setNeedsDisplay(NSRect(x: -400, y: -200, width: 1_200, height: 600))
            container.layoutSubtreeIfNeeded()
            let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / container.bounds.width
            let neighbourX = origin == 0 ? 300.0 : 100.0
            let neighbour = try #require(
                bitmap.colorAt(x: Int(neighbourX * scale), y: bitmap.pixelsHigh / 2)?
                    .usingColorSpace(.deviceRGB)
            )
            let editor = try #require(
                bitmap.colorAt(x: Int((origin + 100) * scale), y: bitmap.pixelsHigh / 2)?
                    .usingColorSpace(.deviceRGB)
            )
            #expect(neighbour.redComponent > 0.95)
            #expect(editor.redComponent > 0.4 && editor.redComponent < 0.8)
        }
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
        try "background = 123456\nforeground = abcdef\npalette = 5=#aabbcc\n"
            .write(to: file, atomically: true, encoding: .utf8)
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

        let payload = theme.monacoThemePayload(isDark: true)
        #expect(payload["base"] as? String == "vs-dark")
        #expect(payload["keywords"] as? String != payload["strings"] as? String)
    }

    @Test func settingsWindowHandlesCommandW() throws {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        #expect(window.performKeyEquivalent(with: event))
        #expect(!window.isVisible)
    }

    @Test func followingOMGReusesWindowBlurInsteadOfAddingSystemMaterial() {
        let following = EditorBackdrop(color: .blue, opacity: 0.85, blur: .enabled, usesWindowBlur: true)
        #expect(following.localEffect == .disabled)
        let independent = EditorBackdrop(color: .blue, opacity: 0.85, blur: .enabled)
        #expect(independent.localEffect == .enabled)
        let followingGlass = EditorBackdrop(
            color: .blue,
            opacity: 0.85,
            blur: .macosGlassRegular,
            usesWindowBlur: true
        )
        #expect(followingGlass.localEffect == .disabled)
        let independentGlass = EditorBackdrop(color: .blue, opacity: 0.85, blur: .macosGlassRegular)
        #expect(independentGlass.localEffect == .macosGlassRegular)
    }

    @Test func monacoEditorRemainsTransparentOverSharedBackdrop() async throws {
        let backdropColor = NSColor(red: 0.12, green: 0.24, blue: 0.36, alpha: 1)
        let source = "from pathlib import Path\n\ndef greet(name: str) -> str:\n    return f'Hello {name}'\n"
        let root = CodeEditorView(
            text: .constant(source),
            fileURL: URL(fileURLWithPath: "/tmp/hello.py"),
            terminalTheme: .oneDark
        )
        .background(EditorBackdrop(color: backdropColor, opacity: 1, blur: .disabled))
        .frame(width: 760, height: 460)

        let mounted = EditorTestSupport.host(root, size: NSSize(width: 760, height: 460))
        mounted.1.makeKeyAndOrderFront(nil)
        defer { EditorTestSupport.unmount(mounted) }

        let webView = try await EditorTestSupport.waitForMonacoReady(in: mounted.0.view)
        #expect(!webView.isOpaque)
        #expect((webView.value(forKey: "drawsBackground") as? Bool) == false)
        #expect((webView.underPageBackgroundColor?.alphaComponent ?? 0) == 0)

        let domTransparent = try await webView.evaluateJavaScript("""
        (() => {
            const isClear = (v) => v === 'rgba(0, 0, 0, 0)' || v === 'transparent';
            const htmlBg = getComputedStyle(document.documentElement).backgroundColor;
            const bodyBg = getComputedStyle(document.body).backgroundColor;
            const rootBg = getComputedStyle(document.getElementById('editor-root')).backgroundColor;
            const monacoBg = document.querySelector('.monaco-editor-background')
                ? getComputedStyle(document.querySelector('.monaco-editor-background')).backgroundColor
                : 'transparent';
            return isClear(htmlBg) && isClear(bodyBg) && isClear(rootBg) && isClear(monacoBg);
        })()
        """) as? Bool
        #expect(domTransparent == true, "Monaco editor and container DOM layers must stay transparent over EditorBackdrop")
    }

    @Test func monacoPierreHighlightingTokenizesPythonJsonAndYaml() async throws {
        let controller = MonacoWorkbenchController()
        let mounted = EditorTestSupport.host(
            MonacoWorkbenchSurface(controller: controller).frame(width: 720, height: 440),
            size: NSSize(width: 720, height: 440)
        )
        mounted.1.makeKeyAndOrderFront(nil)
        defer {
            controller.tearDown()
            EditorTestSupport.unmount(mounted)
        }

        let webView = try await EditorTestSupport.waitForMonacoReady(in: mounted.0.view)
        controller.setTheme(.oneDark, isDark: true)

        let pythonSource = "class TinyCache:\n    def update(self, value: int):\n        return True\n"
        controller.openOrUpdateModel(
            uri: "omg-model://local/tmp/cache.py",
            path: "/tmp/cache.py",
            text: pythonSource,
            languageHint: "python"
        )
        controller.activateModel(
            uri: "omg-model://local/tmp/cache.py",
            readOnly: false,
            wordWrap: false,
            tabSize: 4,
            insertSpaces: true,
            keymapProfile: .idea
        )

        var pythonTokens: Int = 0
        for _ in 0..<60 {
            pythonTokens = (try? await webView.evaluateJavaScript("""
            (() => {
                const monaco = window.omgEditor._internal.monaco;
                const tokens = monaco.editor.tokenize(\(String(reflecting: pythonSource)), 'python');
                return tokens.reduce((sum, line) => sum + line.length, 0);
            })()
            """) as? Int) ?? 0
            if pythonTokens > 3 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(pythonTokens > 3, "Pierre WASM tokenizer must produce rich syntax tokens for Python")

        let jsonSource = "{\n  \"contextWindow\": 1050000,\n  \"enabled\": true\n}\n"
        controller.openOrUpdateModel(
            uri: "omg-model://local/tmp/models.json",
            path: "/tmp/models.json",
            text: jsonSource,
            languageHint: "json"
        )
        let jsonTokens = (try await webView.evaluateJavaScript("""
        (() => {
            const monaco = window.omgEditor._internal.monaco;
            const tokens = monaco.editor.tokenize(\(String(reflecting: jsonSource)), 'json');
            return tokens.reduce((sum, line) => sum + line.length, 0);
        })()
        """) as? Int) ?? 0
        #expect(jsonTokens > 3, "JSON must tokenize keys, numbers, and booleans")
    }

    @Test func renderAppearanceAndEditorSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        for tab in [OhMyGhosttySettingsTab.appearance, .editor] {
            let host = NSHostingController(
                rootView: SettingsView(settings: settings, initialSelection: tab).frame(width: 1_000, height: 920)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 920),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            host.view.setFrameSize(NSSize(width: 1_000, height: 920))
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            window.close()
        }
    }
}
