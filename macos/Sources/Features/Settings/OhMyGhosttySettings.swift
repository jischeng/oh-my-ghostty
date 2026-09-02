import Combine
import Foundation

enum OMGApplicationEnvironment {
    static var isDevelopment: Bool {
        Bundle.main.bundleIdentifier == "com.jischeng.omg.debug"
    }

    static func channel(development: Bool = isDevelopment) -> String {
        development ? "debug" : "release"
    }

    static func settingsFileURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        development: Bool = isDevelopment
    ) -> URL {
        homeURL.appendingPathComponent(
            development
                ? ".config/oh-my-ghostty-dev/settings.json"
                : ".config/oh-my-ghostty/settings.json"
        )
    }

    static func applicationSupportURL(
        baseURL: URL? = nil,
        development: Bool = isDevelopment
    ) -> URL {
        let base = baseURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent(
            development ? "OMG Dev" : "OMG",
            isDirectory: true
        )
    }
}

enum TerminalResizeRenderingMode: String, CaseIterable, Identifiable, Sendable {
    case duringDrag
    case onRelease

    var id: String { rawValue }
}

struct OhMyGhosttySettingDescriptor: Codable, Identifiable, Sendable {
    enum ValueType: String, Codable, Sendable {
        case boolean
        case enumeration
        case number
        case string
    }

    let id: String
    let type: ValueType
    let defaultValue: String
    let allowedValues: [String]?
    let minimum: Double?
    let maximum: Double?
    let description: String
    let requiresNewWindow: Bool
    let category: String
}

enum OhMyGhosttyAppearanceSource: String, Codable, Sendable {
    case ohMyGhosttyOverride
    case ghosttyConfig
    case builtInDefault

    var title: String {
        switch self {
        case .ohMyGhosttyOverride: "OMG"
        case .ghosttyConfig: "Ghostty config"
        case .builtInDefault: "Built-in default"
        }
    }
}

struct ResolvedSetting<Value> {
    let effectiveValue: Value
    let source: OhMyGhosttyAppearanceSource
    let overrideValue: Value?
    let inheritedValue: Value?
    let defaultValue: Value
}

enum OhMyGhosttyWindowTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OhMyGhosttyBackgroundBlur: String, CaseIterable, Identifiable {
    case disabled
    case enabled
    case macosGlassRegular
    case macosGlassClear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Off"
        case .enabled: "Blur"
        case .macosGlassRegular: "macOS Glass — Regular"
        case .macosGlassClear: "macOS Glass — Clear"
        }
    }

    var ghosttyValue: String {
        switch self {
        case .disabled: "false"
        case .enabled: "true"
        case .macosGlassRegular: "macos-glass-regular"
        case .macosGlassClear: "macos-glass-clear"
        }
    }
}

enum OhMyGhosttyCursorStyle: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        case .blockHollow: "Hollow Block"
        }
    }
}

struct EffectiveAppearance {
    let windowTheme: ResolvedSetting<String>
    let theme: ResolvedSetting<String>
    let fontFamily: ResolvedSetting<String>
    let fontSize: ResolvedSetting<Double>
    let backgroundOpacity: ResolvedSetting<Double>
    let backgroundBlur: ResolvedSetting<String>
    let cursorStyle: ResolvedSetting<String>
}

enum GhosttyThemeCatalog {
    static func availableThemes(
        resourceURL: URL? = Bundle.main.resourceURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let roots = [
            resourceURL?.appendingPathComponent("ghostty/themes"),
            homeURL.appendingPathComponent(".config/ghostty/themes"),
        ].compactMap { $0 }
        var names = Set<String>()
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where
                (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.insert(entry.lastPathComponent)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum OhMyGhosttyTabPathDisplay: String, CaseIterable, Identifiable {
    case fullPath
    case folderName

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullPath: "Full Path"
        case .folderName: "Current Folder"
        }
    }
}

enum OhMyGhosttyTabRowDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 28
        case .comfortable: 32
        }
    }
}

