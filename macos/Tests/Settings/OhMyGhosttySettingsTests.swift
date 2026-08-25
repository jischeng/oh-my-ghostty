import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct OhMyGhosttySettingsTests {
    @Test func typedSettingsRoundTripThroughHumanReadableFile() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        settings.tabLayout = .vertical
        settings.defaultSidebarWidth = 300
        settings.sidebarVisible = false
        settings.groupingMode = .project
        settings.orderingMode = .manual
        settings.tabPathDisplay = .folderName
        settings.notifyTaskComplete = false
        settings.restoreSessionsOnLaunch = false

        let data = try Data(contentsOf: url)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["tabs.layout"] as? String == "vertical")
        #expect((object["tabs.sidebarWidth"] as? NSNumber)?.doubleValue == 300)
        #expect(object["tabs.sidebarVisible"] as? Bool == false)
        #expect(object["tabs.grouping"] as? String == "project")
        #expect(object["tabs.ordering"] as? String == "manual")
        #expect(object["tabs.pathDisplay"] as? String == "folderName")
        #expect(object["notifications.taskComplete"] as? Bool == false)
        #expect(object["sessions.restoreOnLaunch"] as? Bool == false)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabLayout == .vertical)
        #expect(restored.defaultSidebarWidth == 300)
        #expect(!restored.sidebarVisible)
        #expect(restored.groupingMode == .project)
        #expect(restored.orderingMode == .manual)
        #expect(restored.tabPathDisplay == .folderName)
        #expect(!restored.notifyTaskComplete)
        #expect(!restored.restoreSessionsOnLaunch)
    }

    @Test func externalEditReloadsTheSameRuntimeModel() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let edited: [String: Any] = [
            "tabs.layout": "horizontal",
            "tabs.sidebarWidth": 280,
            "tabs.grouping": "date",
            "tabs.ordering": "recentlyUsed",
            "tabs.pathDisplay": "folderName",
        ]
        let data = try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)

        settings.reloadFromDisk()

        #expect(settings.tabLayout == .horizontal)
        #expect(settings.defaultSidebarWidth == 280)
        #expect(settings.groupingMode == .date)
        #expect(settings.orderingMode == .recentlyUsed)
        #expect(settings.tabPathDisplay == .folderName)
    }

    @Test func ghosttyConfigIsOnlyTheUnsetLayoutFallback() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        settings.configureGhosttyFallback(tabLayout: .horizontal)
        #expect(settings.tabLayout == .horizontal)
        settings.tabLayout = .vertical
        settings.configureGhosttyFallback(tabLayout: .horizontal)
        #expect(settings.tabLayout == .vertical)
    }

    @Test func appearanceResolutionPreservesGhosttyBaselineAndTracksSource() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ghosttyURL = url.deletingLastPathComponent().appendingPathComponent("ghostty.conf")
        try """
        font-size = 15
        background-opacity = 0.7
        background-blur = 12
        cursor-style = bar
        window-theme = dark
        """.write(to: ghosttyURL, atomically: true, encoding: .utf8)
        let config = Ghostty.Config(at: ghosttyURL.path)

        var appearance = settings.effectiveAppearance(using: config)
        #expect(appearance.fontSize.effectiveValue == 15)
        #expect(appearance.fontSize.source == .ghosttyConfig)
        #expect(appearance.backgroundOpacity.effectiveValue == 0.7)
        #expect(appearance.cursorStyle.effectiveValue == "bar")

        settings.fontSizeOverride = 18
        settings.backgroundOpacityOverride = 0.45
        settings.cursorStyleOverride = .underline
        appearance = settings.effectiveAppearance(using: config)

        #expect(appearance.fontSize.effectiveValue == 18)
        #expect(appearance.fontSize.inheritedValue == 15)
        #expect(appearance.fontSize.source == .ohMyGhosttyOverride)
        #expect(appearance.backgroundOpacity.effectiveValue == 0.45)
        #expect(appearance.cursorStyle.effectiveValue == "underline")
    }

    @Test func appearanceOverlayIsGeneratedAndResetWithoutEditingGhosttyConfig() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let overlayURL = url.deletingLastPathComponent().appendingPathComponent("appearance.ghostty")

        settings.windowThemeOverride = .system
        settings.lightThemeOverride = "Builtin Light"
        settings.darkThemeOverride = "Builtin Dark"
        settings.fontFamilyOverride = "Berkeley Mono"
        settings.backgroundOpacityOverride = 0.6
        settings.backgroundBlurOverride = .enabled

        let overlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(overlay.contains("window-theme = system"))
        #expect(overlay.contains("theme = light:Builtin Light,dark:Builtin Dark"))
        #expect(overlay.contains("font-family = Berkeley Mono"))
        #expect(overlay.contains("background-opacity = 0.6"))
        #expect(overlay.contains("background-blur = true"))

        settings.resetAppearance()
        let resetOverlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(!resetOverlay.contains("window-theme ="))
        #expect(!resetOverlay.contains("background-opacity ="))
        #expect(settings.windowThemeOverride == nil)
        #expect(settings.backgroundOpacityOverride == nil)
    }

    @Test func settingsWindowTracksExplicitAndSystemAppearance() async throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = OhMyGhosttySettingsWindowController(settings: settings)
        let window = try #require(controller.window)

        settings.windowThemeOverride = .dark
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.appearance?.name == .darkAqua)

        settings.windowThemeOverride = .light
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.appearance?.name == .aqua)

        settings.windowThemeOverride = .system
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.appearance == nil)
    }

    @Test func themeCatalogCombinesBundledAndUserThemes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources/ghostty/themes")
        let home = root.appendingPathComponent("Home")
        let userThemes = home.appendingPathComponent(".config/ghostty/themes")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
        try "background = 000000".write(
            to: resources.appendingPathComponent("Bundled"),
            atomically: true,
            encoding: .utf8
        )
        try "background = ffffff".write(
            to: userThemes.appendingPathComponent("Custom"),
            atomically: true,
            encoding: .utf8
        )

        let themes = GhosttyThemeCatalog.availableThemes(
            resourceURL: root.appendingPathComponent("Resources"),
            homeURL: home
        )
        #expect(themes == ["Bundled", "Custom"])
    }

    @Test func schemaDescriptorsAreUniqueAndMachineReadable() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let descriptors = OhMyGhosttySettings.descriptors

        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(descriptors.contains { $0.id == "tabs.layout" })
        #expect(descriptors.contains { $0.id == "tabs.ordering" })
        #expect(descriptors.contains { $0.id == "tabs.pathDisplay" })
        #expect(descriptors.contains { $0.id == "tabs.sidebarVisible" })
        #expect(descriptors.contains { $0.id == "agents.statusHooks" })
        #expect(descriptors.contains { $0.id == "sessions.restoreOnLaunch" })
        #expect(descriptors.contains { $0.id == "appearance.backgroundOpacity" })
        #expect(descriptors.contains { $0.id == "appearance.cursorStyle" })
        let schema = try settings.schemaData()
        #expect(!schema.isEmpty)
    }

    private func temporarySettings() -> (OhMyGhosttySettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        return (OhMyGhosttySettings(fileURL: url), url)
    }
}
