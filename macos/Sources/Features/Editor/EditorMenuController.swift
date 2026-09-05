import AppKit

@MainActor
final class EditorMenuController: NSObject, NSMenuItemValidation {
    static let shared = EditorMenuController()

    func install(in menu: NSMenu?) {
        guard let menu, !menu.items.contains(where: { $0.action == #selector(openFileFromMenu(_:)) }) else { return }
        let open = NSMenuItem(title: "Open File in Editor…", action: #selector(openFileFromMenu(_:)), keyEquivalent: "o")
        open.target = self
        menu.insertItem(open, at: min(2, menu.items.count))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        terminalController != nil
    }

    private var terminalController: TerminalController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? TerminalController
    }

    @objc private func openFileFromMenu(_ sender: Any?) {
        guard let controller = terminalController else { return }
        openFile(in: controller)
    }

    func openFile(in controller: TerminalController) {
        let workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID)
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
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
        if filesystem.descriptor.kind == .ssh {
            let alert = NSAlert()
            alert.messageText = "Open Remote File"
            alert.informativeText = filesystem.descriptor.displayName
            let field = NSTextField(string: filesystem.descriptor.workingDirectory + "/")
            field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard let window = controller.window else { return }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                workspace.open(path: field.stringValue, filesystem: filesystem)
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: filesystem.descriptor.workingDirectory)
            guard let window = controller.window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                workspace.open(path: url.path, filesystem: filesystem)
            }
        }
    }
}
