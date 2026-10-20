import Foundation

/// Deliberately closed list of existing Ghostty capabilities. No free-form config
/// is interpolated into the managed overlay; unset always inherits Ghostty config.
struct CoreSetting: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case lifecycle, shell, selection, clipboard, mouse, keyboard, notifications, cursor

        func title(_ strings: SettingsStrings) -> String {
            switch self {
            case .lifecycle: strings.t("Windows & Closing", "窗口与关闭")
            case .shell: strings.t("Shell Integration & Working Directory", "Shell 集成与工作目录")
            case .selection: strings.t("Text Selection", "文本选择")
            case .clipboard: strings.t("Clipboard & Paste Safety", "剪贴板与粘贴安全")
            case .mouse: strings.t("Mouse & Focus", "鼠标与焦点")
            case .keyboard: strings.t("Terminal Keyboard", "终端键盘")
            case .notifications: strings.t("Terminal Notifications", "终端通知")
            case .cursor: strings.t("Cursor & Font Inheritance", "光标与字体继承")
            }
        }

        var tab: OhMyGhosttySettingsTab {
            switch self {
            case .lifecycle: .general
            case .shell, .notifications: .terminal
            case .selection, .clipboard, .mouse, .keyboard: .controls
            case .cursor: .appearance
            }
        }
    }

    let key: String
    let group: Group
    let english: String
    let chinese: String
    let helpEnglish: String
    let helpChinese: String
    var values: [String] = ["true", "false"]
    var requiresNewTerminal = false
    var id: String { "core." + key }
    func title(_ strings: SettingsStrings) -> String { strings.t(english, chinese) }
    func help(_ strings: SettingsStrings) -> String { strings.t(helpEnglish, helpChinese) }

    func valueTitle(_ value: String, strings: SettingsStrings) -> String {
        switch (key, value) {
        case ("confirm-close-surface", "true"): return strings.t("When a process is running", "有进程运行时")
        case (_, "true"): return strings.t("On", "开启")
        case (_, "false"), ("shell-integration", "none"): return strings.t("Off", "关闭")
        case (_, "always"): return strings.t("Always", "始终")
        case (_, "detect"): return strings.t("Auto-detect", "自动检测")
        case (_, "clipboard"): return strings.t("System clipboard", "系统剪贴板")
        case (_, "ask"): return strings.t("Ask", "询问")
        case (_, "allow"): return strings.t("Allow", "允许")
        case (_, "deny"): return strings.t("Deny", "拒绝")
        case (_, "left"): return strings.t("Left Option", "左 Option")
        case (_, "right"): return strings.t("Right Option", "右 Option")
        default: return value
        }
    }

    static let all: [Self] = [
        .init(key: "confirm-close-surface", group: .lifecycle, english: "Confirm Closing a Terminal", chinese: "关闭终端前确认",
              helpEnglish: "Applies to terminal panes, tabs and windows. Process detection uses shell integration.",
              helpChinese: "适用于终端分屏、标签和窗口；运行状态检测依赖 Shell 集成。", values: ["true", "always", "false"]),
        .init(key: "quit-after-last-window-closed", group: .lifecycle, english: "Quit After Last Window Closes", chinese: "关闭所有窗口后退出",
              helpEnglish: "Quit OMG when its last terminal window closes.", helpChinese: "最后一个终端窗口关闭后退出 OMG。"),
        .init(key: "window-inherit-working-directory", group: .shell, english: "Inherit Working Directory", chinese: "继承工作目录",
              helpEnglish: "New windows, tabs and splits inherit the active terminal's directory. Shell integration must report it.",
              helpChinese: "新窗口、标签和分屏继承当前终端目录；需要 Shell 集成上报目录。", requiresNewTerminal: true),
        .init(key: "shell-integration", group: .shell, english: "Shell Integration", chinese: "Shell 集成",
              helpEnglish: "Inject prompt and directory integration in supported shells.",
              helpChinese: "为受支持的 Shell 注入提示符和目录集成。",
              values: ["detect", "none", "bash", "fish", "zsh", "elvish", "nushell"], requiresNewTerminal: true),
        .init(key: "selection-clear-on-typing", group: .selection, english: "Clear Selection When Typing", chinese: "输入时清除选区",
              helpEnglish: "Clear selected terminal text when typing.", helpChinese: "输入字符时清除终端文字选区。"),
        .init(key: "selection-clear-on-copy", group: .selection, english: "Clear Selection After Copying", chinese: "复制后清除选区",
              helpEnglish: "Clear selected terminal text after a copy action.", helpChinese: "完成复制操作后清除文字选区。"),
        .init(key: "copy-on-select", group: .clipboard, english: "Copy on Selection", chinese: "选中即复制",
              helpEnglish: "Copy selected text to the macOS clipboard.", helpChinese: "将选中的文字自动复制到 macOS 剪贴板。", values: ["false", "clipboard"]),
        .init(key: "clipboard-trim-trailing-spaces", group: .clipboard, english: "Trim Trailing Spaces", chinese: "复制时去除行尾空格",
              helpEnglish: "Remove trailing whitespace from copied terminal lines.", helpChinese: "复制终端文字时移除行尾多余空白。"),
        .init(key: "clipboard-paste-protection", group: .clipboard, english: "Confirm Unsafe Paste", chinese: "确认不安全的粘贴",
              helpEnglish: "Warn before pasting content that may execute commands.", helpChinese: "粘贴可能执行命令的内容前显示警告。"),
        .init(key: "clipboard-paste-bracketed-safe", group: .clipboard, english: "Trust Bracketed Paste", chinese: "信任括号粘贴模式",
              helpEnglish: "Skip paste confirmation when the terminal application enables bracketed paste.",
              helpChinese: "终端应用启用 bracketed paste 时跳过粘贴确认。"),
        .init(key: "clipboard-read", group: .clipboard, english: "Application Clipboard Read", chinese: "终端应用读取剪贴板",
              helpEnglish: "Control terminal escape-sequence clipboard reads; this does not affect normal paste.",
              helpChinese: "控制终端转义序列读取剪贴板的权限，不影响普通粘贴。", values: ["ask", "deny", "allow"]),
        .init(key: "clipboard-write", group: .clipboard, english: "Application Clipboard Write", chinese: "终端应用写入剪贴板",
              helpEnglish: "Control terminal escape-sequence clipboard writes; this does not affect normal copy.",
              helpChinese: "控制终端转义序列写入剪贴板的权限，不影响普通复制。", values: ["allow", "ask", "deny"]),
        .init(key: "focus-follows-mouse", group: .mouse, english: "Focus Follows Mouse", chinese: "鼠标悬停切换焦点",
              helpEnglish: "Focus a terminal split when the pointer enters it.", helpChinese: "鼠标进入终端分屏时将焦点切换到该分屏。"),
        .init(key: "mouse-hide-while-typing", group: .mouse, english: "Hide Pointer While Typing", chinese: "输入时隐藏鼠标",
              helpEnglish: "Hide the pointer until it moves again.", helpChinese: "输入时隐藏鼠标指针，移动后重新显示。"),
        .init(key: "macos-option-as-alt", group: .keyboard, english: "Use Option as Alt", chinese: "将 Option 用作 Alt",
              helpEnglish: "Send Alt escape sequences instead of composing special characters.",
              helpChinese: "发送 Alt 转义序列，而不是输入特殊字符。", values: ["false", "true", "left", "right"]),
        .init(key: "desktop-notifications", group: .notifications, english: "Allow Terminal Notifications", chinese: "允许终端应用通知",
              helpEnglish: "Allow terminal programs to send desktop notifications. Agent notifications are configured separately.",
              helpChinese: "允许终端程序发送桌面通知；Agent 通知在 Agent 页面独立设置。"),
        .init(key: "cursor-style-blink", group: .cursor, english: "Blinking Cursor", chinese: "光标闪烁",
              helpEnglish: "Terminal applications may override the cursor's blinking state.", helpChinese: "终端应用可以覆盖光标的闪烁状态。"),
        .init(key: "window-inherit-font-size", group: .cursor, english: "Inherit Font Size", chinese: "继承字体大小",
              helpEnglish: "New terminals inherit the active terminal's adjusted font size.",
              helpChinese: "新终端继承当前终端调整后的字号。", requiresNewTerminal: true),
    ]

    static func find(_ key: String) -> Self? { all.first { $0.key == key } }
}
