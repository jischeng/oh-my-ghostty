import Foundation

/// Tooltips of the window chrome controls: the sidebar toggles, New Tab and
/// the overflow menus. Shortcuts are the user's configured ones.
struct ChromeStrings: Equatable, Sendable {
    private let settings: SettingsStrings
    private let sidebarShortcut: String
    private let inspectorShortcut: String

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages,
        sidebarShortcut: String = OMGKeyboardShortcut.defaultToggleSidebar.storageValue,
        inspectorShortcut: String = OMGKeyboardShortcut.defaultToggleInspector.storageValue
    ) {
        self.settings = SettingsStrings(language: language, preferredLanguages: preferredLanguages)
        self.sidebarShortcut = sidebarShortcut
        self.inspectorShortcut = inspectorShortcut
    }

    @MainActor static var current: Self {
        let settings = OhMyGhosttySettings.shared
        return .init(
            language: settings.language,
            sidebarShortcut: settings.toggleSidebarShortcut,
            inspectorShortcut: settings.toggleInspectorShortcut
        )
    }

    private func t(_ english: String, _ chinese: String) -> String {
        settings.isChinese ? chinese : english
    }

    /// Appends the shortcut only when one is configured and valid.
    private func withShortcut(_ title: String, _ storageValue: String) -> String {
        guard let shortcut = OMGKeyboardShortcut(storageValue: storageValue) else { return title }
        return "\(title) · \(shortcut.displayValue)"
    }

    func toggleSidebar(visible: Bool) -> String {
        withShortcut(visible ? t("Hide Sidebar", "隐藏侧边栏") : t("Show Sidebar", "显示侧边栏"), sidebarShortcut)
    }

    var toggleSidebar: String {
        withShortcut(t("Show or Hide Sidebar", "显示或隐藏侧边栏"), sidebarShortcut)
    }

    func toggleInspector(visible: Bool) -> String {
        withShortcut(
            visible ? t("Hide Right Sidebar", "隐藏右侧边栏") : t("Show Right Sidebar", "显示右侧边栏"),
            inspectorShortcut
        )
    }

    var newTab: String { t("New Tab", "新建标签页") }
    var organizeTabs: String { t("Organize Tabs", "整理标签页") }
    var morePanes: String { t("More Panes", "更多面板") }
    /// Tab group for panes whose directory belongs to no project.
    var otherProjects: String { t("Other", "其他") }
}
