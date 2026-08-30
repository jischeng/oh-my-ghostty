import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct OhMyGhosttySettingsTests {
    @Test func developmentChannelSeedsButDoesNotShareStableSettings() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stable = OMGApplicationEnvironment.settingsFileURL(
            homeURL: home,
            development: false
        )
        let development = OMGApplicationEnvironment.settingsFileURL(
            homeURL: home,
            development: true
        )
        #expect(stable.path.contains("/.config/oh-my-ghostty/"))
        #expect(development.path.contains("/.config/oh-my-ghostty-dev/"))
        try FileManager.default.createDirectory(
            at: stable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"tabs.sidebarWidth":280}"#.write(
            to: stable,
            atomically: true,
            encoding: .utf8
        )

        OhMyGhosttySettings.seedDevelopmentSettingsIfNeeded(
            homeURL: home,
            development: true
        )
        #expect(try String(contentsOf: development, encoding: .utf8).contains("280"))
        try #"{"tabs.sidebarWidth":320}"#.write(
            to: development,
            atomically: true,
            encoding: .utf8
        )
        OhMyGhosttySettings.seedDevelopmentSettingsIfNeeded(
            homeURL: home,
            development: true
        )
        #expect(try String(contentsOf: development, encoding: .utf8).contains("320"))
        #expect(try String(contentsOf: stable, encoding: .utf8).contains("280"))
    }

    @Test func applicationSupportIsSeparatedByChannel() {
        #expect(OMGApplicationEnvironment.channel(development: false) == "release")
        #expect(OMGApplicationEnvironment.channel(development: true) == "debug")

        let base = URL(fileURLWithPath: "/tmp/omg-channel-test", isDirectory: true)
        #expect(OMGApplicationEnvironment.applicationSupportURL(
            baseURL: base,
            development: false
        ).lastPathComponent == "OMG")
        #expect(OMGApplicationEnvironment.applicationSupportURL(
            baseURL: base,
            development: true
        ).lastPathComponent == "OMG Dev")
    }

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
        settings.quickInputShortcut = "control+option+q"
        settings.quickInputHeight = 318
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
        #expect(object["keyboard.quickInput"] as? String == "control+option+q")
        #expect((object["keyboard.quickInputHeight"] as? NSNumber)?.doubleValue == 318)
        #expect(object["sessions.restoreOnLaunch"] as? Bool == false)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabLayout == .vertical)
        #expect(restored.defaultSidebarWidth == 300)
        #expect(!restored.sidebarVisible)
        #expect(restored.groupingMode == .project)
        #expect(restored.orderingMode == .manual)
        #expect(restored.tabPathDisplay == .folderName)
        #expect(!restored.notifyTaskComplete)
        #expect(restored.quickInputShortcut == "control+option+q")
        #expect(restored.quickInputHeight == 318)
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
        #expect(descriptors.contains { $0.id == "keyboard.quickInput" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHeight" })
        #expect(descriptors.contains { $0.id == "sessions.restoreOnLaunch" })
        #expect(descriptors.contains { $0.id == "general.language" })
        #expect(descriptors.contains { $0.id == "appearance.backgroundOpacity" })
        #expect(descriptors.contains { $0.id == "appearance.cursorStyle" })
        let schema = try settings.schemaData()
        #expect(!schema.isEmpty)
    }

    @Test func languageSettingRoundTripsAndDefaultsToSystem() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.language == .system)

        settings.language = .simplifiedChinese
        let data = try Data(contentsOf: url)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["general.language"] as? String == "zh-Hans")

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.language == .simplifiedChinese)
    }

    @Test func settingsLanguageResolvesSystemPreferenceAndExplicitPins() {
        #expect(SettingsStrings(
            language: .system,
            preferredLanguages: ["zh-Hans-CN", "en"]
        ).languageCode == "zh-Hans")
        #expect(SettingsStrings(
            language: .system,
            preferredLanguages: ["en-US"]
        ).languageCode == "en")
        #expect(SettingsStrings(
            language: .system,
            preferredLanguages: []
        ).languageCode == "en")
        #expect(SettingsStrings(
            language: .english,
            preferredLanguages: ["zh-Hans-CN"]
        ).languageCode == "en")
        #expect(SettingsStrings(
            language: .simplifiedChinese,
            preferredLanguages: ["en-US"]
        ).languageCode == "zh-Hans")
    }

    @Test func settingsStringsTranslateTheSettingsPage() {
        let zh = SettingsStrings(language: .simplifiedChinese, preferredLanguages: [])
        let en = SettingsStrings(language: .english, preferredLanguages: [])

        #expect(zh.windowTitle == "设置")
        #expect(en.windowTitle == "Settings")
        #expect(zh.tabTitle(.general) == "通用")
        #expect(zh.tabTitle(.plugins) == "插件")
        #expect(zh.languageSystem == "跟随系统")
        #expect(zh.groupingTitle(.project) == "按项目")
        #expect(en.groupingTitle(.project) == "By Project")
        #expect(zh.pathDisplayTitle(.folderName) == "当前文件夹")
        #expect(zh.orderingTitle(.recentlyUsed) == "最近使用")
        #expect(zh.agentHooksUpdateRequired == "需要更新 Hooks")
        #expect(zh.agentDetectorMissing == "未安装检测器")
    }

    private func temporarySettings() -> (OhMyGhosttySettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        return (OhMyGhosttySettings(fileURL: url), url)
    }
}
