import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct QuickInputPresentationTests {
    @Test func footerSymbolsExistAndRenderConsistentlyInBothLanguages() throws {
        for symbol in ["command", "option", "return", "escape", "clock.arrow.circlepath"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let strings = SettingsStrings(language: language)
            #expect(strings.quickInputSection == (language == .english ? "Quick Input" : "快速输入"))
            let footer = HStack(spacing: QuickInputFooterStyle.itemSpacing) {
                QuickInputShortcutHint(symbols: ["command", "return"], title: strings.quickInputSendTitle)
                Text("·")
                QuickInputShortcutHint(symbols: ["option", "command", "return"], title: strings.quickInputQueueTitle)
                Text("·")
                QuickInputShortcutHint(symbols: ["escape"], title: strings.quickInputCancelTitle)
                Spacer()
                QuickInputHistoryButton(title: strings.quickInputHistoryButton) {}
            }
            .font(QuickInputFooterStyle.font)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(width: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: footer)
            host.frame.size = host.fittingSize
            #expect(host.fittingSize.width == 620)
            #expect(host.fittingSize.height < 60)
            try capture(host, name: "footer-\(language.rawValue)")
        }
    }

    @Test func quickInputAndHistorySettingsRenderInEditor() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        let host = NSHostingView(rootView: SettingsView(settings: settings, initialSelection: .editor))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try capture(host, name: "editor-settings")
        #expect(host.bounds.width == 820)
    }

    private func capture(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/omg-quick-input-\(name).png"))
    }
}
