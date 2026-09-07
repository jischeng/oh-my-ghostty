import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct EditorAppearanceTests {
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
