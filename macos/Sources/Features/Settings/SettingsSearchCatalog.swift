import Foundation

struct SettingsSearchEntry: Identifiable {
    let id: String
    let tab: OhMyGhosttySettingsTab
    let title: String
    let anchor: String
    var keywords: String
    var settingIDs: [String] = []
    var prefixes: [String] = []

    func matches(_ query: String) -> Bool {
        let text = (title + " " + keywords + " " + settingIDs.joined(separator: " "))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        return !tokens.isEmpty && tokens.allSatisfy { text.contains($0) }
    }
}

@MainActor
enum SettingsSearchCatalog {
    static func entries(strings: SettingsStrings) -> [SettingsSearchEntry] {
        let en = SettingsStrings(language: .english)
        let zh = SettingsStrings(language: .simplifiedChinese)
        func item(_ tab: OhMyGhosttySettingsTab, _ title: KeyPath<SettingsStrings, String>,
                  _ prefixes: [String], _ keywords: String = "", anchor: String? = nil) -> SettingsSearchEntry {
            let label = strings[keyPath: title]
            return .init(id: tab.rawValue + ":" + en[keyPath: title], tab: tab, title: label, anchor: anchor ?? label,
                         keywords: en[keyPath: title] + " " + zh[keyPath: title] + " " + en.tabTitle(tab) + " " + zh.tabTitle(tab) + " " + keywords,
                         prefixes: prefixes)
        }
        var result: [SettingsSearchEntry] = [
            item(.general, \.languageSection, ["general.language"], "English 中文 language"),
            item(.general, \.quitSection, ["general.quitWithoutConfirmation"], "exit quit confirmation 退出 确认"),
            item(.terminal, \.sessionRecoverySection, ["sessions.startup"], "startup restore scrollback 启动 恢复 滚屏"),
            item(.terminal, \.newSessionInheritanceSection, ["sessions.newTab", "sessions.newSplit"],
                 "inherit directory ssh agent resume 继承 目录 会话 新建标签 新建分屏"),
            .init(id: "terminal:runtime", tab: .terminal, title: strings.runtimeTitle, anchor: strings.runtimeTitle,
                  keywords: "SSH background lifetime deadline TTL Agent completion resume quit exit keep quick terminal 后台 会话 存活 截止 完成 恢复 退出 继续 快捷终端",
                  prefixes: ["sessions.runtime", "sessions.localRuntime", "sessions.quickTerminalRuntime", "sessions.keep"]),
            item(.controls, \.quickInputSection,
                 ["keyboard.quickInputHeight", "keyboard.quickInputOpacity", "keyboard.quickInputHistory", "keyboard.quickInputControlJ", "keyboard.quickInputImport"],
                 "history retention newline control-j opacity transparency glass draft import 快捷输入 历史 保留 换行 透明度 不透明度 透明 毛玻璃 草稿 导入"),
            item(.editor, \.editorOpeningSection, ["editor.fileOpen", "editor.directoryOpen"], "files folders 打开 文件 目录"),
            item(.editor, \.editorBehaviorSection, ["editor.keymap", "editor.autoClose", "editor.wordWrap"], "vim wrap pairs 自动换行 括号"),
            item(.editor, \.editorThemeSection, ["editor.background", "editor.syntax", "editor.theme", "editor.opacity", "editor.blur"], "主题 透明"),
            item(.editor, \.editorTypographySection, ["editor.font", "editor.tabWidth"], "字体 缩进 字号"),
            item(.agents, \.aiProvidersSection, ["ai.providers"],
                 "AI provider model service api connection key openai anthropic base url endpoint model list context window max output tokens codex claude opencode pi local cli 模型服务 提供商 连接 密钥 端点 模型 上下文 输出 本机 CLI"),
            item(.agents, \.aiTitleModelGroup, ["agents.sessionTitle"],
                 "title rename conversation tab model always shorten ai 自动命名 会话标题 标签标题 标题 重命名 对话 模型 精简"),
            item(.agents, \.aiTaskModelsSection, ["ai.routes"],
                 "AI model commit tag pull request PR message fallback route priority custom prompt 提交 标签 信息 备用 模型 顺序 提示词"),
            item(.agents, \.terminalCodingAgentsSection, ["agents.statusHooks", "agents.openQuickInput"],
                 "hook install cli update agent integration ssh live status start complete quick input 集成 接入 安装 更新 状态扩展 实时状态 开始 完成 快捷输入"),
            item(.agents, \.agentNotificationsAndHistorySection, ["notifications.", "agents.history"],
                 "notification sound tone permission history sessions limit index 通知 声音 提示音 音色 等待 历史 会话 上限 索引"),
            item(.tabs, \.layoutSection, ["tabs.layout", "tabs.sidebarWidth", "tabs.sidebarVisible", "tabs.remember"],
                 "vertical horizontal sidebar width 垂直 水平 侧栏 侧边栏 宽度"),
            item(.tabs, \.organizationSection, ["tabs.group", "tabs.order", "tabs.path"],
                 "group directory order path tabs list 分组 路径 排序 普通标签"),
            item(.tabs, \.inboxViewSection, ["tabs.sidebarView", "tabs.inbox"],
                 "inbox continue window minutes today yesterday recent created grouping ordering 收件箱 继续 保留 时长 最近 创建 收件箱分组 收件箱排序"),
            item(.tabs, \.tabsDisplaySection, ["appearance.tab", "tabs.show", "terminal.resize"],
                 "density icon shortcut resize rendering reflow 行高 图标 密度 快捷键 调整窗口 渲染 重排"),
            item(.appearance, \.terminalThemeSection, ["appearance.window", "appearance.light", "appearance.dark"], "theme light dark system 主题 深色 浅色 系统"),
            item(.appearance, \.focusedSplitBorderSection,
                 ["terminal.focusedSplitBorder", "appearance.backgroundOpacity", "appearance.unfocusedSplitOpacity"],
                 "outline border focus pane width position opacity dimming background-opacity unfocused-split-opacity 分屏 聚焦 焦点 描边 宽度 厚度 位置 透明度 淡化"),
            item(.appearance, \.fontSection, ["appearance.font"], "字体 字号 font size"),
            item(.appearance, \.transparencySection, ["appearance.background"], "opacity blur 透明 模糊 毛玻璃"),
            item(.appearance, \.cursorSection, ["appearance.cursor"], "cursor 光标"),
            item(.keyboard, \.quickInputShortcutLabel, ["keyboard.quickInput"], "shortcut 快捷键 快捷输入"),
            item(.keyboard, \.numberShortcutsSection, ["keyboard.inspector", "keyboard.tabNumber", "keyboard.toggle"],
                 "inspector sidebar inbox toggle tab workspace panel number modifier 快捷键 检查器 面板 侧边栏 收件箱 标签 工作区 数字 修饰键"),
            item(.keyboard, \.keybindingsSection, [], "keybind terminal shortcut 键位 终端 快捷键"),
            item(.git, \.gitSection, ["git.autoFetch"], "fetch Git 自动拉取"),
            item(.git, \.gitAISettingsTitle, ["git.commitAI"], "commit AI prompt style 提交 提示词 风格"),
            item(.mobile, \.mobileAccessTitle, [], "mobile iPhone iPad device pair invitation gateway LAN wifi usb sidestore altstore refresh provisioning certificate wireless 手机 移动 设备 配对 邀请 网关 局域网 连接 状态 访问 权限 签名 证书 续签 安装 刷新"),
            item(.ssh, \.sshSettingsTitle, [], "ssh machine host remote register 机器 主机 远程 注册", anchor: "sshRegistration"),
            item(.plugins, \.officialPluginsSection, [], "plugin install 插件 安装 官方"),
            item(.advanced, \.doctorSection, [], "doctor health diagnostics accessibility tcc signing certificate trust keychain gatekeeper memory webview lsp reclaim runtime omgd ssh backup 健康 自检 诊断 辅助功能 签名 证书 信任 钥匙串 权限 内存 回收"),
            item(.advanced, \.settingsLocationsSection, [""], "config settings.json reload 配置文件 重载 来源", anchor: "settingsFiles"),
        ]
        for group in CoreSetting.Group.allCases {
            let fields = CoreSetting.all.filter { $0.group == group }
            result.append(.init(id: "core:" + group.rawValue, tab: group.tab, title: group.title(strings), anchor: group.title(strings),
                                keywords: fields.map { $0.english + " " + $0.chinese + " " + $0.helpEnglish + " " + $0.helpChinese + " " + $0.key }.joined(separator: " "),
                                prefixes: fields.map(\.id)))
        }
        // Every persisted descriptor routes to one group, by its most specific prefix.
        for descriptor in OhMyGhosttySettings.descriptors {
            guard let index = result.indices.max(by: { lhs, rhs in
                matchLength(descriptor.id, result[lhs].prefixes) < matchLength(descriptor.id, result[rhs].prefixes)
            }) else { continue }
            result[index].settingIDs.append(descriptor.id)
            result[index].keywords += " " + descriptor.description
        }
        return result
    }

    private static func matchLength(_ id: String, _ prefixes: [String]) -> Int {
        prefixes.filter { id.hasPrefix($0) }.map(\.count).max() ?? -1
    }
}
