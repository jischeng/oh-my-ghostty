import AppKit

@MainActor
final class EditorMenuController: NSObject, NSMenuItemValidation {
    static let shared = EditorMenuController()

    func install(in menu: NSMenu?) {
        guard let menu, !menu.items.contains(where: { $0.action == #selector(openFileFromMenu(_:)) }) else { return }
        let insertIndex = min(2, menu.items.count)
        let quickOpen = NSMenuItem(
            title: "Quick Open in Editor…",
            action: #selector(quickOpenFromMenu(_:)),
            keyEquivalent: "p"
        )
        quickOpen.keyEquivalentModifierMask = [.command]
        quickOpen.target = self
        menu.insertItem(quickOpen, at: insertIndex)

        let open = NSMenuItem(
            title: "Open File in Editor…",
            action: #selector(openFileFromMenu(_:)),
            keyEquivalent: "o"
        )
        open.keyEquivalentModifierMask = [.command]
        open.target = self
        menu.insertItem(open, at: min(insertIndex + 1, menu.items.count))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        terminalController != nil
    }

    private var terminalController: TerminalController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalController
    }

    @objc private func quickOpenFromMenu(_ sender: Any?) {
        guard let controller = terminalController else { return }
        openFile(in: controller)
    }

    @objc private func openFileFromMenu(_ sender: Any?) {
        guard let controller = terminalController else { return }
        openFile(in: controller)
    }

    func openFile(
        in controller: TerminalController,
        surface preferredSurface: Ghostty.SurfaceView? = nil
    ) {
        let surface = preferredSurface ?? controller.focusedSurface ?? controller.surfaceTree.first
        let session = controller.paneSessionContext(for: surface) ?? .init(
            workingDirectory: surface?.pwd,
            terminalTitle: surface?.title ?? "Terminal"
        )
        let context = InspectorPaneContext(
            tabID: controller.tabSessionID,
            surfaceID: surface?.id,
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            workspace: session.workspace,
            session: session
        )
        let filesystem = WorkspaceFilesystemFactory.make(for: context)
        guard let window = controller.window else { return }
        EditorFilePicker.present(filesystem: filesystem, for: window) { path in
            EditorWorkspaceStore.shared.open(path: path, context: context)
        }
    }
}
