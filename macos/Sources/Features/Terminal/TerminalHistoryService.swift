import AppKit
import Foundation
import GhosttyKit

@MainActor
final class TerminalHistoryService {
    static let shared = TerminalHistoryService()

    private var recordedCommandsBySurface: [UUID: [InspectorHistoryItem]] = [:]

    init() {}

    /// 记录某一个 Surface 执行过的命令
    func recordCommand(text: String, surfaceID: UUID, exitCode: Int16? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var list = recordedCommandsBySurface[surfaceID] ?? []
        // Each execution is distinct, including adjacent identical commands.
        let item = InspectorHistoryItem(
            id: UUID().uuidString,
            kind: .command,
            text: trimmed,
            timestamp: Date(),
            exitCode: exitCode
        )
        list.insert(item, at: 0)
        if list.count > 50 { list.removeLast() }
        recordedCommandsBySurface[surfaceID] = list
    }

    /// 清除指定 Surface 的记录
    func removeSurface(_ surfaceID: UUID) {
        recordedCommandsBySurface.removeValue(forKey: surfaceID)
    }

    /// 获取指定 Surface 内存中记录的命令
    func recordedCommands(for surfaceID: UUID) -> [InspectorHistoryItem] {
        recordedCommandsBySurface[surfaceID] ?? []
    }

    /// 获取普通 Shell 的历史命令（严格限定当前 Surface，隔离各 Pane）
    func loadShellHistory(surfaceID: UUID? = nil, limit: Int = 30) -> [InspectorHistoryItem] {
        guard let surfaceID, let recorded = recordedCommandsBySurface[surfaceID] else {
            return []
        }
        return Array(recorded.prefix(max(0, limit)))
    }

    /// 从磁盘读取用户常见 Shell 的历史文件
    private func loadRecentCommandsFromDisk(limit: Int) -> [InspectorHistoryItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let zshHistoryURL = home.appendingPathComponent(".zsh_history")
        let bashHistoryURL = home.appendingPathComponent(".bash_history")

        if FileManager.default.fileExists(atPath: zshHistoryURL.path) {
            return parseZshHistory(at: zshHistoryURL, limit: limit)
        } else if FileManager.default.fileExists(atPath: bashHistoryURL.path) {
            return parseBashHistory(at: bashHistoryURL, limit: limit)
        }
        return []
    }

    private func parseZshHistory(at url: URL, limit: Int) -> [InspectorHistoryItem] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        let lines = content.components(separatedBy: .newlines)
        var items: [InspectorHistoryItem] = []

        // 从后往前读取最新历史
        for rawLine in lines.reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            var cmdText = line
            var date: Date?

            // zsh 扩展格式: ": 1711234567:0;command"
            if line.hasPrefix(": ") {
                let parts = line.dropFirst(2).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count == 2 {
                    cmdText = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let timeParts = parts[0].split(separator: ":")
                    if let first = timeParts.first, let timestamp = TimeInterval(first) {
                        date = Date(timeIntervalSince1970: timestamp)
                    }
                }
            }

            guard !cmdText.isEmpty else { continue }
            items.append(InspectorHistoryItem(
                id: UUID().uuidString,
                kind: .command,
                text: cmdText,
                timestamp: date
            ))

            if items.count >= limit {
                break
            }
        }
        return items
    }

    private func parseBashHistory(at url: URL, limit: Int) -> [InspectorHistoryItem] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: .newlines)
        var items: [InspectorHistoryItem] = []

        for rawLine in lines.reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            items.append(InspectorHistoryItem(
                id: UUID().uuidString,
                kind: .command,
                text: line,
                timestamp: nil
            ))
            if items.count >= limit {
                break
            }
        }
        return items
    }

    private final class CommandSnapshot {
        var items: [InspectorHistoryItem] = []
        let surfaceID: UUID
        init(surfaceID: UUID) { self.surfaceID = surfaceID }
    }

    func commands(in view: Ghostty.SurfaceView) -> [InspectorHistoryItem] {
        guard let surface = view.surface else { return [] }
        let snapshot = CommandSnapshot(surfaceID: view.id)
        ghostty_surface_omg_commands(surface, Unmanaged.passUnretained(snapshot).toOpaque()) { context, id, text, timestamp in
            guard let context, let text else { return }
            let snapshot = Unmanaged<CommandSnapshot>.fromOpaque(context).takeUnretainedValue()
            snapshot.items.append(.init(
                id: "command:\(snapshot.surfaceID.uuidString):\(id)",
                kind: .command,
                text: String(cString: text),
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp))
            ))
        }
        return snapshot.items.reversed()
    }

    /// 执行终端跳转到历史项（Shell 命令或 Agent Prompt）所在位置
    @discardableResult
    func jump(to item: InspectorHistoryItem, in surfaceView: Ghostty.SurfaceView) -> Bool {
        guard let surface = surfaceView.surface else { return false }
        if item.kind == .command {
            let prefix = "command:\(surfaceView.id.uuidString):"
            guard item.id.hasPrefix(prefix),
                  let id = UInt64(item.id.dropFirst(prefix.count)) else { return false }
            let result = ghostty_surface_omg_jump_command(surface, id)
            if result { Ghostty.moveFocus(to: surfaceView, from: nil) }
            return result
        }

        // A transcript message is not a terminal coordinate. Never substitute
        // a text search for an execution anchor (especially repeated prompts).
        return false
    }
}
