import Foundation

/// The OMG settings display language. `system` follows the macOS preferred
/// language; explicit values pin the UI regardless of system settings.
enum OhMyGhosttyLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
}

/// Resolved display strings for the Settings window. English is the source
/// language and Simplified Chinese is the first translation. Strings are kept
/// beside their translation so review and future languages stay mechanical.
struct SettingsStrings: Equatable, Sendable {
    let languageCode: String

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        switch language {
        case .english:
            languageCode = "en"
        case .simplifiedChinese:
            languageCode = "zh-Hans"
        case .system:
            languageCode = preferredLanguages.first.map {
                $0.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
            } ?? "en"
        }
    }

    var isChinese: Bool { languageCode.hasPrefix("zh") }

    private func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    // MARK: Window and navigation

    var windowTitle: String { t("Settings", "设置") }

    func tabTitle(_ tab: OhMyGhosttySettingsTab) -> String {
        switch tab {
        case .general: t("General", "通用")
        case .appearance: t("Appearance", "外观")
        case .tabs: t("Tabs", "标签页")
        case .terminal: t("Terminal", "终端")
        case .keyboard: t("Keyboard", "键盘")
        case .plugins: t("Plugins", "插件")
        case .advanced: t("Advanced", "高级")
        }
    }

    // MARK: General

    var languageSection: String { t("Language", "语言") }
    var languageLabel: String { t("Display Language", "显示语言") }
    var languageSystem: String { t("Follow System", "跟随系统") }
    var languageCaption: String {
        t(
            "Follow System uses the macOS preferred language. Changes apply immediately.",
            "“跟随系统”使用 macOS 首选语言，更改后立即生效。"
        )
    }

    var sessionsSection: String { t("Sessions", "会话") }
    var restoreSessionsLabel: String {
        t("Restore Windows and Agent Sessions", "恢复窗口与 Agent 会话")
    }
    var restoreSessionsCaption: String {
        t(
            "Restores open windows, tabs, splits, working directories, and agents that were still running when OMG quit.",
            "恢复 OMG 退出时仍然打开的窗口、标签页、分屏、工作目录以及仍在运行的 Agent。"
        )
    }
    var configurationSection: String { t("Configuration", "配置") }
    var settingsFileLabel: String { t("OMG Settings", "OMG 设置文件") }
    var precedenceLabel: String { t("Precedence", "优先级") }
    var precedenceValue: String {
        t("Runtime → OMG → Ghostty → Defaults", "运行时 → OMG → Ghostty → 默认值")
    }
    var configurationCaption: String {
        t(
            "Tab layout, appearance, and plugin preferences each have one canonical page.",
            "标签页布局、外观和插件偏好各自只有一个规范设置页。"
        )
    }

    // MARK: Appearance

    var windowSection: String { t("Window", "窗口") }
    var appearancePickerLabel: String { t("Appearance", "外观") }
    var ghosttyConfigOption: String { t("Ghostty config", "跟随 Ghostty 配置") }

    func windowThemeTitle(_ theme: OhMyGhosttyWindowTheme) -> String {
        switch theme {
        case .system: t("System", "跟随系统")
        case .light: t("Light", "浅色")
        case .dark: t("Dark", "深色")
        }
    }

    var effectivePrefix: String { t("Effective", "生效值") }

    func appearanceSourceTitle(_ source: OhMyGhosttyAppearanceSource) -> String {
        switch source {
        case .ohMyGhosttyOverride: "OMG"
        case .ghosttyConfig: t("Ghostty config", "Ghostty 配置")
        case .builtInDefault: t("Built-in default", "内置默认值")
        }
    }

    var terminalThemeSection: String { t("Terminal Theme", "终端主题") }
    var lightThemeLabel: String { t("Light Theme", "浅色主题") }
    var darkThemeLabel: String { t("Dark Theme", "深色主题") }
    var resolvedBackgroundLabel: String { t("Resolved Background", "实际背景色") }
    var themeCaption: String {
        t(
            "Foreground, selection, and palette remain owned by the selected Ghostty theme.",
            "前景色、选区颜色和调色板仍由所选 Ghostty 主题决定。"
        )
    }

    var fontSection: String { t("Font", "字体") }
    var fontFamilyLabel: String { t("Font Family", "字体") }
    var inheritGhosttyPlaceholder: String { t("Inherit Ghostty config", "继承 Ghostty 配置") }
    var fontSizeLabel: String { t("Font Size", "字号") }

    var transparencySection: String { t("Transparency", "透明度") }
    var backgroundOpacityLabel: String { t("Background Opacity", "背景不透明度") }
    var backgroundBlurLabel: String { t("Background Blur", "背景模糊") }

    func blurTitle(_ blur: OhMyGhosttyBackgroundBlur) -> String {
        switch blur {
        case .disabled: t("Off", "关闭")
        case .enabled: t("Blur", "模糊")
        case .macosGlassRegular: "macOS Glass — " + t("Regular", "常规")
        case .macosGlassClear: "macOS Glass — " + t("Clear", "通透")
        }
    }

    var cursorSection: String { t("Cursor", "光标") }
    var cursorStyleLabel: String { t("Style", "样式") }

    func cursorTitle(_ cursor: OhMyGhosttyCursorStyle) -> String {
        switch cursor {
        case .block: t("Block", "方块")
        case .bar: t("Bar", "竖线")
        case .underline: t("Underline", "下划线")
        case .blockHollow: t("Hollow Block", "空心方块")
        }
    }

    var appearanceTabsSection: String { t("Tabs", "标签页") }
    var rowDensityLabel: String { t("Row Density", "行密度") }

    func densityTitle(_ density: OhMyGhosttyTabRowDensity) -> String {
        switch density {
        case .compact: t("Compact", "紧凑")
        case .comfortable: t("Comfortable", "宽松")
        }
    }

    var tabIconSizeLabel: String { t("Icon Size", "图标大小") }
    var appearanceLiveCaption: String {
        t(
            "Changes apply live to existing terminals without restarting the shell.",
            "更改会实时应用到已有终端，无需重启 shell。"
        )
    }
    var resetAppearanceButton: String { t("Reset to Ghostty", "恢复为 Ghostty 配置") }

    // MARK: Tabs

    var layoutSection: String { t("Layout", "布局") }
    var tabLayoutLabel: String { t("Tab Layout", "标签页布局") }
    var horizontalOption: String { t("Horizontal", "水平") }
    var verticalOption: String { t("Vertical", "垂直") }
    var tabLayoutCaption: String {
        t(
            "Applies to newly created windows; existing terminals are not rebuilt.",
            "仅对新创建的窗口生效；已有终端不会重建。"
        )
    }
    var showSidebarLabel: String { t("Show Sidebar", "显示侧边栏") }
    var sidebarWidthLabel: String { t("Sidebar Width", "侧边栏宽度") }
    var rememberSidebarWidthLabel: String {
        t("Remember Resized Width", "记住调整后的宽度")
    }

    var organizationSection: String { t("Organization", "组织方式") }
    var groupingLabel: String { t("Grouping", "分组") }

    func groupingTitle(_ mode: GhosttyTabGroupingMode) -> String {
        switch mode {
        case .none: t("No Grouping", "不分组")
        case .project: t("By Project", "按项目")
        case .date: t("By Date", "按日期")
        }
    }

    var pathDisplayLabel: String { t("Path Display", "路径显示") }

    func pathDisplayTitle(_ mode: OhMyGhosttyTabPathDisplay) -> String {
        switch mode {
        case .fullPath: t("Full Path", "完整路径")
        case .folderName: t("Current Folder", "当前文件夹")
        }
    }

    var orderingLabel: String { t("Ordering", "排序") }

    func orderingTitle(_ mode: GhosttyTabOrderingMode) -> String {
        switch mode {
        case .manual: t("Manual", "手动")
        case .created: t("Created Time", "创建时间")
        case .recentlyUsed: t("Recently Used", "最近使用")
        }
    }

    var showShortcutLabelsLabel: String { t("Show Shortcut Labels", "显示快捷键标签") }
    var resetTabsButton: String { t("Reset Tabs Settings", "重置标签页设置") }

    // MARK: Terminal and Keyboard

    var ghosttySection: String { "Ghostty" }
    var openGhosttyConfigButton: String { t("Open Ghostty Configuration", "打开 Ghostty 配置") }
    var keybindingsSection: String { t("Ghostty Keybindings", "Ghostty 快捷键") }
    var keybindingsCaption: String {
        t(
            "Keyboard shortcuts are defined by Ghostty configuration. Position labels are configured once in Tabs.",
            "键盘快捷键由 Ghostty 配置定义。位置标签在“标签页”中统一设置。"
        )
    }

    // MARK: Plugins

    var officialPluginsSection: String { t("Official Plugins", "官方插件") }
    var officialPluginsCaption: String {
        t(
            "Official plugins are installed independently from the OMG app. SSH uses your existing OpenSSH configuration and credentials. Built-in agent hook adapters are configured below.",
            "官方插件独立于 OMG 应用安装。SSH 使用你现有的 OpenSSH 配置与凭据。内置 Agent 状态适配器在下方配置。"
        )
    }
    var installFromGitHubSection: String { t("Install from GitHub", "从 GitHub 安装") }
    var installButton: String { t("Install", "安装") }
    var installFromGitHubCaption: String {
        t(
            "Only HTTPS GitHub repositories with a validated manifest.json are accepted. Installed external executables remain disabled until the supervised runtime is available.",
            "仅接受带有效 manifest.json 的 HTTPS GitHub 仓库。在受监管的运行时可用之前，已安装的外部可执行文件保持禁用。"
        )
    }
    var invalidGitHubURL: String {
        t("Enter a valid HTTPS GitHub repository URL.", "请输入有效的 HTTPS GitHub 仓库地址。")
    }

    func pluginOperationLabel(_ operation: String) -> String {
        switch operation {
        case "Installing": t("Installing", "安装中")
        case "Disabling": t("Disabling", "禁用中")
        case "Enabling": t("Enabling", "启用中")
        case "Uninstalling": t("Uninstalling", "卸载中")
        case "Downloading": t("Downloading", "下载中")
        default: operation
        }
    }

    var pluginNotInstalled: String { t("Not Installed", "未安装") }
    var pluginEnabled: String { t("Enabled", "已启用") }
    var pluginDisabled: String { t("Disabled", "已禁用") }
    var pluginDisableButton: String { t("Disable", "禁用") }
    var pluginEnableButton: String { t("Enable", "启用") }
    var pluginUpdateButton: String { t("Update", "更新") }
    var pluginUninstallButton: String { t("Uninstall", "卸载") }
    var sshPluginCaption: String {
        t(
            "SSH aliases and remote Files through the system OpenSSH/SFTP client.",
            "通过系统 OpenSSH/SFTP 客户端使用 SSH 别名与远程文件。"
        )
    }
    var genericPluginCaption: String { t("OMG plugin", "OMG 插件") }

    var agentIntegrationSection: String { t("Agent Integration", "Agent 集成") }
    var agentStatusHooksLabel: String {
        t("Enable Normalized Status Events", "启用规范化状态事件")
    }
    var agentBuiltInDetection: String { t("Built-in Detection", "内置检测") }
    var agentHooksMissing: String { t("Hooks Not Installed", "未安装 Hooks") }
    var agentHooksUpdateRequired: String { t("Hook Update Required", "需要更新 Hooks") }
    var agentHooksCurrent: String { t("Hooks Installed", "已安装 Hooks") }
    var agentUpdateButton: String { t("Update", "更新") }
    var agentInstallButton: String { t("Install", "安装") }
    var agentRemoveButton: String { t("Remove", "移除") }
    var exportSSHInstallerButton: String { t("Export SSH Installer…", "导出 SSH 安装脚本…") }
    var agentHooksCaption: String {
        t(
            "Hooks write bounded presentation-only OSC events to the owning terminal. Exported hooks can be reviewed and run explicitly in an SSH account. Agent icons and status are presented by Vertical Tabs; Horizontal keeps Ghostty's native tab UI.",
            "Hooks 只向所属终端写入受限的展示类 OSC 事件。导出的脚本可以先审阅，再在 SSH 账户中显式执行。Agent 图标与状态由垂直标签页展示；水平标签页保持 Ghostty 原生界面。"
        )
    }

    var notificationsSection: String { t("Notifications", "通知") }
    var notifyTaskCompleteLabel: String { t("Task Complete", "任务完成") }
    var notifyAttentionLabel: String { t("Attention Required", "需要注意") }
    var notificationSoundLabel: String { t("Play Sound", "播放声音") }

    // MARK: Advanced

    var forkSettingsSection: String { t("Settings File", "设置文件") }
    var fileLabel: String { t("File", "文件") }
    var openFileButton: String { t("Open File", "打开文件") }
    var reloadButton: String { t("Reload", "重新加载") }
    var revealButton: String { t("Reveal", "在访达中显示") }
    var resetThemeHelp: String { t("Reset to Ghostty config", "恢复为 Ghostty 配置") }
}
