import Foundation

/// Resolves a user-facing string from `Localizable.xcstrings`. Xcode compiles
/// the catalog into the app bundle itself, so `Bundle.main` is already the
/// right table — unlike the Mac app, whose strings live in a SwiftPM resource
/// bundle and need an explicit one. The call shape is deliberately the same as
/// the Mac's `localized(_:)` so one sweep finds every UI string on both sides.
func localized(_ key: String.LocalizationValue) -> String {
    let value = String(localized: key).replacingOccurrences(of: "Termio", with: "OMG")
    if value == "Chats" || value == "聊天" { return "Agent" }
    let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    let labels = [
        "Agent": "Agent",
        "Acknowledgements": "致谢",
        "Add Project": "添加项目",
        "Background": "后台",
        "Background Sessions": "后台会话",
        "Conversation": "对话",
        "Send": "发送",
        "Workspaces": "工作区",
        "Message": "消息",
        "Interrupt": "中断",
        "Choose Folder": "选择文件夹",
        "Use This Folder": "使用此文件夹",
        "Local Machine": "本机",
        "Earlier messages omitted": "较早消息已省略",
        "Conversation history is not available yet. Continue in Terminal.": "暂无可用对话历史，请使用终端继续。",
    ]
    return chinese ? (labels[value] ?? value) : value
}
