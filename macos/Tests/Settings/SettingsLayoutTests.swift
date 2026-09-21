import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SettingsLayoutTests {
    @Test func settingsUseWideWindowAndAgentRowsFitNarrowAndWideForms() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SettingsLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: home)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        var snapshot = AgentIntegrationSnapshot()
        for agent in SupportedAgent.allCases {
            snapshot.hooks[agent] = .current
            snapshot.cli[agent] = .init(version: "1.2.3", path: "/usr/local/bin/" + agent.rawValue)
        }
        snapshot.hooks[.claude] = .updateAvailable
        snapshot.cli[.codex] = .init(version: "0.154.0", path: "/usr/local/bin/codex", updater: "native")
        let manager = AgentIntegrationManager(defaults: defaults, snapshots: ["local": snapshot], connectionTargets: { [] })
        let connection = try GitSSHConnection(destination: "cloud", options: ["-p", "2222"])
        let cachedInventory = snapshot
        let registry = SSHHostRegistry(defaults: defaults, live: { [connection] }, inventory: { _ in cachedInventory })
        registry.reconcile()
        await registry.register(connection, endpoint: "chengjisheng@10.0.0.123:2222")
        let registeredManager = AgentIntegrationManager(defaults: defaults,
            connectionTargets: { [RegisteredSSHHost.id(for: connection)] }, registry: registry)
        let registeredRoot = Form {
            Section("SSH") {
                SSHRegistrationSettingsView(strings: .init(language: .simplifiedChinese), registry: registry, agents: registeredManager,
                    initialChoices: [.init(id: RegisteredSSHHost.id(for: connection), name: "cloud", endpoint: "chengjisheng@10.0.0.123:2222",
                                           connection: connection, fromConfiguration: true)])
            }
            AgentIntegrationSettingsView(strings: .init(language: .simplifiedChinese), settings: settings,
                manager: registeredManager, registry: registry, refreshOnAppear: false, target: RegisteredSSHHost.id(for: connection))
        }.formStyle(.grouped).environment(\.colorScheme, .dark)
        let registeredHost = NSHostingView(rootView: registeredRoot)
        let registeredWindow = makeWindow(registeredHost, width: 800)
        defer { registeredWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        registeredHost.layoutSubtreeIfNeeded()
        try capture(registeredHost, name: "registered-ssh")
        for width in [CGFloat(450), 1_000] {
            let root = Form {
                AgentIntegrationSettingsView(strings: .init(language: .simplifiedChinese), settings: settings,
                                             manager: manager, refreshOnAppear: false)
            }
            .formStyle(.grouped).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: root)
            let window = makeWindow(host, width: width)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            try capture(host, name: "agents-\(Int(width))")
            #expect(host.bounds.width == width)
        }
        let host = NSHostingView(rootView: SettingsView(settings: settings, initialSelection: .appearance)
            .environment(\.colorScheme, .dark))
        let window = makeWindow(host, width: 1_200)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scrollViews = descendants(of: NSScrollView.self, in: host)
        #expect(scrollViews.contains { $0.frame.width > 900 })
        try capture(host, name: "appearance-wide")
    }

    @Test func themedSettingsRenderLightAndDarkWithoutSystemCanvas() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        let palettes: [(String, OMGThemePalette)] = [
            ("dark", OMGThemePalette(background: NSColor(srgbRed: 40 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1),
                                     foreground: NSColor(srgbRed: 0.8, green: 0.82, blue: 0.85, alpha: 1))),
            ("light", OMGThemePalette(background: NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1),
                                      foreground: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1)))
        ]
        for (name, palette) in palettes {
            let host = NSHostingView(rootView: SettingsView(settings: settings, initialSelection: .terminal, palette: palette))
            let window = makeWindow(host, width: 820)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            try capture(host, name: "terminal-" + name)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Sample empty content well away from text, controls and dividers.
            let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 30, y: bitmap.pixelsHigh - 30)?.usingColorSpace(.sRGB))
            // Bitmap caching uses the window/display profile. Render a solid
            // reference through the same path rather than interpreting those
            // bytes as unconverted config RGB (which fails on wide-gamut displays).
            let reference = NSHostingView(rootView: Color(palette.background))
            let referenceWindow = makeWindow(reference, width: 100)
            defer { referenceWindow.close() }
            reference.layoutSubtreeIfNeeded()
            let referenceBitmap = try #require(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
            reference.cacheDisplay(in: reference.bounds, to: referenceBitmap)
            let expected = try #require(referenceBitmap.colorAt(x: 30, y: 30)?.usingColorSpace(.sRGB))
            #expect(pixel.alphaComponent == 1)
            #expect(abs(pixel.redComponent - expected.redComponent) < 0.005)
            #expect(abs(pixel.greenComponent - expected.greenComponent) < 0.005)
            #expect(abs(pixel.blueComponent - expected.blueComponent) < 0.005)
        }
    }

    private func makeWindow(_ content: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.setFrameSize(NSSize(width: width, height: 850))
        return window
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func capture(_ view: NSView, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/omg-settings-layout")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
