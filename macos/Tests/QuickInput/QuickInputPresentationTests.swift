import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct QuickInputPresentationTests {
    @Test func footerSymbolsExistAndRenderConsistentlyInBothLanguages() throws {
        for symbol in ["command", "option", "return", "escape", "clock.arrow.circlepath", "pin", "pin.fill"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let strings = SettingsStrings(language: language)
            #expect(strings.quickInputSection == (language == .english ? "Quick Input" : "快速输入"))
            let footer = HStack(spacing: QuickInputFooterStyle.itemSpacing) {
                QuickInputFooterActionButton(symbols: ["command", "return"], title: strings.quickInputSendTitle) {}
                QuickInputFooterActionButton(symbols: ["option", "command", "return"], title: strings.quickInputQueueTitle) {}
                QuickInputFooterActionButton(symbols: ["escape"], title: strings.quickInputCancelTitle) {}
                Spacer()
                QuickInputFooterIconButton(title: strings.quickInputPinHelp, symbol: "pin.fill", isActive: true) {}
                QuickInputHistoryButton(title: strings.quickInputHistoryButtonHelp) {}
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

    @Test func multilineSubmissionReachesPTYBeforeEnter() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("receive.py")
        let ready = root.appendingPathComponent("ready")
        let output = root.appendingPathComponent("input")
        try """
        import os, tty, pathlib
        tty.setraw(0)
        os.write(1, b'\\x1b[?2004h')
        pathlib.Path(\(String(reflecting: ready.path))).touch()
        data = b''
        while not data.endswith(b'\\r'):
            data += os.read(0, 65536)
        pathlib.Path(\(String(reflecting: output.path))).write_bytes(data)
        """.write(to: script, atomically: true, encoding: .utf8)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/python3 " + script.path
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        try await Task.sleep(for: .milliseconds(100))
        let surface = try #require(controller.surfaceTree.first)
        controller.quickInputModel.present(for: surface.id)
        let text = "第一行中文🙂\n" + String(repeating: "long line abc 中文\n", count: 200) + "last line"
        controller.quickInputModel.draft = text
        controller.sendQuickInputDraft()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: output.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let received = try String(contentsOf: output, encoding: .utf8)
        #expect(received == "\u{1B}[200~" + text + "\u{1B}[201~\r")
    }

    @Test func importedDraftNoticeUsesSelectedLanguage() {
        #expect(SettingsStrings(language: .english).quickInputDraftImported ==
            "Draft imported. Sending will append only text after the original prefix.")
        #expect(SettingsStrings(language: .simplifiedChinese).quickInputDraftImported ==
            "草稿已导入。发送时只会追加原有内容之后新增的文字。")
    }

    @Test func inputUsesRegularFaceAndConfiguredForegroundForTextAndCaret() async throws {
        let foreground = NSColor(srgbRed: 0.8, green: 0.82, blue: 0.85, alpha: 1)
        let font = QuickInputTypography.font(family: "Menlo", size: 13)
        let root = AgentQuickInputTextEditor(
            text: .constant("Quick Input Regular / 快速输入\n匹配终端字体和前景色"),
            placeholder: "Type here…", isPresented: true, focusRequestID: 0,
            font: font, textColor: foreground, onPasteImage: nil,
            onSend: {}, onQueue: {}, onCancel: {}
        ).background(Color(nsColor: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 90),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func find(_ view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let editor = try #require(find(host))
        #expect(editor.font?.pointSize == 13)
        #expect(editor.font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(editor.textColor == foreground)
        #expect(editor.insertionPointColor == foreground)
        #expect((editor.typingAttributes[.foregroundColor] as? NSColor) == foreground)
        try capture(host, name: "typography")
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