@MainActor
final class OhMyGhosttySettings: ObservableObject {
    static let shared = OhMyGhosttySettings()
    static let didChangeNotification = Notification.Name("com.oh-my-ghostty.settingsDidChange")
    static let changedKeyUserInfoKey = "changedKey"
    static let appearanceDidChangeNotification = Notification.Name(
        "com.oh-my-ghostty.appearanceDidChange"
    )

    static var fileURL: URL {
        OMGApplicationEnvironment.settingsFileURL()
    }

    static var ghosttyAppearanceOverlayURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("appearance.ghostty")
    }

    static let descriptors: [OhMyGhosttySettingDescriptor] = [
        .init(
            id: "tabs.layout", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: ["horizontal", "vertical"], minimum: nil, maximum: nil,
            description: "Tab presentation used by newly created windows.",
            requiresNewWindow: true, category: "tabs"),
        .init(
            id: "tabs.sidebarWidth", type: .number, defaultValue: "240",
            allowedValues: nil, minimum: 176, maximum: 480,
            description: "Default width of the Vertical Tabs sidebar in points.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.grouping", type: .enumeration, defaultValue: "none",
            allowedValues: GhosttyTabGroupingMode.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Derived grouping applied to Vertical Tabs.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.ordering", type: .enumeration, defaultValue: "manual",
            allowedValues: GhosttyTabOrderingMode.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Canonical tab ordering policy.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.pathDisplay", type: .enumeration, defaultValue: "folderName",
            allowedValues: OhMyGhosttyTabPathDisplay.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Display the full working path or only the current folder in Vertical Tabs.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.showShortcutLabels", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Show configured position shortcuts for the first nine tabs.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.rememberSidebarWidth", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Use the last committed sidebar width as the next window default.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "tabs.sidebarVisible", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Show the Vertical Tabs sidebar by default.",
            requiresNewWindow: false, category: "tabs"),
        .init(
            id: "appearance.windowTheme", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: OhMyGhosttyWindowTheme.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Optional window appearance override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.lightTheme", type: .string, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional Ghostty theme used in Light appearance.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.darkTheme", type: .string, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional Ghostty theme used in Dark appearance.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.fontFamily", type: .string, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Optional terminal font family override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.fontSize", type: .number, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: 6, maximum: 72,
            description: "Optional terminal font size override in points.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.backgroundOpacity", type: .number, defaultValue: "ghostty-config",
            allowedValues: nil, minimum: 0.05, maximum: 1,
            description: "Optional terminal and app-shell background opacity override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.backgroundBlur", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: OhMyGhosttyBackgroundBlur.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Optional Ghostty background blur override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.cursorStyle", type: .enumeration, defaultValue: "ghostty-config",
            allowedValues: OhMyGhosttyCursorStyle.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Optional terminal cursor style override.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.tabRowDensity", type: .enumeration, defaultValue: "compact",
            allowedValues: OhMyGhosttyTabRowDensity.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Vertical tab row density.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "appearance.tabIconSize", type: .number, defaultValue: "16",
            allowedValues: nil, minimum: 12, maximum: 20,
            description: "Vertical tab icon size in points.",
            requiresNewWindow: false, category: "appearance"),
        .init(
            id: "notifications.taskComplete", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Allow completion events to request a notification.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "notifications.attention", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Allow attention events to request a notification.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "notifications.sound", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Play a sound for enabled agent notifications.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "agents.statusHooks", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Accept normalized activity events from agent adapters.",
            requiresNewWindow: false, category: "plugins"),
        .init(
            id: "agents.openQuickInputOnStart", type: .boolean, defaultValue: "false",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Open Quick Input when an agent starts without changing keyboard focus.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInput", type: .string,
            defaultValue: OMGKeyboardShortcut.defaultQuickInput.storageValue,
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Shortcut that toggles the Agent Quick Input composer.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "keyboard.quickInputHeight", type: .number, defaultValue: "252",
            allowedValues: nil, minimum: 140, maximum: 480,
            description: "Last committed Agent Quick Input dock height in points.",
            requiresNewWindow: false, category: "keyboard"),
        .init(
            id: "terminal.resizeRendering", type: .enumeration,
            defaultValue: TerminalResizeRenderingMode.onRelease.rawValue,
            allowedValues: TerminalResizeRenderingMode.allCases.map(\.rawValue),
            minimum: nil, maximum: nil,
            description: "Choose whether terminal content reflows during a resize or once on release.",
            requiresNewWindow: false, category: "terminal"),
        .init(
            id: "general.language", type: .enumeration, defaultValue: "system",
            allowedValues: OhMyGhosttyLanguage.allCases.map(\.rawValue), minimum: nil, maximum: nil,
            description: "Settings display language. system follows the macOS preferred language.",
            requiresNewWindow: false, category: "general"),
        .init(
            id: "sessions.restoreOnLaunch", type: .boolean, defaultValue: "true",
            allowedValues: nil, minimum: nil, maximum: nil,
            description: "Restore open windows, tabs, splits, and active agent sessions.",
            requiresNewWindow: false, category: "general"),
    ]

    @Published var tabLayout: Ghostty.Config.MacOSTabLayout = .vertical {
        didSet { persist("tabs.layout", tabLayout.rawValue) }
    }
    @Published var defaultSidebarWidth: Double = 240 {
        didSet {
            let clamped = min(max(defaultSidebarWidth, 176), 480)
            if defaultSidebarWidth != clamped {
                defaultSidebarWidth = clamped
            } else {
                persist("tabs.sidebarWidth", clamped)
            }
        }
    }
    @Published var groupingMode: GhosttyTabGroupingMode = .none {
        didSet { persist("tabs.grouping", groupingMode.rawValue) }
    }
    @Published var orderingMode: GhosttyTabOrderingMode = .manual {
        didSet { persist("tabs.ordering", orderingMode.rawValue) }
    }
    @Published var tabPathDisplay: OhMyGhosttyTabPathDisplay = .folderName {
        didSet { persist("tabs.pathDisplay", tabPathDisplay.rawValue) }
    }
    @Published var showShortcutLabels = true {
        didSet { persist("tabs.showShortcutLabels", showShortcutLabels) }
    }
    @Published var rememberSidebarWidth = true {
        didSet { persist("tabs.rememberSidebarWidth", rememberSidebarWidth) }
    }
    @Published var sidebarVisible = true {
        didSet { persist("tabs.sidebarVisible", sidebarVisible) }
    }
    @Published var windowThemeOverride: OhMyGhosttyWindowTheme? {
        didSet { persistOptional("appearance.windowTheme", windowThemeOverride?.rawValue) }
    }
    @Published var lightThemeOverride: String? {
        didSet {
            persistOptional("appearance.lightTheme", Self.normalized(lightThemeOverride))
        }
    }
    @Published var darkThemeOverride: String? {
        didSet {
            persistOptional("appearance.darkTheme", Self.normalized(darkThemeOverride))
        }
    }
    @Published var fontFamilyOverride: String? {
        didSet {
            persistOptional("appearance.fontFamily", Self.normalized(fontFamilyOverride))
        }
    }
    @Published var fontSizeOverride: Double? {
        didSet {
            let clamped = fontSizeOverride.map { min(max($0, 6), 72) }
            if fontSizeOverride != clamped {
                fontSizeOverride = clamped
            } else {
                persistOptional("appearance.fontSize", clamped)
            }
        }
    }
    @Published var backgroundOpacityOverride: Double? {
        didSet {
            let clamped = backgroundOpacityOverride.map { min(max($0, 0.05), 1) }
            if backgroundOpacityOverride != clamped {
                backgroundOpacityOverride = clamped
            } else {
                persistOptional("appearance.backgroundOpacity", clamped)
            }
        }
    }
    @Published var backgroundBlurOverride: OhMyGhosttyBackgroundBlur? {
        didSet { persistOptional("appearance.backgroundBlur", backgroundBlurOverride?.rawValue) }
    }
    @Published var cursorStyleOverride: OhMyGhosttyCursorStyle? {
        didSet { persistOptional("appearance.cursorStyle", cursorStyleOverride?.rawValue) }
    }
    @Published var tabRowDensity: OhMyGhosttyTabRowDensity = .compact {
        didSet { persist("appearance.tabRowDensity", tabRowDensity.rawValue) }
    }
    @Published var tabIconSize: Double = 16 {
        didSet {
            let clamped = min(max(tabIconSize, 12), 20)
            if tabIconSize != clamped {
                tabIconSize = clamped
            } else {
                persist("appearance.tabIconSize", clamped)
            }
        }
    }
    @Published var notifyTaskComplete = true {
        didSet { persist("notifications.taskComplete", notifyTaskComplete) }
    }
    @Published var notifyAttention = true {
        didSet { persist("notifications.attention", notifyAttention) }
    }
    @Published var notificationSound = false {
        didSet { persist("notifications.sound", notificationSound) }
    }
    @Published var agentStatusHooksEnabled = true {
        didSet { persist("agents.statusHooks", agentStatusHooksEnabled) }
    }
    @Published var openQuickInputOnAgentStart = false {
        didSet {
            persist("agents.openQuickInputOnStart", openQuickInputOnAgentStart)
        }
    }
    @Published var quickInputShortcut = OMGKeyboardShortcut.defaultQuickInput.storageValue {
        didSet {
            let normalized = OMGKeyboardShortcut(storageValue: quickInputShortcut)?.storageValue
                ?? OMGKeyboardShortcut.defaultQuickInput.storageValue
            if quickInputShortcut != normalized {
                quickInputShortcut = normalized
            } else {
                persist("keyboard.quickInput", normalized)
            }
        }
    }
    @Published var quickInputHeight = Double(AgentQuickInputMetrics.defaultHeight) {
        didSet {
            let clamped = min(max(quickInputHeight, 140), 480)
            if quickInputHeight != clamped {
                quickInputHeight = clamped
            } else {
                persist("keyboard.quickInputHeight", clamped)
            }
        }
    }
    @Published var terminalResizeRendering: TerminalResizeRenderingMode = .onRelease {
        didSet { persist("terminal.resizeRendering", terminalResizeRendering.rawValue) }
    }
    @Published var restoreSessionsOnLaunch = true {
        didSet { persist("sessions.restoreOnLaunch", restoreSessionsOnLaunch) }
    }
    @Published var language: OhMyGhosttyLanguage = .system {
        didSet { persist("general.language", language.rawValue) }
    }
    @Published private(set) var lastError: String?

    private var chosen: [String: Any] = [:]
    private var ghosttyTabLayout: Ghostty.Config.MacOSTabLayout = .vertical
    private var isApplying = false
    private let fileURL: URL
    private let appearanceOverlayURL: URL
    private var appearanceNotificationWorkItem: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if fileURL == nil { Self.seedDevelopmentSettingsIfNeeded() }
        let fileURL = fileURL ?? Self.fileURL
        self.fileURL = fileURL
        self.appearanceOverlayURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("appearance.ghostty")
        reloadFromDisk()
    }

    static func seedDevelopmentSettingsIfNeeded(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        development: Bool = OMGApplicationEnvironment.isDevelopment
    ) {
        guard development else { return }
        let destination = OMGApplicationEnvironment.settingsFileURL(
            homeURL: homeURL,
            development: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let source = OMGApplicationEnvironment.settingsFileURL(
            homeURL: homeURL,
            development: false
        )
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            // Loading defaults remains safe when the optional seed cannot be copied.
        }
    }

    func configureGhosttyFallback(tabLayout: Ghostty.Config.MacOSTabLayout) {
        ghosttyTabLayout = tabLayout
        guard chosen["tabs.layout"] == nil else { return }
        applyWithoutPersisting {
            self.tabLayout = tabLayout
        }
    }

    func reloadFromDisk() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    throw SettingsError.invalidRoot
                }
                chosen = dictionary
            } else {
                chosen = [:]
            }
            let migratedPathDisplay = migratePathDisplayDefault()
            let migratedResizeRendering = migrateResizeRenderingSetting()
            applyChosenValues()
            if migratedPathDisplay || migratedResizeRendering { save() }
            lastError = nil
            writeAppearanceOverlay()
            notifyRuntime()
            notifyAppearanceRuntime()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func migratePathDisplayDefault() -> Bool {
        let marker = "_migrations.tabsPathDisplayFolderName"
        guard chosen[marker] == nil else { return false }
        chosen["tabs.pathDisplay"] = OhMyGhosttyTabPathDisplay.folderName.rawValue
        chosen[marker] = 1
        return true
    }

    private func migrateResizeRenderingSetting() -> Bool {
        let legacyKey = "terminal.smoothResize"
        guard chosen["terminal.resizeRendering"] == nil,
              let enabled = chosen.removeValue(forKey: legacyKey) as? Bool else {
            return false
        }
        chosen["terminal.resizeRendering"] = enabled
            ? TerminalResizeRenderingMode.duringDrag.rawValue
            : TerminalResizeRenderingMode.onRelease.rawValue
        return true
    }

    func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        save()
    }

    func resetTabs() {
        let keys = chosen.keys.filter { $0.hasPrefix("tabs.") }
        for key in keys { chosen.removeValue(forKey: key) }
        applyChosenValues()
        save()
        notifyRuntime()
    }

    func resetAppearance() {
        let keys = chosen.keys.filter {
            $0.hasPrefix("appearance.") &&
                $0 != "appearance.tabRowDensity" &&
                $0 != "appearance.tabIconSize"
        }
        for key in keys { chosen.removeValue(forKey: key) }
        applyChosenValues()
        save()
        notifyRuntime()
        notifyAppearanceRuntime()
    }

    /// Ensures the generated Ghostty overlay exists before Ghostty starts.
    /// The overlay is app-owned and never mutates the user's Ghostty config.
    func prepareAppearanceOverlay() {
        writeAppearanceOverlay()
    }

    func effectiveAppearance(using config: Ghostty.Config) -> EffectiveAppearance {
        let inheritedWindowTheme = config.windowTheme ?? "auto"
        let inheritedBlur = Self.describe(config.backgroundBlur)
        let overrideTheme = resolvedThemeOverride
        return .init(
            windowTheme: resolve(
                override: windowThemeOverride?.rawValue,
                inherited: inheritedWindowTheme,
                defaultValue: "auto"
            ),
            theme: resolve(
                override: overrideTheme,
                inherited: "Ghostty configuration",
                defaultValue: "Built-in Ghostty theme"
            ),
            fontFamily: resolve(
                override: Self.normalized(fontFamilyOverride),
                inherited: "Ghostty configuration",
                defaultValue: "System monospace"
            ),
            fontSize: resolve(
                override: fontSizeOverride,
                inherited: config.fontSize,
                defaultValue: 13
            ),
            backgroundOpacity: resolve(
                override: backgroundOpacityOverride,
                inherited: config.backgroundOpacity,
                defaultValue: 1
            ),
            backgroundBlur: resolve(
                override: backgroundBlurOverride?.title,
                inherited: inheritedBlur,
                defaultValue: "Off"
            ),
            cursorStyle: resolve(
                override: cursorStyleOverride?.rawValue,
                inherited: config.cursorStyle,
                defaultValue: "block"
            )
        )
    }

    func schemaData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Self.descriptors)
    }

    private func applyChosenValues() {
        applyWithoutPersisting {
            tabLayout = enumValue("tabs.layout", fallback: ghosttyTabLayout)
            defaultSidebarWidth = numberValue("tabs.sidebarWidth", fallback: 240, range: 176...480)
            groupingMode = enumValue("tabs.grouping", fallback: .none)
            orderingMode = enumValue("tabs.ordering", fallback: .manual)
            tabPathDisplay = enumValue("tabs.pathDisplay", fallback: .folderName)
            showShortcutLabels = boolValue("tabs.showShortcutLabels", fallback: true)
            rememberSidebarWidth = boolValue("tabs.rememberSidebarWidth", fallback: true)
            sidebarVisible = boolValue("tabs.sidebarVisible", fallback: true)
            windowThemeOverride = optionalEnumValue("appearance.windowTheme")
            lightThemeOverride = optionalStringValue("appearance.lightTheme")
            darkThemeOverride = optionalStringValue("appearance.darkTheme")
            fontFamilyOverride = optionalStringValue("appearance.fontFamily")
            fontSizeOverride = optionalNumberValue("appearance.fontSize", range: 6...72)
            backgroundOpacityOverride = optionalNumberValue(
                "appearance.backgroundOpacity",
                range: 0.05...1
            )
            backgroundBlurOverride = optionalEnumValue("appearance.backgroundBlur")
            cursorStyleOverride = optionalEnumValue("appearance.cursorStyle")
            tabRowDensity = enumValue("appearance.tabRowDensity", fallback: .compact)
            tabIconSize = numberValue("appearance.tabIconSize", fallback: 16, range: 12...20)
            notifyTaskComplete = boolValue("notifications.taskComplete", fallback: true)
            notifyAttention = boolValue("notifications.attention", fallback: true)
            notificationSound = boolValue("notifications.sound", fallback: false)
            agentStatusHooksEnabled = boolValue("agents.statusHooks", fallback: true)
            openQuickInputOnAgentStart = boolValue(
                "agents.openQuickInputOnStart",
                fallback: false
            )
            quickInputShortcut = validatedShortcutValue(
                "keyboard.quickInput",
                fallback: OMGKeyboardShortcut.defaultQuickInput.storageValue
            )
            quickInputHeight = numberValue(
                "keyboard.quickInputHeight",
                fallback: Double(AgentQuickInputMetrics.defaultHeight),
                range: 140...480
            )
            terminalResizeRendering = enumValue(
                "terminal.resizeRendering",
                fallback: .onRelease
            )
            restoreSessionsOnLaunch = boolValue(
                "sessions.restoreOnLaunch",
                fallback: true
            )
            language = enumValue("general.language", fallback: .system)
        }
    }

    private func enumValue<Value: RawRepresentable>(
        _ key: String,
        fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = chosen[key] as? String, let value = Value(rawValue: raw) else {
            return fallback
        }
        return value
    }

    private func optionalEnumValue<Value: RawRepresentable>(_ key: String) -> Value?
    where Value.RawValue == String {
        guard let raw = chosen[key] as? String else { return nil }
        return Value(rawValue: raw)
    }

    private func optionalStringValue(_ key: String) -> String? {
        guard let raw = chosen[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func validatedShortcutValue(_ key: String, fallback: String) -> String {
        guard let raw = chosen[key] as? String,
              let shortcut = OMGKeyboardShortcut(storageValue: raw) else {
            return fallback
        }
        return shortcut.storageValue
    }

    private func optionalNumberValue(
        _ key: String,
        range: ClosedRange<Double>
    ) -> Double? {
        guard let value = (chosen[key] as? NSNumber)?.doubleValue else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func boolValue(_ key: String, fallback: Bool) -> Bool {
        chosen[key] as? Bool ?? fallback
    }

    private func numberValue(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        let value = (chosen[key] as? NSNumber)?.doubleValue ?? fallback
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func applyWithoutPersisting(_ body: () -> Void) {
        isApplying = true
        body()
        isApplying = false
    }

    private func persist(_ key: String, _ value: Any) {
        guard !isApplying else { return }
        chosen[key] = value
        save()
        notifyRuntime(changedKey: key)
        if key.hasPrefix("appearance.") { notifyAppearanceRuntime() }
    }

    private func persistOptional(_ key: String, _ value: Any?) {
        guard !isApplying else { return }
        if let value {
            chosen[key] = value
        } else {
            chosen.removeValue(forKey: key)
        }
        save()
        notifyRuntime(changedKey: key)
        notifyAppearanceRuntime()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: chosen,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
            writeAppearanceOverlay()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func notifyRuntime(changedKey: String? = nil) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: changedKey.map { [Self.changedKeyUserInfoKey: $0] }
        )
    }

    private func notifyAppearanceRuntime() {
        appearanceNotificationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: Self.appearanceDidChangeNotification,
                object: self
            )
        }
        appearanceNotificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private var resolvedThemeOverride: String? {
        switch (Self.normalized(lightThemeOverride), Self.normalized(darkThemeOverride)) {
        case let (light?, dark?) where light == dark:
            light
        case let (light?, dark?):
            "light:\(light),dark:\(dark)"
        case let (theme?, nil), let (nil, theme?):
            theme
        case (nil, nil):
            nil
        }
    }

    private func writeAppearanceOverlay() {
        do {
            try FileManager.default.createDirectory(
                at: appearanceOverlayURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var lines: [String] = [
                "# Generated by OMG. Edit settings.json, not this file.",
            ]
            if let windowThemeOverride {
                lines.append("window-theme = \(windowThemeOverride.rawValue)")
            }
            if let theme = resolvedThemeOverride {
                lines.append("theme = \(Self.safeConfigValue(theme))")
            }
            if let fontFamilyOverride = Self.normalized(fontFamilyOverride) {
                lines.append("font-family =")
                lines.append("font-family = \(Self.safeConfigValue(fontFamilyOverride))")
            }
            if let fontSizeOverride {
                lines.append("font-size = \(fontSizeOverride)")
            }
            if let backgroundOpacityOverride {
                lines.append("background-opacity = \(backgroundOpacityOverride)")
            }
            if let backgroundBlurOverride {
                lines.append("background-blur = \(backgroundBlurOverride.ghosttyValue)")
            }
            if let cursorStyleOverride {
                lines.append("cursor-style = \(cursorStyleOverride.rawValue)")
            }
            let content = lines.joined(separator: "\n") + "\n"
            try content.write(to: appearanceOverlayURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolve<Value>(
        override: Value?,
        inherited: Value?,
        defaultValue: Value
    ) -> ResolvedSetting<Value> {
        if let override {
            return .init(
                effectiveValue: override,
                source: .ohMyGhosttyOverride,
                overrideValue: override,
                inheritedValue: inherited,
                defaultValue: defaultValue
            )
        }
        if let inherited {
            return .init(
                effectiveValue: inherited,
                source: .ghosttyConfig,
                overrideValue: nil,
                inheritedValue: inherited,
                defaultValue: defaultValue
            )
        }
        return .init(
            effectiveValue: defaultValue,
            source: .builtInDefault,
            overrideValue: nil,
            inheritedValue: nil,
            defaultValue: defaultValue
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func safeConfigValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func describe(_ blur: Ghostty.Config.BackgroundBlur) -> String {
        switch blur {
        case .disabled: "Off"
        case .radius(let radius): "Radius \(radius)"
        case .macosGlassRegular: "macOS Glass — Regular"
        case .macosGlassClear: "macOS Glass — Clear"
        }
    }

    private enum SettingsError: LocalizedError {
        case invalidRoot

        var errorDescription: String? {
            "The settings file must contain one JSON object."
        }
    }
}
