import AppKit
import Darwin
import Foundation
import GhosttyKit

@MainActor
enum TerminalCommandOutputActions {
    static let copyLastOutputEnglishTitle = "Copy Last Command Output"
    static let openLastOutputEnglishTitle = "Open Last Command Output in Editor"

    static var copyLastOutputTitle: String {
        SettingsStrings(language: OhMyGhosttySettings.shared.language).isChinese
            ? "复制上一条命令输出"
            : copyLastOutputEnglishTitle
    }

    static var openLastOutputTitle: String {
        SettingsStrings(language: OhMyGhosttySettings.shared.language).isChinese
            ? "在编辑器中打开上一条命令输出"
            : openLastOutputEnglishTitle
    }

    static func hasLastCommandOutput(
        in surface: Ghostty.SurfaceView,
        historyService: TerminalHistoryService = .shared
    ) -> Bool {
        guard let output = historyService.lastCommandOutput(in: surface) else { return false }
        return !output.isEmpty
    }

    static func canExtractOutput(
        for item: InspectorHistoryItem,
        in surface: Ghostty.SurfaceView,
        historyService: TerminalHistoryService = .shared
    ) -> Bool {
        guard item.kind == .command, item.location.isAvailable else { return false }
        guard let output = historyService.commandOutput(for: item, in: surface) else { return false }
        return !output.isEmpty
    }

