import Foundation

/// Tooltips of the window chrome controls: the sidebar toggles, New Tab and
/// the overflow menus. Shortcuts are the user's configured ones.
struct ChromeStrings: Equatable, Sendable {
    private let settings: SettingsStrings
    private let sidebarShortcut: String
    private let inboxShortcut: String
    private let inspectorShortcut: String

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages,
        sidebarShortcut: String = OMGKeyboardShortcut.defaultToggleSidebar.storageValue,
        inboxShortcut: String = "",
        inspectorShortcut: String = OMGKeyboardShortcut.defaultToggleInspector.storageValue
    ) {
        self.settings = SettingsStrings(language: language, preferredLanguages: preferredLanguages)
        self.sidebarShortcut = sidebarShortcut
        self.inboxShortcut = inboxShortcut
        self.inspectorShortcut = inspectorShortcut
    }

    @MainActor static var current: Self {
        let settings = OhMyGhosttySettings.shared
        return .init(
            language: settings.language,
            sidebarShortcut: settings.toggleSidebarShortcut,
            inboxShortcut: settings.toggleInboxShortcut,
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
    var resetZoom: String { t("Reset Zoom", "还原缩放") }
    var resetSplitZoom: String { t("Reset Split Zoom", "还原分屏缩放") }

    // Tab sidebar menus
    var renameTab: String { t("Rename Tab…", "重命名标签页…") }
    var autoRenameTab: String { t("Auto-Rename Tab", "自动重命名") }
    var autoRenameWorkspaceTabs: String { t("Auto-Rename Workspace Tabs", "自动重命名当前工作区标签") }
    var moveToWorkspace: String { t("Move to Workspace", "移到工作区") }
    var moveTabToNewWindow: String { t("Move Tab to New Window", "将标签页移到新窗口") }
    var closeOtherTabs: String { t("Close Other Tabs", "关闭其他标签页") }
    var closeTab: String { t("Close Tab", "关闭标签页") }
    var groupHeader: String { t("GROUP", "分组") }
    var orderHeader: String { t("ORDER", "排序") }
    func groupingTitle(_ mode: GhosttyTabGroupingMode) -> String { settings.groupingTitle(mode) }
    func orderingTitle(_ mode: GhosttyTabOrderingMode) -> String { settings.orderingTitle(mode) }

    // Tab groups
    /// Tab group for panes whose directory belongs to no project.
    var otherProjects: String { t("Other", "其他") }
    var today: String { t("Today", "今天") }
    var yesterday: String { t("Yesterday", "昨天") }
    var older: String { t("Older", "更早") }

    // Tab inbox
    var inbox: String { t("Inbox", "收件箱") }
    /// Tooltip of the inbox toggle. While the Tabs view is shown it also says
    /// how many tabs wait for the user.
    func toggleInbox(shown: Bool, attention: Int = 0) -> String {
        let base: String
        if shown {
            base = t("Show Tabs", "显示标签页")
        } else {
            let title = t("Show Inbox", "显示收件箱")
            base = attention > 0 ? "\(title) · \(inboxAttention(attention))" : title
        }
        return withShortcut(base, inboxShortcut)
    }
    /// Tabs whose agent needs attention, failed, or finished unseen.
    func inboxAttention(_ count: Int) -> String {
        t(count == 1 ? "1 tab needs attention" : "\(count) tabs need attention", "\(count) 个标签页待处理")
    }
    /// Inbox section for tabs whose agent is working or waiting for the user.
    var inboxContinue: String { t("Continue", "继续") }
    var inboxEarlier: String { t("Earlier", "更早") }

    // Accessibility
    var tabs: String { t("Tabs", "标签页") }
    var rightSidebar: String { t("Right Sidebar", "右侧边栏") }
    var selected: String { t("Selected", "已选中") }
}
