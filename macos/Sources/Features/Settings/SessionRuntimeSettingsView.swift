import SwiftUI

struct SessionRuntimeSettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @State private var host = ""
    @State private var error: String?
    private var chinese: Bool { settings.language == .simplifiedChinese }
    private func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("Persistent SSH sessions", "SSH 后台会话")).font(.headline)
            HStack {
                TextField(text("SSH host or user@host", "SSH 主机别名或 user@host"), text: $host)
                Button(text("Connect", "连接")) { connect() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(text("Uses your SSH configuration and keys. Installs the runtime and, when Python 3 is available, OMG recovery hooks for Codex, Claude and Pi in the remote user's directory.",
                      "使用现有 SSH 配置与密钥，自动在远端用户目录安装 Runtime；有 Python 3 时同时安装 Codex、Claude、Pi 的 OMG 对话恢复 hooks。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(text("Keep disconnected sessions (hours)", "断开后最长保留（小时）"))
                Spacer()
                TextField("72", value: $settings.runtimeDetachedHours, format: .number).frame(width: 80)
            }
            Text(text("Defaults to 72 hours (3 days). 0 disables only this time limit, not completion cleanup. Output does not extend it. Changes apply to new sessions.",
                      "默认 72 小时（3 天）。0 仅关闭此时间上限，不影响任务完成后回收。持续输出不会延长期限；修改对新会话生效。"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(text("Optional deadline, e.g. 2026-12-01T18:00:00Z", "可选截止时间，例如 2026-12-01T18:00:00Z"), text: $settings.runtimeExpiration)
            Toggle(text("Close after Agent task completion", "Agent 任务完成后回收"), isOn: $settings.runtimeCloseOnAgentDone)
            Text(text("Installs OMG hooks for Codex, Claude and Pi (requires remote Python 3). Only closes disconnected sessions with verified completion and an existing conversation record; reopening resumes that conversation.",
                      "会安装 Codex、Claude、Pi 的 OMG hooks（需要远端 Python 3）。仅在无人连接、收到可靠完成事件且已有对话记录时回收，再次打开恢复原对话。"))
                .font(.caption).foregroundStyle(.secondary)
            if settings.runtimeCloseOnAgentDone {
                HStack {
                    Text(text("Completion grace period (seconds)", "完成后的宽限期（秒）"))
                    Spacer()
                    TextField("60", value: $settings.runtimeDoneGraceSeconds, format: .number).frame(width: 80)
                }
                Text(text("Wait after both disconnection and verified completion. Reconnecting or new work cancels this pending cleanup; the maximum detached lifetime still applies independently.",
                          "断开连接且确认任务完成后，再等待这段时间。重连或新任务会取消本次完成回收；最长保留期限仍独立生效。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(text("The remote manager exits after 5 minutes with no active sessions or client connections. Running or waiting Agent sessions are not an idle manager.",
                      "远端管理进程在没有活跃会话和客户端连接达 5 分钟后退出。仍有 Agent 运行或等待输入时，不属于管理进程空闲。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func connect() {
        do {
            if !settings.runtimeExpiration.isEmpty && settings.runtimePolicy.expiresAt == nil {
                error = text("Enter an ISO-8601 deadline or leave it empty.", "请填写 ISO-8601 截止时间，或留空。")
                return
            }
            let connection = try GitSSHConnection(destination: host.trimmingCharacters(in: .whitespacesAndNewlines))
            try SessionRuntimeConnections.shared.open(connection: connection, policy: settings.runtimePolicy)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