    @discardableResult
    static func copyLastCommandOutput(
        from surface: Ghostty.SurfaceView,
        historyService: TerminalHistoryService = .shared,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let output = historyService.lastCommandOutput(in: surface), !output.isEmpty else {
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(output, forType: .string)
    }

    @discardableResult
    static func copyCommandOutput(
        for item: InspectorHistoryItem,
        from surface: Ghostty.SurfaceView,
        historyService: TerminalHistoryService = .shared,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let output = historyService.commandOutput(for: item, in: surface), !output.isEmpty else {
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(output, forType: .string)
    }

    @discardableResult
    static func openLastCommandOutputInEditor(
        from surface: Ghostty.SurfaceView,
        historyService: TerminalHistoryService = .shared,
        editorStore: EditorWorkspaceStore = .shared,
        baseDirectory: URL? = nil
    ) -> URL? {
        guard let output = historyService.lastCommandOutput(in: surface), !output.isEmpty else {
            NSSound.beep()
            return nil
        }
        let commandText = historyService.commands(for: surface.id)
            .first(where: { $0.location.isAvailable })?
            .text
        return openOutputTextInEditor(
            output,
            commandText: commandText,
            from: surface,
            editorStore: editorStore,
            baseDirectory: baseDirectory
        )
    }

    @discardableResult
    static func openCommandOutputInEditor(
        for item: InspectorHistoryItem,
        from surface: Ghostty.SurfaceView,
        historyService: TerminalHistoryService = .shared,
        editorStore: EditorWorkspaceStore = .shared,
        baseDirectory: URL? = nil
    ) -> URL? {
        guard let output = historyService.commandOutput(for: item, in: surface), !output.isEmpty else {
            NSSound.beep()
            return nil
        }
        return openOutputTextInEditor(
            output,
            commandText: item.text,
            from: surface,
            editorStore: editorStore,
            baseDirectory: baseDirectory
        )
    }

    static func writeTemporaryOutputFile(
        _ output: String,
        commandText: String?,
        baseDirectory: URL? = nil
    ) -> URL? {
        let root = baseDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-command-output-\(getuid())", isDirectory: true)
        guard ensurePrivateDirectory(root) else { return nil }
        pruneExpiredFiles(in: root)

        let slug = sanitizedFilenameSlug(from: commandText)
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let filename = "\(slug)-\(stamp)-\(suffix).log"
        let fileURL = root.appendingPathComponent(filename)
        let normalized = output.hasSuffix("\n") ? output : output + "\n"
        do {
            try SessionRuntimeBridgeStorage.writePrivateFile(
                at: fileURL,
                data: Data(normalized.utf8),
                permissions: 0o600
            )
            return fileURL
        } catch {
            return nil
        }
    }

    @discardableResult
    static func openOutputTextInEditor(
        _ output: String,
        commandText: String? = nil,
        from surface: Ghostty.SurfaceView,
        editorStore: EditorWorkspaceStore = .shared,
        baseDirectory: URL? = nil
    ) -> URL? {
        guard let fileURL = writeTemporaryOutputFile(
            output,
            commandText: commandText,
            baseDirectory: baseDirectory
        ) else {
            NSSound.beep()
            return nil
        }

        let localFilesystem = LocalWorkspaceFilesystem(
            workingDirectory: fileURL.deletingLastPathComponent().path
        )
        if let controller = TerminalFocusRouter.controller(owning: surface) as? TerminalController,
           let target = EditorPaneDestination.open(
               in: controller,
               source: surface,
               destination: OhMyGhosttySettings.shared.editorFileOpenDestination
           ) {
            editorStore.workspace(
                for: target.controller.tabSessionID,
                surfaceID: target.surface.id
            ).open(
                path: fileURL.path,
                filesystem: localFilesystem,
                location: nil,
                externalFallback: true
            )
        } else if let host = TerminalHostLookup.host(owning: surface),
                  let editorController = host.resolveEditorHostController(workingDirectory: surface.pwd),
                  let targetSurface = editorController.focusedSurface ?? editorController.surfaceTree.first {
            editorStore.workspace(
                for: editorController.tabSessionID,
                surfaceID: targetSurface.id
            ).open(
                path: fileURL.path,
                filesystem: localFilesystem,
                location: nil,
                externalFallback: true
            )
        }
        return fileURL
    }

    private static func sanitizedFilenameSlug(from commandText: String?) -> String {
        guard let commandText else { return "command-output" }
        let firstToken = commandText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        let base = (firstToken as NSString).lastPathComponent
        let filtered = String(base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        })
        .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !filtered.isEmpty else { return "command-output" }
        return String(filtered.prefix(24)).lowercased()
    }

    private static func ensurePrivateDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return false }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }

    private static func pruneExpiredFiles(in directory: URL, maxAge: TimeInterval = 24 * 60 * 60) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in urls where url.pathExtension == "log" {
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

@MainActor
final class TerminalCommandMenuController: NSObject, NSMenuItemValidation {
    static let shared = TerminalCommandMenuController()

    func install(in editMenu: NSMenu?) {
        guard let editMenu,
              !editMenu.items.contains(where: { $0.action == #selector(copyLastCommandOutputFromMenu(_:)) }) else {
            return
        }
        let copyIndex = editMenu.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) })
        let insertIndex = copyIndex.map { min($0 + 2, editMenu.items.count) } ?? editMenu.items.count

        let copyItem = NSMenuItem(
            title: TerminalCommandOutputActions.copyLastOutputTitle,
            action: #selector(copyLastCommandOutputFromMenu(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self

        let openItem = NSMenuItem(
            title: TerminalCommandOutputActions.openLastOutputTitle,
            action: #selector(openLastCommandOutputFromMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self

        editMenu.insertItem(openItem, at: insertIndex)
        editMenu.insertItem(copyItem, at: insertIndex)
    }

    func appendContextMenuItems(to menu: NSMenu, for surface: Ghostty.SurfaceView) {
        let hasOutput = TerminalCommandOutputActions.hasLastCommandOutput(in: surface)
        let copyItem = NSMenuItem(
            title: TerminalCommandOutputActions.copyLastOutputTitle,
            action: #selector(copyLastCommandOutputFromContextMenu(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.representedObject = surface
        copyItem.isEnabled = hasOutput
        copyItem.setImageIfDesired(systemSymbolName: "doc.on.doc")

        let openItem = NSMenuItem(
            title: TerminalCommandOutputActions.openLastOutputTitle,
            action: #selector(openLastCommandOutputFromContextMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.representedObject = surface
        openItem.isEnabled = hasOutput
        openItem.setImageIfDesired(systemSymbolName: "doc.text")

        let pasteIndex = menu.items.firstIndex(where: { $0.action == #selector(NSText.paste(_:)) })
        let insertBase = pasteIndex.map { $0 + 1 } ?? menu.items.count
        menu.insertItem(openItem, at: insertBase)
        menu.insertItem(copyItem, at: insertBase)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let surface = menuItem.representedObject as? Ghostty.SurfaceView {
            return TerminalCommandOutputActions.hasLastCommandOutput(in: surface)
        }
        guard let surface = activeSurface else { return false }
        return TerminalCommandOutputActions.hasLastCommandOutput(in: surface)
    }

    private var activeSurface: Ghostty.SurfaceView? {
        guard let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? BaseTerminalController else {
            return nil
        }
        return controller.focusedSurface ?? controller.surfaceTree.first
    }

    @objc private func copyLastCommandOutputFromMenu(_ sender: Any?) {
        guard let surface = activeSurface else { return }
        _ = TerminalCommandOutputActions.copyLastCommandOutput(from: surface)
    }

    @objc private func openLastCommandOutputFromMenu(_ sender: Any?) {
        guard let surface = activeSurface else { return }
        _ = TerminalCommandOutputActions.openLastCommandOutputInEditor(from: surface)
    }

    @objc private func copyLastCommandOutputFromContextMenu(_ sender: NSMenuItem) {
        guard let surface = sender.representedObject as? Ghostty.SurfaceView ?? activeSurface else { return }
        _ = TerminalCommandOutputActions.copyLastCommandOutput(from: surface)
    }

    @objc private func openLastCommandOutputFromContextMenu(_ sender: NSMenuItem) {
        guard let surface = sender.representedObject as? Ghostty.SurfaceView ?? activeSurface else { return }
        _ = TerminalCommandOutputActions.openLastCommandOutputInEditor(from: surface)
    }
}
