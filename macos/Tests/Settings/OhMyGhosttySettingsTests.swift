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

    @Test func terminalResizeRenderingDefaultsToOnRelease() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.terminalResizeRendering == .onRelease)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "terminal.resizeRendering"
        }
        #expect(descriptor?.defaultValue == "onRelease")
    }

    @Test func gitAutoFetchIntervalDefaultsToFiveMinutesAndPersists() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.gitAutoFetchInterval == 5)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "git.autoFetchInterval"
        }
        #expect(descriptor?.defaultValue == "5")
        #expect(descriptor?.category == "general")

        settings.gitAutoFetchInterval = 10
        #expect(settings.gitAutoFetchInterval == 10)
        let disk = OhMyGhosttySettings(fileURL: url)
        #expect(disk.gitAutoFetchInterval == 10)
    }

    @Test func quickInputHistorySettingsDefaultClampAndRoundTrip() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.quickInputHistoryScope == .tab)
        #expect(settings.quickInputHistoryShareByDirectory)
        #expect(settings.quickInputHistoryInsertionMode == .append)
        #expect(settings.quickInputHistoryRetentionDays == 7)
        #expect(settings.quickInputHistoryKeepAfterQuit)
        settings.quickInputHistoryScope = .tab
        settings.quickInputHistoryShareByDirectory = false
        settings.quickInputHistoryRetentionDays = 30
        settings.quickInputHistoryKeepAfterQuit = false
        settings.quickInputHistoryInsertionMode = .replace
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.quickInputHistoryScope == .tab)
        #expect(!restored.quickInputHistoryShareByDirectory)
        #expect(restored.quickInputHistoryRetentionDays == 30)
        #expect(!restored.quickInputHistoryKeepAfterQuit)
        #expect(restored.quickInputHistoryInsertionMode == .replace)
        settings.quickInputHistoryScope = .pane
        #expect(OhMyGhosttySettings(fileURL: url).quickInputHistoryScope == .pane)
        settings.quickInputHistoryRetentionDays = 0
        #expect(settings.quickInputHistoryRetentionDays == 1)
        settings.quickInputHistoryRetentionDays = 400
        #expect(settings.quickInputHistoryRetentionDays == 365)
        settings.quickInputHistoryRetentionDays = 3.4
        #expect(settings.quickInputHistoryRetentionDays == 3)
        settings.quickInputHistoryRetentionDays = .nan
        #expect(settings.quickInputHistoryRetentionDays == 7)
        settings.quickInputHistoryScope = .global
        #expect(OhMyGhosttySettings(fileURL: url).quickInputHistoryScope == .global)
        let english = SettingsStrings(language: .english)
        let chinese = SettingsStrings(language: .simplifiedChinese)
        #expect(english.quickInputHistoryScopeName(.tab) == "Current Tab")
        #expect(chinese.quickInputHistoryScopeName(.tab) == "当前 Tab")
        #expect(english.quickInputHistoryRetentionValue(7) == "7 days")
        #expect(chinese.quickInputHistoryRetentionValue(7) == "7 天")
    }

    @Test func agentNotificationSoundTonePersistsValidatesAndExposesSystemSounds() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(!settings.notificationSound)
        #expect(settings.notificationSoundTone == .systemDefault)
        let descriptor = OhMyGhosttySettings.descriptors.first { $0.id == "notifications.soundTone" }
        #expect(descriptor?.defaultValue == "default")
        #expect(descriptor?.allowedValues?.count == 15)

        settings.notificationSound = true
        settings.notificationSoundTone = .glass
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.notificationSound)
        #expect(restored.notificationSoundTone == .glass)

        try Data(#"{"notifications.sound":true,"notifications.soundTone":"nonexistent"}"#.utf8).write(to: url)
        settings.reloadFromDisk()
        #expect(settings.notificationSound)
        #expect(settings.notificationSoundTone == .systemDefault)

        #expect(AgentActivityNotification.soundPlan(enabled: false, tone: .glass)
            == .init(requestBannerSound: false, customTone: nil))
        #expect(AgentActivityNotification.soundPlan(enabled: true, tone: .systemDefault)
            == .init(requestBannerSound: true, customTone: nil))
        #expect(AgentActivityNotification.soundPlan(enabled: true, tone: .ping)
            == .init(requestBannerSound: false, customTone: .ping))

        for tone in AgentNotificationSoundTone.allCases where tone != .systemDefault {
            #expect(AgentActivityNotification.makeSystemSound(for: tone) != nil)
        }

        let en = SettingsStrings(language: .english, preferredLanguages: [])
        let zh = SettingsStrings(language: .simplifiedChinese, preferredLanguages: [])
        #expect(en.notificationSoundToneLabel == "Sound Tone")
        #expect(zh.notificationSoundToneLabel == "提示音音色")
        #expect(en.notificationSoundToneTitle(.systemDefault) == "System Default")
        #expect(zh.notificationSoundToneTitle(.systemDefault) == "系统默认")
        #expect(zh.notificationSoundToneTitle(.sosumi) == "Sosumi")
    }

    @Test func quickInputControlJNewlineDefaultsOffAndPersists() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!settings.quickInputControlJNewline)
        settings.quickInputControlJNewline = true
        #expect(OhMyGhosttySettings(fileURL: url).quickInputControlJNewline)
    }

    @Test func focusedSplitBorderSettingsPersistAndClamp() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.focusedSplitBorder)
        #expect(settings.focusedSplitBorderWidth == 3)
        #expect(settings.focusedSplitBorderPosition == .bottom)
        settings.focusedSplitBorder = false
        settings.focusedSplitBorderWidth = 1.5
        #expect(OhMyGhosttySettings(fileURL: url).focusedSplitBorderWidth == 1.5)
        settings.focusedSplitBorderWidth = 3
        settings.focusedSplitBorderPosition = .right
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(!restored.focusedSplitBorder)
        #expect(restored.focusedSplitBorderWidth == 3)
        #expect(restored.focusedSplitBorderPosition == .right)
        settings.focusedSplitBorderWidth = 10
        #expect(settings.focusedSplitBorderWidth == 6)
        settings.focusedSplitBorderWidth = 0
        #expect(settings.focusedSplitBorderWidth == 1)
    }

    @Test func splitOpacityPassesThroughNativeConfigAndResetsWithFocusAppearance() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let overlayURL = url.deletingLastPathComponent().appendingPathComponent("appearance.ghostty")
        let configURL = url.deletingLastPathComponent().appendingPathComponent("baseline.ghostty")
        try "background-opacity = 0.8\nunfocused-split-opacity = 0.7\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        #expect(settings.unfocusedSplitOpacity == 0.9)
        let initialOverlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(!initialOverlay.contains("unfocused-split-opacity"))
        let initial = Ghostty.Config(at: configURL.path, overrideAt: overlayURL.path)
        #expect(initial.errors.isEmpty)
        #expect(initial.backgroundOpacity == 0.8)
        // Native `baseline.ghostty` sets `unfocused-split-opacity = 0.7` (overlay alpha 0.3),
        // which must be preserved until the user explicitly customizes `unfocusedSplitOpacity`.
        #expect(abs(initial.unfocusedSplitOpacity - 0.3) < 0.001)

        settings.backgroundOpacityOverride = 0.6
        settings.unfocusedSplitOpacity = 0.75
        settings.focusedSplitBorderPosition = .left
        settings.focusedSplitBorderWidth = 3
        let customOverlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(customOverlay.contains("unfocused-split-opacity = 0.75"))
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.unfocusedSplitOpacity == 0.75)
        let custom = Ghostty.Config(at: configURL.path, overrideAt: overlayURL.path)
        #expect(custom.errors.isEmpty)
        #expect(custom.backgroundOpacity == 0.6)
        #expect(custom.unfocusedSplitOpacity == 0.25)

        settings.unfocusedSplitOpacity = 0
        #expect(settings.unfocusedSplitOpacity == 0.15)
        settings.unfocusedSplitOpacity = 2
        #expect(settings.unfocusedSplitOpacity == 1)
        let opaque = Ghostty.Config(at: configURL.path, overrideAt: overlayURL.path)
        #expect(opaque.unfocusedSplitOpacity == 0)

        settings.resetAppearance()
        let resetOverlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(!resetOverlay.contains("unfocused-split-opacity"))
        let reset = OhMyGhosttySettings(fileURL: url)
        #expect(reset.backgroundOpacityOverride == nil)
        #expect(reset.unfocusedSplitOpacity == 0.9)
        #expect(reset.focusedSplitBorderWidth == 3)
        #expect(reset.focusedSplitBorderPosition == .bottom)
        let resetConfig = Ghostty.Config(at: configURL.path, overrideAt: overlayURL.path)
        #expect(resetConfig.backgroundOpacity == 0.8)
        #expect(abs(resetConfig.unfocusedSplitOpacity - 0.3) < 0.001)
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
        settings.openQuickInputOnAgentStart = true
        settings.openQuickInputOnAgentComplete = true
        settings.quickInputShortcut = "control+option+q"
        settings.inspectorPanel1Shortcut = "option+command+1"
        settings.inspectorPanel2Shortcut = "option+command+2"
        settings.inspectorPanel3Shortcut = "option+command+3"
        settings.inspectorPanel4Shortcut = "option+command+4"
        settings.quickInputHeight = 318
        settings.quickInputOpacity = 0.25
        settings.terminalResizeRendering = .onRelease
        settings.editorKeymapPreset = .vscode
        settings.editorBackgroundMode = .system
        settings.editorSyntaxTheme = .dracula
        settings.editorFontFamily = .sfMono
        settings.editorFontSize = 15.5
        settings.editorTabWidth = 2
        settings.editorWordWrap = false
        settings.startupMode = .newTerminal
        settings.quitWithoutConfirmation = true

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
        #expect(object["agents.openQuickInputOnStart"] as? Bool == true)
        #expect(object["agents.openQuickInputOnComplete"] as? Bool == true)
        #expect(object["keyboard.quickInput"] as? String == "control+option+q")
        #expect(object["keyboard.inspectorPanel1"] as? String == "option+command+1")
        #expect(object["keyboard.inspectorPanel2"] as? String == "option+command+2")
        #expect(object["keyboard.inspectorPanel3"] as? String == "option+command+3")
        #expect(object["keyboard.inspectorPanel4"] as? String == "option+command+4")
        #expect((object["keyboard.quickInputHeight"] as? NSNumber)?.doubleValue == 318)
        #expect((object["keyboard.quickInputOpacity"] as? NSNumber)?.doubleValue == 0.25)
        #expect(object["terminal.resizeRendering"] as? String == "onRelease")
        #expect(object["editor.keymapPreset"] as? String == "vscode")
        #expect(object["editor.backgroundMode"] as? String == "system")
        #expect(object["editor.syntaxTheme"] as? String == "dracula")
        #expect(object["editor.fontFamily"] as? String == "sfMono")
        #expect((object["editor.fontSize"] as? NSNumber)?.doubleValue == 15.5)
        #expect((object["editor.tabWidth"] as? NSNumber)?.doubleValue == 2)
        #expect(object["editor.wordWrap"] as? Bool == false)
        #expect(object["sessions.startupMode"] as? String == "newTerminal")
        #expect(object["general.quitWithoutConfirmation"] as? Bool == true)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabLayout == .vertical)
        #expect(restored.defaultSidebarWidth == 300)
        #expect(!restored.sidebarVisible)
        #expect(restored.groupingMode == .project)
        #expect(restored.orderingMode == .manual)
        #expect(restored.tabPathDisplay == .folderName)
        #expect(!restored.notifyTaskComplete)
        #expect(restored.openQuickInputOnAgentStart)
        #expect(restored.openQuickInputOnAgentComplete)
        #expect(restored.quickInputShortcut == "control+option+q")
        #expect(restored.inspectorPanel1Shortcut == "option+command+1")
        #expect(restored.inspectorPanel2Shortcut == "option+command+2")
        #expect(restored.inspectorPanel3Shortcut == "option+command+3")
        #expect(restored.inspectorPanel4Shortcut == "option+command+4")
        #expect(restored.inspectorPanelShortcut(slot: 1) == "option+command+1")
        #expect(restored.inspectorPanelShortcut(slot: 2) == "option+command+2")
        #expect(restored.inspectorPanelShortcut(slot: 3) == "option+command+3")
        #expect(restored.inspectorPanelShortcut(slot: 4) == "option+command+4")
        #expect(restored.quickInputHeight == 318)
        #expect(restored.quickInputOpacity == 0.25)
        #expect(restored.terminalResizeRendering == .onRelease)
        #expect(restored.editorSettings.keymapPreset == .vscode)
        #expect(restored.editorSettings.backgroundMode == .system)
        #expect(restored.editorSettings.syntaxTheme == .dracula)
        #expect(restored.editorSettings.fontFamily == .sfMono)
        #expect(restored.editorSettings.fontSize == 15.5)
        #expect(restored.editorSettings.tabWidth == 2)
        #expect(!restored.editorSettings.wordWrap)
        #expect(restored.startupMode == .newTerminal)
        #expect(restored.quitWithoutConfirmation)
    }

    @Test func legacyRestoreBooleanMigratesWithoutChangingTheEffectiveMode() throws {
        for (legacy, expected) in [(false, OMGStartupMode.newTerminal),
                                   (true, OMGStartupMode.restoreSessions)] {
            let (_, url) = temporarySettings()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try Data("{\"sessions.restoreOnLaunch\":\(legacy)}".utf8).write(to: url)
            let settings = OhMyGhosttySettings(fileURL: url)
            #expect(settings.startupMode == expected)
            let object = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["sessions.startupMode"] as? String == expected.rawValue)
            #expect(object["sessions.restoreOnLaunch"] == nil)
        }
    }

    @Test func newStartupModeWinsOverLegacyBooleanDuringMigration() throws {
        let (_, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("{\"sessions.startupMode\":\"restoreTabs\",\"sessions.restoreOnLaunch\":false}".utf8)
            .write(to: url)
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.startupMode == .restoreTabs)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["sessions.restoreOnLaunch"] == nil)
    }

    @Test func allStartupModesPersistAndInvalidValueFailsSafe() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for mode in OMGStartupMode.allCases {
            settings.startupMode = mode
            #expect(OhMyGhosttySettings(fileURL: url).startupMode == mode)
        }
        try Data("{\"sessions.startupMode\":\"bad\"}".utf8).write(to: url)
        settings.reloadFromDisk()
        #expect(settings.startupMode == .restoreSessions)
        #expect(!OMGStartupMode.newTerminal.restoresTabs)
        #expect(OMGStartupMode.restoreTabs.restoresTabs)
        #expect(!OMGStartupMode.restoreTabs.restoresSessions)
        #expect(OMGStartupMode.restoreSessions.restoresSessions)
    }

    @Test func legacySmoothResizeBooleanMigratesToRenderingMode() throws {
        let (_, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"terminal.smoothResize\":false}".utf8).write(to: url)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.terminalResizeRendering == .onRelease)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["terminal.resizeRendering"] as? String == "onRelease")
        #expect(object["terminal.smoothResize"] == nil)
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
        #expect(descriptors.contains { $0.id == "agents.historyLimit" })
        #expect(descriptors.contains { $0.id == "agents.statusHooks" })
        #expect(descriptors.contains { $0.id == "agents.openQuickInputOnStart" })
        #expect(descriptors.contains { $0.id == "agents.openQuickInputOnComplete" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInput" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHeight" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputOpacity" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryScope" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryInsertionMode" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryRetentionDays" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryKeepAfterQuit" })
        #expect(descriptors.contains { $0.id == "terminal.resizeRendering" })
        #expect(descriptors.contains { $0.id == "editor.keymapPreset" })
        #expect(descriptors.contains { $0.id == "editor.backgroundMode" })
        #expect(descriptors.contains { $0.id == "editor.fontSize" })
        #expect(descriptors.contains { $0.id == "editor.tabWidth" })
        #expect(descriptors.contains { $0.id == "editor.wordWrap" })
        #expect(descriptors.contains { $0.id == "sessions.startupMode" })
        #expect(descriptors.contains { $0.id == "general.language" })
        #expect(descriptors.contains { $0.id == "general.quitWithoutConfirmation" })
        #expect(descriptors.contains { $0.id == "appearance.backgroundOpacity" })
        #expect(descriptors.contains { $0.id == "appearance.cursorStyle" })
        let schema = try settings.schemaData()
        #expect(!schema.isEmpty)
    }

    @Test func quitConfirmationDefaultTracksApplicationChannel() {
        #expect(!OMGApplicationEnvironment.quitWithoutConfirmationDefault(
            development: false
        ))
        #expect(OMGApplicationEnvironment.quitWithoutConfirmationDefault(
            development: true
        ))
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expected = OMGApplicationEnvironment.quitWithoutConfirmationDefault()
        #expect(settings.quitWithoutConfirmation == expected)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "general.quitWithoutConfirmation"
        }
        #expect(descriptor?.defaultValue == String(expected))
    }

    @Test func quickInputOnAgentStartDefaultsOff() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!settings.openQuickInputOnAgentStart)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "agents.openQuickInputOnStart"
        }
        #expect(descriptor?.defaultValue == "false")
    }

    @Test func quickInputOnAgentCompleteDefaultsOff() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!settings.openQuickInputOnAgentComplete)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "agents.openQuickInputOnComplete"
        }
        #expect(descriptor?.defaultValue == "false")
    }

    @Test func editorOpenDestinationsPersistIndependently() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.editorFileOpenDestination == .currentPane)
        #expect(settings.editorDirectoryOpenDestination == .currentPane)
        for destination in EditorOpenDestination.allCases {
            settings.editorFileOpenDestination = destination
            settings.editorDirectoryOpenDestination = .splitLeft
            let restored = OhMyGhosttySettings(fileURL: url)
            #expect(restored.editorSettings.fileOpenDestination == destination)
            #expect(restored.editorSettings.directoryOpenDestination == .splitLeft)
        }
        try #"{"editor.fileOpenDestination":"invalid","editor.directoryOpenDestination":"invalid"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.editorFileOpenDestination == .currentPane)
        #expect(restored.editorDirectoryOpenDestination == .currentPane)
    }

    @Test func editorSettingsDefaultToIdeaAndFollowTerminal() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.editorSettings == EditorSettings(
            keymapPreset: .idea,
            backgroundMode: .followTerminal,
            syntaxTheme: .followTerminal,
            fontFamily: .jetbrainsMono,
            fontSize: 13,
            tabWidth: 4,
            wordWrap: false
        ))
        #expect(settings.editorSettings.keymapProfile == .idea)
        #expect(settings.editorSettings.keymap.action(
            for: EditorKeyStroke(key: "d", modifiers: .command)
        ) == .duplicateLine)
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
        #expect(zh.tabTitle(.editor) == "编辑器")
        #expect(en.tabTitle(.editor) == "Editor")
        #expect(en.tabTitle(.ssh) == "Remote Machines")
        #expect(zh.tabTitle(.ssh) == "远程机器")
        #expect(en.tabTitle(.mobile) == "Mobile Devices")
        #expect(zh.tabTitle(.mobile) == "移动设备")
        #expect(zh.resetEditorButton == "重置编辑器设置")
        #expect(zh.editorOpenDestinationTitle(.currentPane) == "当前窗格")
        #expect(en.editorOpenDestinationTitle(.newTab) == "New Tab")
        #expect(zh.languageSystem == "跟随系统")
        #expect(zh.startupModeLabel == "重新打开 OMG 时")
        #expect(en.startupModeTitle(.newTerminal) == "Open a New Terminal")
        #expect(en.startupModeTitle(.restoreTabs) == "Restore All Tabs")
        #expect(zh.startupModeTitle(.restoreSessions) == "恢复所有会话")
        #expect(zh.quitWithoutConfirmationLabel == "退出时无需确认")
        #expect(en.quitWithoutConfirmationLabel == "Quit Without Confirmation")
        #expect(zh.groupingTitle(.project) == "按项目")
        #expect(en.groupingTitle(.project) == "By Project")
        #expect(zh.pathDisplayTitle(.folderName) == "当前文件夹")
        #expect(zh.orderingTitle(.recentlyUsed) == "最近使用")
        #expect(zh.agentHooksUpdateRequired == "需要更新 Hooks")
        #expect(zh.agentDetectorMissing == "未安装检测器")
        #expect(zh.agentDetectorUpdateExplanation.contains("尚未接入厂商状态 Hook"))
        #expect(en.agentDetectorUpdateExplanation.contains("not a vendor status Hook"))
    }

    @Test func settingsAndAppearanceOverlayEnforcePrivate0700And0600Permissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDir = root.appendingPathComponent("oh-my-ghostty", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Pre-create with permissive 0755/0644 modes to verify tightening on save.
        try FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let settingsURL = configDir.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsURL.path)

        let settings = OhMyGhosttySettings(fileURL: settingsURL)
        settings.windowThemeOverride = .dark
        #expect(settings.lastError == nil)

        let overlayURL = configDir.appendingPathComponent("appearance.ghostty")
        let dirPerms = try (FileManager.default.attributesOfItem(atPath: configDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let settingsPerms = try (FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber)?.intValue
        let overlayPerms = try (FileManager.default.attributesOfItem(atPath: overlayURL.path)[.posixPermissions] as? NSNumber)?.intValue

        #expect((dirPerms ?? 0) & 0o777 == 0o700)
        #expect((settingsPerms ?? 0) & 0o777 == 0o600)
        #expect((overlayPerms ?? 0) & 0o777 == 0o600)

        // Symlinked target must be refused rather than clobbering an external target.
        let external = root.appendingPathComponent("external.json")
        try Data("keep".utf8).write(to: external)
        let symlink = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        #expect(throws: OMGPrivateFileWriter.WriteError.self) {
            try OMGPrivateFileWriter.writeAtomically(Data("overwrite".utf8), to: symlink)
        }
        #expect(try String(contentsOf: external, encoding: .utf8) == "keep")
    }

    @Test func portableSettingsMigratesLegacyUserDefaultsNonDestructivelyIntoPrivateJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-portable-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "OhMyGhosttyPortableMigrate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let conn = try GitSSHConnection(destination: "dev@box.example.com", options: ["-p", "2222"])
        _ = registry.prepareSetup(conn)
        registry.automaticallyRegister = false

        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)
        agents.setPolicy(
            AgentIntegrationPolicy(
                checkAutomatically: false,
                updateHooksAutomatically: false,
                automaticallyUpdatedAgents: [.claude, .codex],
                intervalHours: 12,
                updateAllCLIsAutomatically: true,
                checkOnConnection: false
            ),
            for: AgentIntegrationManager.localID
        )

        let gitDiff = GitDiffPreferences(defaults: defaults)
        gitDiff.setViewMode(.split)
        gitDiff.setReview(false)
        gitDiff.setWordWrap(false)

        let settingsURL = dir.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: settingsURL)
        settings.bindPortableStores(
            sshRegistry: registry,
            agentManager: agents,
            gitDiff: gitDiff,
            defaults: defaults
        )

        // Legacy UserDefaults entries remain intact (non-destructive migration).
        #expect(defaults.data(forKey: "OMG.SSH.Registry.v1") != nil)
        #expect(defaults.data(forKey: "OMG.AgentIntegration.Policies.v1") != nil)

        // And settings.json now mirrors sshHosts, agentPolicies, and gitDiff with 0600 permissions.
        let perms = try (FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect((perms ?? 0) & 0o777 == 0o600)

        let rawJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        #expect(rawJSON["sshHosts"] != nil)
        #expect(rawJSON["agentPolicies"] != nil)
        #expect(rawJSON["gitDiff"] != nil)
        #expect(rawJSON["workspaceTrust"] == nil)

        // Loading that single settings.json on a second clean Mac restores all three stores!
        let cleanSuite = "OhMyGhosttyPortableClean.\(UUID().uuidString)"
        let cleanDefaults = try #require(UserDefaults(suiteName: cleanSuite))
        defer { cleanDefaults.removePersistentDomain(forName: cleanSuite) }

        let targetRegistry = SSHHostRegistry(defaults: cleanDefaults, live: { [] }, inventory: { _ in .init() })
        let targetAgents = AgentIntegrationManager(defaults: cleanDefaults, connectionTargets: { [] }, registry: targetRegistry)
        let targetGitDiff = GitDiffPreferences(defaults: cleanDefaults)
        let targetSettings = OhMyGhosttySettings(fileURL: settingsURL)
        targetSettings.bindPortableStores(
            sshRegistry: targetRegistry,
            agentManager: targetAgents,
            gitDiff: targetGitDiff,
            defaults: cleanDefaults
        )

        #expect(!targetRegistry.automaticallyRegister)
        #expect(targetRegistry.hosts.map(\.connection) == [conn])
        let restoredPolicy = targetAgents.policy(for: AgentIntegrationManager.localID)
        #expect(!restoredPolicy.checkAutomatically)
        #expect(!restoredPolicy.updateHooksAutomatically)
        #expect(restoredPolicy.automaticallyUpdatedAgents == [.claude, .codex])
        #expect(restoredPolicy.intervalHours == 12)
        #expect(restoredPolicy.updateAllCLIsAutomatically == true)
        #expect(targetGitDiff.viewMode == .split)
        #expect(!targetGitDiff.review)
        #expect(!targetGitDiff.wordWrap)
    }

    @Test func portableSettingsAppliesReloadedJSONAndMirrorsLiveMutationsWhileKeepingTrustLocal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-portable-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "OhMyGhosttyPortableSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let trustFileURL = dir.appendingPathComponent("editor-trusted-workspaces.json")
        let trustedRepo = dir.appendingPathComponent("local-machine-only-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedRepo, withIntermediateDirectories: true)
        let trustStore = EditorWorkspaceTrustStore(fileURL: trustFileURL)
        trustStore.trust(workspaceRoot: trustedRepo.path)

        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)
        let gitDiff = GitDiffPreferences(defaults: defaults)

        let settingsURL = dir.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: settingsURL)
        settings.bindPortableStores(
            sshRegistry: registry,
            agentManager: agents,
            gitDiff: gitDiff,
            defaults: defaults
        )

        // Mutate live -> automatically mirrored to settings.json
        gitDiff.setViewMode(.split)
        #expect(settings.portableGitDiff?.viewMode == GitDiffViewMode.split.rawValue)

        // Edit settings.json externally (e.g. git pull / chezmoi apply) and reloadFromDisk()
        let prodConn = try GitSSHConnection(destination: "ops@prod.example.com")
        let prodHostID = RegisteredSSHHost.id(for: prodConn)
        let externalJSON = """
        {
          "agentPolicies": {
            "local": {
              "automaticallyUpdatedAgents": ["qwen"],
              "checkAutomatically": true,
              "checkOnConnection": true,
              "intervalHours": 6,
              "updateAllCLIsAutomatically": false,
              "updateHooksAutomatically": true
            }
          },
          "gitDiff": {
            "review": false,
            "viewMode": "inline",
            "wordWrap": false
          },
          "sshHosts": {
            "automaticallyRegister": false,
            "excluded": ["ssh-host:old"],
            "hosts": [
              {
                "connection": {
                  "destination": "ops@prod.example.com",
                  "executablePath": "/usr/bin/ssh",
                  "localWorkingDirectory": "/",
                  "options": [],
                  "workspaceID": "ssh:ops@prod.example.com"
                },
                "id": "\(prodHostID)",
                "name": "ops@prod.example.com"
              }
            ]
          }
        }
        """
        try OMGPrivateFileWriter.writeAtomically(Data(externalJSON.utf8), to: settingsURL)
        settings.reloadFromDisk()

        #expect(gitDiff.viewMode == .inline)
        #expect(!gitDiff.review)
        #expect(!gitDiff.wordWrap)
        #expect(!registry.automaticallyRegister)
        #expect(registry.excludedIDs == ["ssh-host:old"])
        #expect(registry.hosts.first?.connection.destination == "ops@prod.example.com")
        #expect(agents.policy(for: "local").intervalHours == 6)
        #expect(agents.policy(for: "local").automaticallyUpdatedAgents == [.qwen])

        // Machine-local workspace trust remains untouched and never serialized into settings.json.
        #expect(trustStore.isTrusted(workspaceRoot: trustedRepo.path))
        let savedText = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(!savedText.contains("local-machine-only-repo"))
    }

    @Test func tabSidebarAndConversationTitleSettingsDefaultAndPersist() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.tabSidebarViewMode == .tabs)
        #expect(settings.tabInboxGroupingMode == .date)
        #expect(settings.tabInboxOrderingMode == .recentlyUsed)
        #expect(settings.tabRowDensity == .comfortable)
        #expect(OhMyGhosttyTabRowDensity.comfortable.rowHeight == 36)
        #expect(OhMyGhosttyTabRowDensity.compact.rowHeight == 30)
        #expect(settings.agentSessionTitleMode == .generate)
        #expect(!settings.agentSessionTitleAlwaysUseAI)
        #expect(settings.aiProviders.isEmpty)
        #expect(settings.aiTitleRoute == nil)

        let density = OhMyGhosttySettings.descriptors.first { $0.id == "appearance.tabRowDensity" }
        #expect(density?.defaultValue == "comfortable")
        #expect(density?.allowedValues == ["compact", "comfortable"])
        let sidebar = OhMyGhosttySettings.descriptors.first { $0.id == "tabs.sidebarView" }
        #expect(sidebar?.defaultValue == "tabs")
        #expect(sidebar?.allowedValues == ["tabs", "inbox"])
        let grouping = OhMyGhosttySettings.descriptors.first { $0.id == "tabs.inboxGrouping" }
        #expect(grouping?.defaultValue == "date")
        #expect(grouping?.allowedValues == ["none", "project", "date"])
        let ordering = OhMyGhosttySettings.descriptors.first { $0.id == "tabs.inboxOrdering" }
        #expect(ordering?.defaultValue == "recentlyUsed")
        #expect(ordering?.allowedValues == ["manual", "created", "recentlyUsed"])
        #expect(OhMyGhosttySettings.descriptors.first { $0.id == "agents.sessionTitle.mode" }?
            .allowedValues == ["off", "native", "generate"])
        let alwaysUseAI = OhMyGhosttySettings.descriptors.first { $0.id == "agents.sessionTitle.alwaysUseAI" }
        #expect(alwaysUseAI?.type == .boolean)
        #expect(alwaysUseAI?.defaultValue == "false")
        // The single endpoint of the first AI build is gone from the registry.
        #expect(!OhMyGhosttySettings.descriptors.contains { $0.id.hasPrefix("ai.endpoint.") })

        settings.tabSidebarViewMode = .inbox
        settings.tabInboxGroupingMode = .project
        settings.tabInboxOrderingMode = .created
        settings.tabRowDensity = .compact
        settings.agentSessionTitleMode = .native
        settings.agentSessionTitleAlwaysUseAI = true

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["tabs.sidebarView"] as? String == "inbox")
        #expect(object["tabs.inboxGrouping"] as? String == "project")
        #expect(object["tabs.inboxOrdering"] as? String == "created")
        #expect(object["appearance.tabRowDensity"] as? String == "compact")
        #expect(object["agents.sessionTitle.mode"] as? String == "native")
        #expect(object["agents.sessionTitle.alwaysUseAI"] as? Bool == true)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabSidebarViewMode == .inbox)
        #expect(restored.tabInboxGroupingMode == .project)
        #expect(restored.tabInboxOrderingMode == .created)
        #expect(restored.tabRowDensity == .compact)
        #expect(restored.agentSessionTitleMode == .native)
        #expect(restored.agentSessionTitleAlwaysUseAI)
    }

    @Test func invalidInboxAndTitleValuesFallBackToDefaults() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // `recent` is what the first inbox build stored for the ordering.
        try #"{"tabs.sidebarView":"grid","tabs.inboxGrouping":"host","tabs.inboxOrdering":"recent","appearance.tabRowDensity":" cramped ","agents.sessionTitle.mode":"always","agents.sessionTitle.alwaysUseAI":"yes","ai.providers":"none","ai.routes.title":["x"],"ai.routes.commit":{"kind":"agent"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.tabSidebarViewMode == .tabs)
        #expect(settings.tabInboxGroupingMode == .date)
        #expect(settings.tabInboxOrderingMode == .recentlyUsed)
        #expect(settings.tabRowDensity == .comfortable)
        #expect(settings.agentSessionTitleMode == .generate)
        #expect(!settings.agentSessionTitleAlwaysUseAI)
        #expect(settings.aiProviders.isEmpty)
        #expect(settings.aiTitleRoute == nil)
        #expect(settings.gitCommitAIRoutes.isEmpty)
    }

    @Test func aiProvidersAndTheTitleModelPersistWithoutAnySecret() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = AIProvider(
            name: "Work proxy", kind: .anthropic, baseURL: "https://proxy.example.com",
            models: [AIProviderModel(id: "claude-test", contextWindow: 200_000, maxOutputTokens: 8_192)]
        )
        settings.aiProviders = [provider]
        settings.aiTitleRoute = AITitleRoute(provider: provider.id, model: "claude-test")

        let text = try String(contentsOf: url, encoding: .utf8)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let stored = try #require((object["ai.providers"] as? [[String: Any]])?.first)
        #expect(Set(stored.keys) == ["id", "name", "kind", "baseURL", "enabled", "models"])
        #expect(stored["kind"] as? String == "anthropic")
        let title = try #require(object["ai.routes.title"] as? [String: Any])
        #expect(title["provider"] as? String == provider.id.uuidString)
        #expect(title["model"] as? String == "claude-test")
        #expect(!text.lowercased().contains("apikey"))
        #expect(!text.lowercased().contains("api_key"))

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.aiProviders == [provider])
        #expect(restored.aiTitleRoute == settings.aiTitleRoute)

        // Clearing the title model removes its key instead of writing an empty value.
        restored.aiTitleRoute = nil
        let cleared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(cleared["ai.routes.title"] == nil)
        #expect(OhMyGhosttySettings(fileURL: url).aiTitleRoute == nil)
    }

    @Test func editingProvidersKeepsModelChoicesAndStoredKeysConsistent() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentials = AICredentialStore(
            fileURL: url.deletingLastPathComponent().appendingPathComponent("credentials.json")
        )
        let kept = try #require(settings.addAIProvider(name: "Kept"))
        let removed = try #require(settings.addAIProvider(name: "Removed"))
        settings.updateAIProvider(kept.id) { $0.mergeModels(["a", "b"]) }
        settings.updateAIProvider(removed.id) { $0.mergeModels(["x"]) }
        try credentials.setAPIKey("kept-test-key", for: kept.id)
        try credentials.setAPIKey("removed-test-key", for: removed.id)
        settings.gitCommitAIRoutes = [
            GitCommitAIRoute(agent: .claude, model: "sonnet"),
            GitCommitAIRoute(provider: kept.id, model: "a"),
            GitCommitAIRoute(provider: kept.id, model: "b"),
            GitCommitAIRoute(provider: removed.id, model: "x"),
        ]
        settings.aiTitleRoute = AITitleRoute(provider: removed.id, model: "x")

        try settings.removeAIProvider(removed.id, credentials: credentials)
        #expect(settings.aiProviders.map(\.id) == [kept.id])
        #expect(settings.gitCommitAIRoutes.map(\.model) == ["sonnet", "a", "b"])
        #expect(settings.aiTitleRoute == nil)
        #expect(credentials.apiKey(for: removed.id) == nil)
        #expect(credentials.apiKey(for: kept.id) == "kept-test-key")

        settings.aiTitleRoute = AITitleRoute(provider: kept.id, model: "b")
        settings.removeAIProviderModel("b", from: kept.id)
        #expect(settings.aiProvider(kept.id)?.models.map(\.id) == ["a"])
        #expect(settings.gitCommitAIRoutes.map(\.model) == ["sonnet", "a"])
        #expect(settings.aiTitleRoute == nil)

        // An edit cannot change the identity the stored key hangs on.
        settings.updateAIProvider(kept.id) { $0.id = UUID(); $0.name = "Renamed" }
        #expect(settings.aiProviders.map(\.id) == [kept.id])
        #expect(settings.aiProvider(kept.id)?.name == "Renamed")
        #expect(settings.aiProviderDirectory(credentials: credentials).providers == settings.aiProviders)
        #expect(OhMyGhosttySettings(fileURL: url).aiProviders == settings.aiProviders)
    }

    @Test func theFirstBuildEndpointMigratesToAConnectionAndTheTitleModel() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try #"{"ai.endpoint.protocol":"anthropic","ai.endpoint.baseURL":" https://proxy.example.com/v1 ","ai.endpoint.model":"claude-test","future.key":"kept"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()

        let provider = try #require(settings.aiProviders.first)
        #expect(settings.aiProviders.count == 1)
        #expect(provider.id == AIProvider.legacyEndpointID)
        #expect(provider.kind == .anthropic)
        #expect(provider.baseURL == "https://proxy.example.com/v1")
        #expect(provider.models.map(\.id) == ["claude-test"])
        #expect(settings.aiTitleRoute == AITitleRoute(provider: provider.id, model: "claude-test"))

        // The old keys are gone from the file, the new ones are saved, and unrelated keys stay.
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(!object.keys.contains { $0.hasPrefix("ai.endpoint.") })
        #expect((object["ai.providers"] as? [[String: Any]])?.count == 1)
        #expect(object["ai.routes.title"] != nil)
        #expect(object["future.key"] as? String == "kept")

        // The migrated connection finds the old single key under the same identity.
        let credentialsURL = url.deletingLastPathComponent().appendingPathComponent("credentials.json")
        try Data(#"{"version":1,"apiKey":"legacy-test-key"}"#.utf8).write(to: credentialsURL)
        let endpoint = settings.aiProviderDirectory(credentials: AICredentialStore(fileURL: credentialsURL))
            .titleEndpoint(settings.aiTitleRoute)
        #expect(endpoint?.apiKey == "legacy-test-key")
        #expect(endpoint?.model == "claude-test")

        // A second load changes nothing.
        let again = OhMyGhosttySettings(fileURL: url)
        #expect(again.aiProviders == settings.aiProviders)
        #expect(again.aiTitleRoute == settings.aiTitleRoute)
    }

    @Test func legacyEndpointKeysNeverReplaceExistingProvidersOrAnIncompleteEndpoint() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let existing = AIProvider(name: "Mine", baseURL: "https://api.example.com")
        let providers = try JSONSerialization.data(withJSONObject: AIProvider.encode([existing]))
        let json = #"{"ai.endpoint.baseURL":"https://old.example.com","ai.endpoint.model":"old","ai.providers":"#
            + (String(bytes: providers, encoding: .utf8) ?? "[]") + "}"
        try json.write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.aiProviders == [existing])
        #expect(settings.aiTitleRoute == nil)

        // Only a model, no base URL: nothing to connect to, so the keys are simply dropped.
        try #"{"ai.endpoint.protocol":"openai","ai.endpoint.model":"gpt-test"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.aiProviders.isEmpty)
        #expect(settings.aiTitleRoute == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(!object.keys.contains { $0.hasPrefix("ai.") })
    }

    @Test func testingEnvironmentIsolatesDefaultSettingsFileURLFromRealHomeDirectory() {
        #expect(OMGApplicationEnvironment.isRunningTests)
        let realConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .path
        #expect(!OhMyGhosttySettings.fileURL.path.hasPrefix(realConfigPath))
    }

    @Test func quickInputOpacityDefaultsClampsAndReloadsFromDisk() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.quickInputOpacity == 0.70)

        settings.quickInputOpacity = 0.0
        #expect(settings.quickInputOpacity == 0.05)

        settings.quickInputOpacity = 1.5
        #expect(settings.quickInputOpacity == 1.0)

        try #"{"keyboard.quickInputOpacity":0.2}"#.write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.quickInputOpacity == 0.2)
    }

    @Test func toggleInboxShortcutDefaultsPersistsAndBindsMenuItem() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(OMGKeyboardShortcut.defaultToggleInbox == OMGKeyboardShortcut(key: "i", modifiers: [.command, .shift]))
        #expect(settings.toggleInboxShortcut == "shift+command+i")
        let descriptor = OhMyGhosttySettings.descriptors.first { $0.id == "keyboard.toggleInbox" }
        #expect(descriptor?.defaultValue == "shift+command+i")
        #expect(descriptor?.category == "keyboard")

        settings.toggleInboxShortcut = "option+command+i"
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.toggleInboxShortcut == "option+command+i")

        let menu = NSMenu(title: "View")
        let item = NSMenuItem(title: "Toggle Inbox", action: #selector(AppDelegate.toggleInbox(_:)), keyEquivalent: "i")
        item.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(item)
        OMGMenuShortcuts.apply(to: menu, settings: restored)
        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask == [.option, .command])

        settings.toggleInboxShortcut = "invalid"
        #expect(settings.toggleInboxShortcut == "shift+command+i")
    }

    @Test func tabInboxContinueMinutesDefaultsPersistsAndValidatesAllowedOptions() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.tabInboxContinueMinutes == 15)
        let descriptor = OhMyGhosttySettings.descriptors.first { $0.id == "tabs.inboxContinueMinutes" }
        #expect(descriptor?.defaultValue == "15")
        #expect(descriptor?.category == "tabs")

        settings.tabInboxContinueMinutes = 3
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabInboxContinueMinutes == 3)

        settings.tabInboxContinueMinutes = 7
        #expect(settings.tabInboxContinueMinutes == 15)

        try #"{"tabs.inboxContinueMinutes":60}"#.write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.tabInboxContinueMinutes == 60)

        try #"{"tabs.inboxContinueMinutes":999}"#.write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.tabInboxContinueMinutes == 15)
    }

    private func temporarySettings() -> (OhMyGhosttySettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        return (OhMyGhosttySettings(fileURL: url), url)
    }
}
