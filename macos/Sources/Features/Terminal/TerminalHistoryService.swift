import AppKit
import Foundation
import GhosttyKit

@MainActor
final class TerminalHistoryService {
    static let shared = TerminalHistoryService()

    private var recordedCommandsBySurface: [UUID: [InspectorHistoryItem]] = [:]

    private var pendingJumps: [UUID: Date] = [:]

    init() {}

    /// Search completion is asynchronous; navigate only once a match exists.
    func searchResultsChanged(in surfaceView: Ghostty.SurfaceView, total: UInt?) {
        guard let deadline = pendingJumps[surfaceView.id] else { return }
        guard deadline > Date() else {
            pendingJumps.removeValue(forKey: surfaceView.id)
            return
        }
        guard let total, total > 0 else { return }
        pendingJumps.removeValue(forKey: surfaceView.id)
        _ = surfaceView.navigateSearchToPrevious()
    }

    /// 记录某一个 Surface 执行过的命令
    func recordCommand(text: String, surfaceID: UUID, exitCode: Int16? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var list = recordedCommandsBySurface[surfaceID] ?? []
        // 避免紧邻的完全相同重复命令连续刷屏
        if list.first?.text != trimmed {
            let item = InspectorHistoryItem(
                id: UUID().uuidString,
                kind: .command,
                text: trimmed,
                timestamp: Date(),
                exitCode: exitCode
            )
            list.insert(item, at: 0)
            if list.count > 50 {
                list.removeLast()
            }
            recordedCommandsBySurface[surfaceID] = list
        }
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
        var results: [InspectorHistoryItem] = []
        var seenTexts = Set<String>()
        for item in recorded where seenTexts.insert(item.text).inserted {
            results.append(item)
            if results.count >= limit { break }
        }
        return results
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

    /// 执行终端跳转到历史项（Shell 命令或 Agent Prompt）所在位置
    @discardableResult
    func jump(to item: InspectorHistoryItem, in surfaceView: Ghostty.SurfaceView) -> Bool {
        guard let surface = surfaceView.surface else { return false }

        // 提取搜索关键文本：取第一行非空文本，最多 40 字符，去除多余字符
        let firstLine = item.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? item.text

        // 去掉可能的 prompt 符号前缀（如 '> ', '● ', '$ ' 等）
        var needle = firstLine
        for prefix in ["> ", "● ", "$ ", "# ", "% ", "➜ "] where needle.hasPrefix(prefix) {
            needle = String(needle.dropFirst(prefix.count))
            break
        }
        needle = String(needle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))

        guard !needle.isEmpty else { return false }

        // 确保该 Surface 聚焦
        Ghostty.moveFocus(to: surfaceView, from: nil)

        // Restart even an unchanged needle so a fresh result callback arrives.
        _ = ghostty_surface_binding_action(surface, "search:", 7)
        pendingJumps[surfaceView.id] = Date().addingTimeInterval(10)
        let action = "search:\(needle)"
        let success = ghostty_surface_binding_action(
            surface,
            action,
            UInt(action.lengthOfBytes(using: .utf8))
        )
        if !success { pendingJumps.removeValue(forKey: surfaceView.id) }
        return success
    }
}
